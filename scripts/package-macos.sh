#!/usr/bin/env bash
set -euo pipefail

# Build a Release MatrixClient.app the same way scripts/build-debug.sh does
# (xcodegen + xcodebuild, then copy nested frameworks), then Developer ID-sign,
# notarize, and staple both the .app and a .dmg.
#
# Architectures: separate arm64 and x86_64 apps, not one universal binary.
# CI runs macos-15 (ARCHS=arm64) and macos-15-intel (ARCHS=x86_64). After
# assemble, every Mach-O must contain that job's slice (a fat VLCKit still
# counts). Do not pass both arches in one job.
#
# Flags:
#   --compile-only  unsigned Release compile + assemble + slice check.
#                   Used by pull-request CI. Does not import a cert, call
#                   notarytool, staple, consume a date.build N, or emit zip/dmg.
#   --print-version resolve the artifact version label and exit.
#
# Required for a signed release:
#   MACOS_CODESIGN_IDENTITY  (never "-" / ad-hoc)
#
# Required for notarization (signed releases only; never on --compile-only):
#   APPLE_ID
#   APPLE_APP_SPECIFIC_PASSWORD
#   APPLE_TEAM_ID
#
# Versioning:
#   MATRIXCLIENT_RELEASE=1  assign YYYY.M.D.N (America/Chicago) for a real
#                           GitHub release. N is max(existing tag/release)+1.
#   MATRIXCLIENT_VERSION    when releasing from an already-pushed vYYYY.M.D.N
#                           tag, use that version instead of incrementing.
#   Pull-request / verification runs must leave MATRIXCLIENT_RELEASE unset.
#   They keep the committed Info.plist template (0.1.0 / 1) inside the bundle
#   and name artifacts with a non-release label (default: ci).
#
# Zip / notary (Apple cannot staple a zip):
#   ditto -c -k --keepParent the .app, notarytool submit that zip, stapler
#   staple the .app, THEN ship that stapled .app as the release zip. Codesign,
#   notarize, and staple the .dmg as well. The notary zip is disposable.
#
# Optional:
#   MACOS_REQUIRE_NOTARIZATION=1  force notarization even outside Actions
#   MACOS_NOTARY_TIMEOUT          notarytool --timeout (default 45m)
#   MATRIXCLIENT_CI_VERSION_LABEL artifact label for non-release runs (ci)
#   MATRIXCLIENT_ARCH             arm64 or x86_64 (default: uname -m)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
VERSION_HELPER="${SCRIPT_DIR}/next-date-build-version.py"
VLCKIT_LOAD_HELPER="${SCRIPT_DIR}/verify-mediakit-vlckit-load.py"
SLICE_HELPER="${SCRIPT_DIR}/verify-macos-slices.py"
PROJECT_PATH="${ROOT_DIR}/MatrixClient.xcodeproj"
COMPILE_ONLY=0
ENTITLEMENTS_FILE="${ROOT_DIR}/Config/MatrixClient.entitlements"
INFO_PLIST="${ROOT_DIR}/Config/MatrixClient-Info.plist"
APP_NAME="MatrixClient"
CI_VERSION_LABEL="${MATRIXCLIENT_CI_VERSION_LABEL:-ci}"

is_release_packaging() {
  [[ "${MATRIXCLIENT_RELEASE:-0}" == "1" ]]
}

looks_like_date_build() {
  [[ "${1:-}" =~ ^[0-9]{4}\.([1-9]|1[0-2])\.([1-9]|[12][0-9]|3[01])\.[1-9][0-9]*$ ]]
}

