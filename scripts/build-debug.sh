#!/bin/zsh

set -euo pipefail
setopt null_glob

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/MatrixClient.xcodeproj"
DELIVERABLE_DIR="$ROOT_DIR/build"
TMP_ROOT="${TMPDIR:-/tmp}"
DERIVED_DATA_PATH="${TMP_ROOT%/}/MatrixClientDerivedData"
STAGING_BUILD_DIR="${TMP_ROOT%/}/MatrixClientBuildProducts"

cd "$ROOT_DIR"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen is required to regenerate the Xcode project before building." >&2
  exit 1
fi

export DELIVERABLE_DIR
export DERIVED_DATA_PATH
export STAGING_BUILD_DIR

for existing_app in "$DELIVERABLE_DIR"/MatrixClient*.app(N); do
  executable_path="$existing_app/Contents/MacOS/MatrixClient"
  if [ -f "$executable_path" ]; then
    pkill -TERM -f "$executable_path" 2>/dev/null || true
  fi
done

sleep 1

python3 - <<'PY'
from pathlib import Path
import os
import shutil

for path_str in (
    os.environ["DELIVERABLE_DIR"],
    os.environ["DERIVED_DATA_PATH"],
    os.environ["STAGING_BUILD_DIR"],
):
    path = Path(path_str)
    if path.exists():
        shutil.rmtree(path)
PY

mkdir -p "$DELIVERABLE_DIR"
mkdir -p "$STAGING_BUILD_DIR"

xcodegen generate --spec "$ROOT_DIR/project.yml"

xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme MatrixClient \
  -configuration Debug \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  "CONFIGURATION_BUILD_DIR=$STAGING_BUILD_DIR" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build

ditto "$STAGING_BUILD_DIR/MatrixClient.app" "$DELIVERABLE_DIR/MatrixClient.app"

APP_FRAMEWORKS_DIR="$DELIVERABLE_DIR/MatrixClient.app/Contents/Frameworks"
mkdir -p "$APP_FRAMEWORKS_DIR"

for framework_dir in "$STAGING_BUILD_DIR"/*.framework "$STAGING_BUILD_DIR"/PackageFrameworks/*.framework; do
  if [ -d "$framework_dir" ]; then
    framework_name="$(basename "$framework_dir")"
    FRAMEWORK_DESTINATION="$APP_FRAMEWORKS_DIR/$framework_name" python3 - <<'PY'
from pathlib import Path
import os
import shutil

path = Path(os.environ["FRAMEWORK_DESTINATION"])
if path.exists():
    shutil.rmtree(path)
PY
    FRAMEWORK_DESTINATION="$APP_FRAMEWORKS_DIR/$framework_name" ditto "$framework_dir" "$APP_FRAMEWORKS_DIR/$framework_name"
  fi
done

MEDIAKIT_FRAMEWORKS_DIR="$APP_FRAMEWORKS_DIR/MediaKit.framework/Versions/Frameworks"
mkdir -p "$MEDIAKIT_FRAMEWORKS_DIR"

if [ -d "$APP_FRAMEWORKS_DIR/VLCKit.framework" ]; then
  FRAMEWORK_DESTINATION="$MEDIAKIT_FRAMEWORKS_DIR/VLCKit.framework" python3 - <<'PY'
from pathlib import Path
import os
import shutil

path = Path(os.environ["FRAMEWORK_DESTINATION"])
if path.exists():
    shutil.rmtree(path)
PY
  ditto "$APP_FRAMEWORKS_DIR/VLCKit.framework" "$MEDIAKIT_FRAMEWORKS_DIR/VLCKit.framework"
fi

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister"
if [ -x "$LSREGISTER" ]; then
  "$LSREGISTER" -u "$STAGING_BUILD_DIR/MatrixClient.app" >/dev/null 2>&1 || true
fi

python3 - <<'PY'
from pathlib import Path
import os
import shutil

deliverable_dir = Path(os.environ["DELIVERABLE_DIR"])
for duplicate in deliverable_dir.glob("MatrixClient *.app"):
    if duplicate.name != "MatrixClient.app":
        shutil.rmtree(duplicate, ignore_errors=True)

for path_str in (os.environ["DERIVED_DATA_PATH"], os.environ["STAGING_BUILD_DIR"]):
    path = Path(path_str)
    if path.exists():
        shutil.rmtree(path, ignore_errors=True)
PY

xattr -cr "$DELIVERABLE_DIR/MatrixClient.app" 2>/dev/null || true

echo "Built app bundle at $DELIVERABLE_DIR/MatrixClient.app"
