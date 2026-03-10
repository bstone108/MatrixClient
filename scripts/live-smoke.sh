#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/MatrixClient.xcodeproj"
TMP_ROOT="${TMPDIR:-/tmp}"
DERIVED_DATA_PATH="${TMP_ROOT%/}/MatrixLiveSmokeDerivedData"
RUNTIME_ROOT="$(mktemp -d "${TMP_ROOT%/}/matrix-live-smoke.XXXXXX")"

cleanup() {
  rm -rf "$RUNTIME_ROOT"
}
trap cleanup EXIT

if [[ -z "${MATRIX_LIVE_TEST_SERVER:-}" || -z "${MATRIX_LIVE_TEST_USERNAME:-}" || -z "${MATRIX_LIVE_TEST_PASSWORD:-}" ]]; then
  echo "Set MATRIX_LIVE_TEST_SERVER, MATRIX_LIVE_TEST_USERNAME, and MATRIX_LIVE_TEST_PASSWORD before running this script." >&2
  exit 1
fi

cd "$ROOT_DIR"

xcodegen generate --spec "$ROOT_DIR/project.yml"

xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme MatrixLiveSmoke \
  -configuration Debug \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build

PRODUCTS_DIR="$DERIVED_DATA_PATH/Build/Products/Debug"
mkdir -p "$RUNTIME_ROOT/Frameworks"

ditto "$PRODUCTS_DIR/MatrixLiveSmoke" "$RUNTIME_ROOT/MatrixLiveSmoke"
ditto "$PRODUCTS_DIR/MatrixCore.framework" "$RUNTIME_ROOT/Frameworks/MatrixCore.framework"
ditto "$PRODUCTS_DIR/Persistence.framework" "$RUNTIME_ROOT/Frameworks/Persistence.framework"
ditto "$PRODUCTS_DIR/Diagnostics.framework" "$RUNTIME_ROOT/Frameworks/Diagnostics.framework"

env \
  MATRIX_LIVE_TEST_SERVER="$MATRIX_LIVE_TEST_SERVER" \
  MATRIX_LIVE_TEST_USERNAME="$MATRIX_LIVE_TEST_USERNAME" \
  MATRIX_LIVE_TEST_PASSWORD="$MATRIX_LIVE_TEST_PASSWORD" \
  MATRIX_LIVE_TEST_EXPECTED_HOMESERVER_HOST="${MATRIX_LIVE_TEST_EXPECTED_HOMESERVER_HOST:-}" \
  DYLD_FRAMEWORK_PATH="$RUNTIME_ROOT/Frameworks" \
  "$RUNTIME_ROOT/MatrixLiveSmoke"
