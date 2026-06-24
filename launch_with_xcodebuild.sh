#!/usr/bin/env bash
set -euo pipefail

# Builds the RemoteControlTest XCUITest runner on a physical device via
# xcodebuild and keeps it alive. The test method blocks on its embedded swifter
# control server, so this process stays running until a client hits /api/exit
# (or until you Ctrl-C it).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_PATH="$SCRIPT_DIR/RemoteControlTest.xcodeproj"
SCHEME="${SCHEME:-RemoteControlTest}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$SCRIPT_DIR/build/DerivedData-RemoteControlTest}"
ONLY_TESTING="${ONLY_TESTING:-RemoteControlTest/RemoteControlTest/testRemoteControl}"
DEVICE_UDID="${DEVICE_UDID:-00008101-00161DAE14B8001E}"
SERVER_PORT="${SERVER_PORT:-18200}"
# Reuse an existing .xctestrun and skip the build-for-testing step when set.
SKIP_BUILD="${SKIP_BUILD:-0}"

if [[ -n "${XCODE_DESTINATION:-}" ]]; then
  DESTINATION="$XCODE_DESTINATION"
elif [[ -n "$DEVICE_UDID" ]]; then
  DESTINATION="platform=iOS,id=$DEVICE_UDID"
else
  echo "Set DEVICE_UDID or XCODE_DESTINATION to launch on a physical iOS device." >&2
  exit 64
fi

if [[ ! -d "$PROJECT_PATH" ]]; then
  echo "Missing Xcode project: $PROJECT_PATH" >&2
  exit 66
fi

COMMON_XCODEBUILD_ARGS=(
  -project "$PROJECT_PATH"
  -scheme "$SCHEME"
  -destination "$DESTINATION"
  -derivedDataPath "$DERIVED_DATA_PATH"
)

if [[ "$SKIP_BUILD" != "1" ]]; then
  # Resolve the swifter Swift Package dependency, then build the test bundle.
  xcodebuild "${COMMON_XCODEBUILD_ARGS[@]}" -resolvePackageDependencies
  xcodebuild "${COMMON_XCODEBUILD_ARGS[@]}" build-for-testing
fi

XCTESTRUN_FILES=("$DERIVED_DATA_PATH"/Build/Products/*.xctestrun)
if [[ ! -e "${XCTESTRUN_FILES[0]}" ]]; then
  echo "Missing generated .xctestrun under $DERIVED_DATA_PATH/Build/Products" >&2
  echo "Run without SKIP_BUILD=1 to build it first." >&2
  exit 66
fi
XCTESTRUN_PATH="${XCTESTRUN_FILES[0]}"
PLIST_BUDDY="/usr/libexec/PlistBuddy"

set_xctestrun_env_var() {
  local env_path="$1"
  local key="$2"
  local value="$3"

  "$PLIST_BUDDY" -c "Print $env_path" "$XCTESTRUN_PATH" >/dev/null 2>&1 ||
    "$PLIST_BUDDY" -c "Add $env_path dict" "$XCTESTRUN_PATH"

  "$PLIST_BUDDY" -c "Set $env_path:$key $value" "$XCTESTRUN_PATH" >/dev/null 2>&1 ||
    "$PLIST_BUDDY" -c "Add $env_path:$key string $value" "$XCTESTRUN_PATH"
}

for env_path in \
  ":TestConfigurations:0:TestTargets:0:EnvironmentVariables" \
  ":TestConfigurations:0:TestTargets:0:TestingEnvironmentVariables"; do
  set_xctestrun_env_var "$env_path" "SERVER_PORT" "$SERVER_PORT"
done

echo "Launching $ONLY_TESTING on $DESTINATION"
echo "  SERVER_PORT=$SERVER_PORT"
echo "Control the runner over http://<device-ip>:$SERVER_PORT (e.g. /api/health)."

exec xcodebuild \
  -xctestrun "$XCTESTRUN_PATH" \
  -destination "$DESTINATION" \
  test-without-building \
  -only-testing:"$ONLY_TESTING"
