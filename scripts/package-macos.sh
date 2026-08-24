#!/usr/bin/env bash
set -euo pipefail

# Build a Release MatrixClient.app the same way scripts/build-debug.sh does
# (xcodegen + xcodebuild, then copy nested frameworks), then Developer ID-sign,
# notarize, and staple both the .app and a .dmg.
#
# Required for a signed release:
#   MACOS_CODESIGN_IDENTITY  (never "-" / ad-hoc)
#
# Required for notarization (always on GitHub Actions):
#   APPLE_ID
#   APPLE_APP_SPECIFIC_PASSWORD
#   APPLE_TEAM_ID
#
# Optional:
#   MACOS_REQUIRE_NOTARIZATION=1  force notarization even outside Actions
#   MACOS_NOTARY_TIMEOUT          notarytool --timeout (default 45m)

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This packaging script must be run on macOS." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT_PATH="${ROOT_DIR}/MatrixClient.xcodeproj"
ENTITLEMENTS_FILE="${ROOT_DIR}/Config/MatrixClient.entitlements"
INFO_PLIST="${ROOT_DIR}/Config/MatrixClient-Info.plist"
APP_NAME="MatrixClient"
ARCH="$(uname -m)"
CODESIGN_IDENTITY="${MACOS_CODESIGN_IDENTITY:-}"
NOTARY_TIMEOUT="${MACOS_NOTARY_TIMEOUT:-45m}"

TMP_ROOT="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
TMP_ROOT="${TMP_ROOT%/}"
WORK_DIR="${TMP_ROOT}/MatrixClientRelease"
DERIVED_DATA_PATH="${TMP_ROOT}/MatrixClientReleaseDerivedData"
STAGING_BUILD_DIR="${TMP_ROOT}/MatrixClientReleaseBuildProducts"
DELIVERABLE_DIR="${ROOT_DIR}/build"

cd "${ROOT_DIR}"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen is required to regenerate the Xcode project before building." >&2
  exit 1
fi

if [[ ! -f "${INFO_PLIST}" ]]; then
  echo "Info.plist not found: ${INFO_PLIST}" >&2
  exit 1
fi

APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${INFO_PLIST}")"
BUNDLE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${INFO_PLIST}")"
if [[ -z "${APP_VERSION}" ]]; then
  echo "CFBundleShortVersionString is empty in ${INFO_PLIST}" >&2
  exit 1
fi

using_developer_id() {
  [[ -n "${CODESIGN_IDENTITY}" && "${CODESIGN_IDENTITY}" != "-" ]]
}