resolve_packaging_version() {
  if is_release_packaging; then
    local version
    if [[ -n "${MATRIXCLIENT_VERSION:-}" ]]; then
      version="$(python3 "${VERSION_HELPER}" --from-tag "${MATRIXCLIENT_VERSION}")"
    else
      version="$(python3 "${VERSION_HELPER}")"
    fi
    if [[ -z "${version}" ]] || ! looks_like_date_build "${version}"; then
      echo "Failed to assign a date.build release version (got: ${version:-empty})." >&2
      exit 1
    fi
    APP_VERSION="${version}"
    BUNDLE_VERSION="${version}"
    echo "Release version ${APP_VERSION} (America/Chicago date.build)" >&2
    return
  fi

  APP_VERSION="${CI_VERSION_LABEL}"
  BUNDLE_VERSION="${CI_VERSION_LABEL}"
  if looks_like_date_build "${APP_VERSION}"; then
    echo "CI/test artifact label ${APP_VERSION} looks like a shipped date.build; refusing to consume a release number." >&2
    exit 1
  fi
  echo "CI/test packaging label ${APP_VERSION} (not a release; Info.plist template is left unstamped)" >&2
}

if [[ "${1:-}" == "--print-version" ]]; then
  resolve_packaging_version
  printf '%s\n' "${APP_VERSION}"
  exit 0
fi

if [[ "${1:-}" == "--compile-only" ]]; then
  COMPILE_ONLY=1
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This packaging script must be run on macOS (except --print-version)." >&2
  exit 1
fi

MACOS_ARCH="${MATRIXCLIENT_ARCH:-${MATRIXCLIENT_ARCHS:-$(uname -m)}}"
if [[ "${MACOS_ARCH}" == *" "* || "${MACOS_ARCH}" == *","* || "${MACOS_ARCH}" == *universal* ]]; then
  echo "Refusing ARCHS=${MACOS_ARCH}. Ship separate arm64 and x86_64 jobs, not a universal binary." >&2
  exit 1
fi
if [[ "${MACOS_ARCH}" != "arm64" && "${MACOS_ARCH}" != "x86_64" ]]; then
  echo "Unsupported MATRIXCLIENT_ARCH=${MACOS_ARCH} (expected arm64 or x86_64)." >&2
  exit 1
fi
ARCH_LABEL="${MACOS_ARCH}"
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

if [[ ! -f "${VERSION_HELPER}" ]]; then
  echo "Version helper not found: ${VERSION_HELPER}" >&2
  exit 1
fi

if [[ ! -f "${VLCKIT_LOAD_HELPER}" ]]; then
  echo "VLCKit load helper not found: ${VLCKIT_LOAD_HELPER}" >&2
  exit 1
fi

if [[ ! -f "${SLICE_HELPER}" ]]; then
  echo "Architecture slice helper not found: ${SLICE_HELPER}" >&2
  exit 1
fi

if [[ "${COMPILE_ONLY}" -eq 1 ]] && is_release_packaging; then
  echo "Refusing --compile-only together with MATRIXCLIENT_RELEASE=1 (that would consume a date.build)." >&2
  exit 1
fi

resolve_packaging_version

using_developer_id() {
  [[ -n "${CODESIGN_IDENTITY}" && "${CODESIGN_IDENTITY}" != "-" ]]
}

