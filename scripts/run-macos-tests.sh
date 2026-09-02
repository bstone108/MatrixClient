#!/usr/bin/env bash
set -euo pipefail

# Run the focused MatrixCore regressions, then the complete MatrixClient
# scheme test suite (MatrixCoreTests + PersistenceTests + AppShellTests).
# Requires macOS with xcodegen and Xcode. Does not sign, notarize, or publish.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT_PATH="${ROOT_DIR}/MatrixClient.xcodeproj"
LOG_DIR="${ROOT_DIR}/build/macos-test-logs"
FOCUSED_LOG="${LOG_DIR}/focused-matrixcore.log"
APPKIT_LOG="${LOG_DIR}/appkit-window-integration.log"
FULL_LOG="${LOG_DIR}/complete-scheme.log"
DERIVED_DATA="${ROOT_DIR}/build/macos-test-derived-data"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen is required." >&2
  exit 1
fi
if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "xcodebuild is required (macOS / Xcode)." >&2
  exit 1
fi

mkdir -p "${LOG_DIR}"
rm -rf "${DERIVED_DATA}"
mkdir -p "${DERIVED_DATA}"

cd "${ROOT_DIR}"
echo "+ xcodegen generate --spec project.yml"
xcodegen generate --spec "${ROOT_DIR}/project.yml"

COMMON=(
  -project "${PROJECT_PATH}"
  -scheme MatrixClient
  -destination "platform=macOS"
  -derivedDataPath "${DERIVED_DATA}"
  CODE_SIGNING_ALLOWED=NO
  CODE_SIGNING_REQUIRED=NO
)

echo
echo "===== Focused MatrixCore regressions ====="
FOCUSED_CMD=(
  xcodebuild
  "${COMMON[@]}"
  -only-testing:MatrixCoreTests/SavedSessionRestorePolicyTests
  -only-testing:MatrixCoreTests/TimelineScrollAnchorTests
  -only-testing:MatrixCoreTests/RoomListPresentationPolicyTests
  -only-testing:MatrixCoreTests/RoomHeaderExpansionPolicyTests
  -only-testing:MatrixCoreTests/WindowFramePolicyTests
  test
)
printf '+ %q' "${FOCUSED_CMD[0]}"
printf ' %q' "${FOCUSED_CMD[@]:1}"
echo
set +e
"${FOCUSED_CMD[@]}" 2>&1 | tee "${FOCUSED_LOG}"
FOCUSED_STATUS=${PIPESTATUS[0]}
set -e
echo "focused-matrixcore exit=${FOCUSED_STATUS}" | tee -a "${FOCUSED_LOG}"
if [[ "${FOCUSED_STATUS}" -ne 0 ]]; then
  echo "Focused MatrixCore regressions failed." >&2
  exit "${FOCUSED_STATUS}"
fi

echo
echo "===== AppKit main-window frame integration ====="
APPKIT_CMD=(
  xcodebuild
  "${COMMON[@]}"
  -only-testing:AppShellTests/MainWindowFrameIntegrationTests
  test
)
printf '+ %q' "${APPKIT_CMD[0]}"
printf ' %q' "${APPKIT_CMD[@]:1}"
echo
set +e
"${APPKIT_CMD[@]}" 2>&1 | tee "${APPKIT_LOG}"
APPKIT_STATUS=${PIPESTATUS[0]}
set -e
echo "appkit-window-integration exit=${APPKIT_STATUS}" | tee -a "${APPKIT_LOG}"
if [[ "${APPKIT_STATUS}" -ne 0 ]]; then
  echo "AppKit window-frame integration tests failed." >&2
  exit "${APPKIT_STATUS}"
fi

echo
echo "===== Complete MatrixClient scheme test suite ====="
FULL_CMD=(
  xcodebuild
  "${COMMON[@]}"
  test
)
printf '+ %q' "${FULL_CMD[0]}"
printf ' %q' "${FULL_CMD[@]:1}"
echo
set +e
"${FULL_CMD[@]}" 2>&1 | tee "${FULL_LOG}"
FULL_STATUS=${PIPESTATUS[0]}
set -e
echo "complete-scheme exit=${FULL_STATUS}" | tee -a "${FULL_LOG}"
if [[ "${FULL_STATUS}" -ne 0 ]]; then
  echo "Complete scheme test suite failed." >&2
  exit "${FULL_STATUS}"
fi

echo
echo "Wrote ${FOCUSED_LOG}"
echo "Wrote ${APPKIT_LOG}"
echo "Wrote ${FULL_LOG}"
echo "Both macOS test commands succeeded."