notarization_requested() {
  if [[ "${MACOS_REQUIRE_NOTARIZATION:-0}" == "1" || -n "${GITHUB_ACTIONS:-}" ]]; then
    return 0
  fi
  [[ -n "${APPLE_ID:-}" && -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" && -n "${APPLE_TEAM_ID:-}" ]]
}

if ! using_developer_id; then
  echo "MACOS_CODESIGN_IDENTITY must be a Developer ID identity; ad-hoc codesign --sign - is not allowed for release artifacts." >&2
  exit 1
fi

if [[ ! -f "${ENTITLEMENTS_FILE}" ]]; then
  echo "Entitlements file not found: ${ENTITLEMENTS_FILE}" >&2
  exit 1
fi

if notarization_requested; then
  : "${APPLE_ID:?APPLE_ID is required for notarization}"
  : "${APPLE_APP_SPECIFIC_PASSWORD:?APPLE_APP_SPECIFIC_PASSWORD is required for notarization}"
  : "${APPLE_TEAM_ID:?APPLE_TEAM_ID is required for notarization}"
fi

if ! security find-identity -v -p codesigning | grep -F "${CODESIGN_IDENTITY}" >/dev/null; then
  echo "Signing identity not found in keychain: ${CODESIGN_IDENTITY}" >&2
  security find-identity -v -p codesigning >&2 || true
  exit 1
fi

rm_rf() {
  python3 - "$@" <<'PY'
from pathlib import Path
import shutil
import sys

for path_str in sys.argv[1:]:
    path = Path(path_str)
    if path.exists():
        shutil.rmtree(path)
PY
}

copy_tree() {
  local source="$1"
  local destination="$2"
  FRAMEWORK_DESTINATION="${destination}" python3 - <<'PY'
from pathlib import Path
import os
import shutil

path = Path(os.environ["FRAMEWORK_DESTINATION"])
if path.exists():
    shutil.rmtree(path)
PY
  ditto "${source}" "${destination}"
}

list_macho_files() {
  local root="$1"
  python3 - "${root}" <<'PY'
import os
import sys

root = sys.argv[1]
magics = {
    b"\xfe\xed\xfa\xce",
    b"\xce\xfa\xed\xfe",
    b"\xfe\xed\xfa\xcf",
    b"\xcf\xfa\xed\xfe",
    b"\xca\xfe\xba\xbe",
    b"\xbe\xba\xfe\xca",
    b"\xca\xfe\xba\xbf",
}
files = []
for dirpath, _, filenames in os.walk(root):
    for name in filenames:
        path = os.path.join(dirpath, name)
        try:
            with open(path, "rb") as handle:
                magic = handle.read(4)
        except OSError:
            continue
        if magic in magics:
            files.append(path)
files.sort(key=lambda path: path.count(os.sep), reverse=True)
for path in files:
    print(path)
PY
}

item_wants_entitlements() {
  local item="$1"
  if [[ -d "${item}" && "${item}" == *.app ]]; then
    return 0
  fi
  # Entitlements apply to processes, not libraries. Nested VLCKit/MatrixRustSDK
  # dylibs and framework binaries only need a hardened-runtime signature.
  if [[ "${item}" == *.dylib || "${item}" == *.so || "${item}" == *.framework/* ]]; then
    return 1
  fi
  return 0
}

sign_item() {
  local item="$1"
  local args=(
    --force
    --options runtime
    --timestamp
    --sign "${CODESIGN_IDENTITY}"
  )
  if item_wants_entitlements "${item}" && [[ -f "${ENTITLEMENTS_FILE}" ]]; then
    args+=(--entitlements "${ENTITLEMENTS_FILE}" --generate-entitlement-der)
  fi
  echo "Signing (Developer ID) ${item}"
  codesign "${args[@]}" "${item}"
}

sign_app_bundle() {
  local app_bundle="$1"

  if [[ ! -d "${app_bundle}" ]]; then
    echo "App bundle not found: ${app_bundle}" >&2
    exit 1
  fi

  xattr -cr "${app_bundle}" 2>/dev/null || true

  while IFS= read -r macho_path; do
    [[ -z "${macho_path}" ]] && continue
    sign_item "${macho_path}"
  done < <(list_macho_files "${app_bundle}")

  while IFS= read -r framework; do
    [[ -d "${framework}" ]] || continue
    echo "Signing framework ${framework}"
    codesign --force --options runtime --timestamp --sign "${CODESIGN_IDENTITY}" "${framework}"
  done < <(find "${app_bundle}" -name "*.framework" -type d | awk '{ print gsub(/\//, "/") "\t" $0 }' | sort -nr | cut -f2-)

  # Sign the bundle last so the sealed resources include nested signatures.
  sign_item "${app_bundle}"

  codesign --verify --deep --strict --verbose=2 "${app_bundle}"

  local signature_info
  signature_info="$(codesign --display --verbose=2 "${app_bundle}" 2>&1)"
  echo "${signature_info}"
  if grep -q "Signature=adhoc" <<<"${signature_info}"; then
    echo "Developer ID signing produced an ad-hoc signature." >&2
    exit 1
  fi
  if ! grep -Eq "flags=.*runtime" <<<"${signature_info}"; then
    echo "Hardened runtime is missing from the app signature." >&2
    exit 1
  fi
}

zip_app_bundle() {
  local app_bundle="$1"
  local archive_path="$2"
  rm -f "${archive_path}"
  ditto -c -k --sequesterRsrc --keepParent "${app_bundle}" "${archive_path}"
}

create_signed_dmg() {
  local app_bundle="$1"
  local dmg_path="$2"
  local dmg_stage="${WORK_DIR}/dmg-stage"

  rm -rf "${dmg_stage}" "${dmg_path}"
  mkdir -p "${dmg_stage}"
  ditto "${app_bundle}" "${dmg_stage}/${APP_NAME}.app"
  ln -s /Applications "${dmg_stage}/Applications"

  hdiutil create \
    -volname "Matrix Client" \
    -srcfolder "${dmg_stage}" \
    -ov \
    -format UDZO \
    -fs HFS+ \
    "${dmg_path}"

  rm -rf "${dmg_stage}"

  echo "Signing (Developer ID) ${dmg_path}"
  codesign --force --timestamp --sign "${CODESIGN_IDENTITY}" "${dmg_path}"
  codesign --verify --verbose=2 "${dmg_path}"
}

parse_notary_field() {
  local json_path="$1"
  local field="$2"
  python3 - "${json_path}" "${field}" <<'PY'
import json
import sys

path = sys.argv[1]
field = sys.argv[2]
text = open(path, encoding="utf-8").read().strip()
obj = None
try:
    obj = json.loads(text)
except json.JSONDecodeError:
    start = text.rfind("{")
    end = text.rfind("}")
    if start == -1 or end == -1 or end < start:
        raise
    obj = json.loads(text[start:end + 1])
if isinstance(obj, list):
    obj = obj[-1]
print(obj.get(field, "") or "")
PY
}

fetch_notary_log() {
  local json_path="$1"
  local submission_id
  submission_id="$(parse_notary_field "${json_path}" id || true)"
  if [[ -z "${submission_id}" ]]; then
    echo "Unable to parse notarization submission id from ${json_path}" >&2
    cat "${json_path}" >&2 || true
    return 1
  fi
  echo "Fetching notarization log for ${submission_id}" >&2
  xcrun notarytool log "${submission_id}" \
    --apple-id "${APPLE_ID}" \
    --password "${APPLE_APP_SPECIFIC_PASSWORD}" \
    --team-id "${APPLE_TEAM_ID}" >&2 || true
}

submit_for_notarization() {
  local artifact_path="$1"
  local label="$2"
  # BSD mktemp requires the XXXXXX placeholder at the end of the template.
  # A suffix such as .json after XXXXXX can fail to create the file and break
  # the second notarytool submit after the app is already notarized.
  local output_file
  output_file="$(mktemp "${WORK_DIR}/notary.XXXXXX")"
  local status=""

  echo "Submitting ${label} for notarization: ${artifact_path}"
  if ! xcrun notarytool submit "${artifact_path}" \
      --apple-id "${APPLE_ID}" \
      --password "${APPLE_APP_SPECIFIC_PASSWORD}" \
      --team-id "${APPLE_TEAM_ID}" \
      --wait \
      --timeout "${NOTARY_TIMEOUT}" \
      --output-format json \
      > "${output_file}"; then
    echo "notarytool submit failed for ${label}" >&2
    cat "${output_file}" >&2 || true
    fetch_notary_log "${output_file}" || true
    exit 1
  fi

  cat "${output_file}"
  status="$(parse_notary_field "${output_file}" status)"
  if [[ "${status}" != "Accepted" ]]; then
    echo "Notarization for ${label} finished with status: ${status:-unknown}" >&2
    fetch_notary_log "${output_file}" || true
    exit 1
  fi
}

assemble_app_bundle() {
  local source_app="$1"
  local staged_app="$2"

  ditto "${source_app}" "${staged_app}"

  local app_frameworks_dir="${staged_app}/Contents/Frameworks"
  mkdir -p "${app_frameworks_dir}"

  shopt -s nullglob
  local framework_dir
  for framework_dir in "${STAGING_BUILD_DIR}"/*.framework "${STAGING_BUILD_DIR}"/PackageFrameworks/*.framework; do
    if [[ -d "${framework_dir}" ]]; then
      copy_tree "${framework_dir}" "${app_frameworks_dir}/$(basename "${framework_dir}")"
    fi
  done
  shopt -u nullglob

  # Nested frameworks belong in Versions/<version>/Frameworks. A directory named
  # Versions/Frameworks is treated as an invalid version and fails
  # `codesign --verify --deep --strict`.
  local mediakit_version_dir="${app_frameworks_dir}/MediaKit.framework/Versions/Current"
  if [[ ! -e "${mediakit_version_dir}" ]]; then
    mediakit_version_dir="${app_frameworks_dir}/MediaKit.framework/Versions/A"
  fi
  local mediakit_frameworks_dir="${mediakit_version_dir}/Frameworks"
  mkdir -p "${mediakit_frameworks_dir}"
  if [[ -d "${app_frameworks_dir}/VLCKit.framework" ]]; then
    copy_tree "${app_frameworks_dir}/VLCKit.framework" "${mediakit_frameworks_dir}/VLCKit.framework"
  fi
}

rm_rf "${WORK_DIR}" "${DERIVED_DATA_PATH}" "${STAGING_BUILD_DIR}"
mkdir -p "${WORK_DIR}" "${STAGING_BUILD_DIR}" "${DELIVERABLE_DIR}"

xcodegen generate --spec "${ROOT_DIR}/project.yml"

xcodebuild \
  -project "${PROJECT_PATH}" \
  -scheme MatrixClient \
  -configuration Release \
  -derivedDataPath "${DERIVED_DATA_PATH}" \
  "CONFIGURATION_BUILD_DIR=${STAGING_BUILD_DIR}" \
  ARCHS="${ARCH}" \
  ONLY_ACTIVE_ARCH=YES \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build

SOURCE_APP="${STAGING_BUILD_DIR}/${APP_NAME}.app"
if [[ ! -d "${SOURCE_APP}" ]]; then
  echo "Built app bundle not found: ${SOURCE_APP}" >&2
  exit 1
fi

STAGED_APP="${WORK_DIR}/${APP_NAME}.app"
rm_rf "${STAGED_APP}"
assemble_app_bundle "${SOURCE_APP}" "${STAGED_APP}"

if [[ ! -f "${STAGED_APP}/Contents/MacOS/${APP_NAME}" ]]; then
  echo "Missing app executable: ${STAGED_APP}/Contents/MacOS/${APP_NAME}" >&2
  exit 1
fi

sign_app_bundle "${STAGED_APP}"

ARCHIVE_PATH="${DELIVERABLE_DIR}/${APP_NAME}-${APP_VERSION}-macos-${ARCH}.zip"
DMG_PATH="${DELIVERABLE_DIR}/${APP_NAME}-${APP_VERSION}-macos-${ARCH}.dmg"
NOTARY_ZIP_PATH="${WORK_DIR}/${APP_NAME}-notarize.zip"

if notarization_requested; then
  zip_app_bundle "${STAGED_APP}" "${NOTARY_ZIP_PATH}"
  submit_for_notarization "${NOTARY_ZIP_PATH}" "app"
  rm -f "${NOTARY_ZIP_PATH}"
  xcrun stapler staple "${STAGED_APP}"
  xcrun stapler validate "${STAGED_APP}"
fi

zip_app_bundle "${STAGED_APP}" "${ARCHIVE_PATH}"
create_signed_dmg "${STAGED_APP}" "${DMG_PATH}"

if notarization_requested; then
  submit_for_notarization "${DMG_PATH}" "dmg"
  xcrun stapler staple "${DMG_PATH}"
  xcrun stapler validate "${DMG_PATH}"
fi

ditto "${STAGED_APP}" "${DELIVERABLE_DIR}/${APP_NAME}.app"

{
  cd "${DELIVERABLE_DIR}"
  shasum -a 256 \
    "$(basename "${ARCHIVE_PATH}")" \
    "$(basename "${DMG_PATH}")"
} > "${DELIVERABLE_DIR}/SHA256SUMS"

echo "Created ${ARCHIVE_PATH}"
echo "Created ${DMG_PATH}"
echo "Signed app identity:"
codesign -dvv "${STAGED_APP}" 2>&1 | grep -E "Authority|Identifier|TeamIdentifier|Runtime|Signature=" || true
echo "Signed dmg identity:"
codesign -dvv "${DMG_PATH}" 2>&1 | grep -E "Authority|Identifier|TeamIdentifier|Signature=" || true

if notarization_requested; then
  echo "Stapler status:"
  xcrun stapler validate "${STAGED_APP}"
  xcrun stapler validate "${DMG_PATH}"
fi

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "app_version=${APP_VERSION}"
    echo "bundle_version=${BUNDLE_VERSION}"
    echo "arch=${ARCH}"
  } >> "${GITHUB_OUTPUT}"
fi