notarization_requested() {
  if [[ "${COMPILE_ONLY}" -eq 1 ]]; then
    return 1
  fi
  if [[ "${MACOS_REQUIRE_NOTARIZATION:-0}" == "1" || -n "${GITHUB_ACTIONS:-}" ]]; then
    return 0
  fi
  [[ -n "${APPLE_ID:-}" && -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" && -n "${APPLE_TEAM_ID:-}" ]]
}

if [[ "${COMPILE_ONLY}" -eq 0 ]]; then
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

  local mediakit_binary
  mediakit_binary="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "${mediakit_version_dir}/MediaKit")"
  rewrite_mediakit_vlckit_load "${mediakit_binary}"
  python3 "${VLCKIT_LOAD_HELPER}" --binary "${mediakit_binary}"
}

rewrite_mediakit_vlckit_load() {
  local mediakit_binary="$1"
  if [[ ! -f "${mediakit_binary}" ]]; then
    echo "MediaKit binary not found: ${mediakit_binary}" >&2
    exit 1
  fi
  if ! command -v otool >/dev/null 2>&1; then
    echo "otool is required to rewrite MediaKit's VLCKit load command." >&2
    exit 1
  fi
  if ! command -v install_name_tool >/dev/null 2>&1; then
    echo "install_name_tool is required to rewrite MediaKit's VLCKit load command." >&2
    exit 1
  fi

  local current_load rewritten_load
  current_load="$(otool -arch all -L "${mediakit_binary}" | python3 "${VLCKIT_LOAD_HELPER}" --print-vlckit-load)"
  rewritten_load="$(python3 "${VLCKIT_LOAD_HELPER}" --rewrite-load "${current_load}")"
  if [[ "${current_load}" == "${rewritten_load}" ]]; then
    echo "MediaKit VLCKit load command already nested: ${current_load}"
    return
  fi

  # vlckit-spm/Xcode records @loader_path/../Frameworks/VLCKit..., which is a
  # sibling of Versions/A. After the codesign-valid nest, dyld needs
  # @loader_path/Frameworks/VLCKit...  LC_RPATH is unused: this is not @rpath.
  echo "Rewriting MediaKit VLCKit load command:"
  echo "  from ${current_load}"
  echo "  to   ${rewritten_load}"
  chmod u+w "${mediakit_binary}"
  install_name_tool -change "${current_load}" "${rewritten_load}" "${mediakit_binary}"
}

stamp_release_versions_on_app() {
  local app_bundle="$1"
  local plist="${app_bundle}/Contents/Info.plist"
  if [[ ! -f "${plist}" ]]; then
    echo "Staged Info.plist not found: ${plist}" >&2
    exit 1
  fi

  if ! is_release_packaging; then
    echo "CI/test build: leaving template versions in ${plist}"
    /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${plist}" || true
    /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${plist}" || true
    return
  fi

  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${APP_VERSION}" "${plist}"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${APP_VERSION}" "${plist}"

  local short_version
  local bundle_version
  short_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${plist}")"
  bundle_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${plist}")"
  if [[ "${short_version}" != "${APP_VERSION}" || "${bundle_version}" != "${APP_VERSION}" ]]; then
    echo "Failed to stamp ${plist} with ${APP_VERSION} (got ${short_version} / ${bundle_version})." >&2
    exit 1
  fi
  echo "Stamped ${plist} CFBundleShortVersionString=${short_version} CFBundleVersion=${bundle_version}"
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
  ARCHS="${MACOS_ARCH}" \
  ONLY_ACTIVE_ARCH=YES \
  EXCLUDED_ARCHS= \
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

# This job's slice must be present. A fat nested VLCKit still counts.
python3 "${SLICE_HELPER}" \
  --require "${MACOS_ARCH}" \
  --must-include "Contents/MacOS/${APP_NAME}" \
  --must-include "VLCKit.framework" \
  "${STAGED_APP}"

if [[ "${COMPILE_ONLY}" -eq 1 ]]; then
  echo "Compile-only: unsigned ${ARCH_LABEL} app staged at ${STAGED_APP}"
  echo "ARCHS=${MACOS_ARCH} ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO"
  echo "Skipping Developer ID import, notarytool, stapler, zip, and dmg."
  exit 0
fi

# Stamp before codesign so the sealed Info.plist matches the artifact/tag.
# Never rewrite Config/MatrixClient-Info.plist in git.
stamp_release_versions_on_app "${STAGED_APP}"

sign_app_bundle "${STAGED_APP}"

ARCHIVE_PATH="${DELIVERABLE_DIR}/${APP_NAME}-${APP_VERSION}-macos-${ARCH_LABEL}.zip"
DMG_PATH="${DELIVERABLE_DIR}/${APP_NAME}-${APP_VERSION}-macos-${ARCH_LABEL}.dmg"
NOTARY_ZIP_PATH="${WORK_DIR}/${APP_NAME}-notarize.zip"

if notarization_requested; then
  # Apple cannot staple a zip. Submit a zip of the Developer ID-signed .app,
  # stapler staple that .app, then ship a new zip of the stapled .app. The
  # notary zip is deleted and is not a release asset.
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
} > "${DELIVERABLE_DIR}/SHA256SUMS-macos-${ARCH_LABEL}"

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
    echo "arch=${ARCH_LABEL}"
  } >> "${GITHUB_OUTPUT}"
fi
