#!/usr/bin/env bash
set -euo pipefail

# Launch the prebuilt RemoteControlTest runner on a physical device via go-ios.
# Build it once with launch_with_xcodebuild.sh (or `xcodebuild build-for-testing`)
# so the .xctest bundle is installed, then drive it over the LAN.

DEVICE_UDID="${DEVICE_UDID:-00008101-00161DAE14B8001E}"
DEVICE_IP="${DEVICE_IP:-}"
RUNNER_BUNDLE_IDENTIFIER="${RUNNER_BUNDLE_IDENTIFIER:-com.idevice.RemoteControlTest.xctrunner}"
SERVER_PORT="${SERVER_PORT:-18200}"
MAX_SESSION_SECONDS="${MAX_SESSION_SECONDS:-3600}"
MAX_MEASUREMENT_SECONDS="${MAX_MEASUREMENT_SECONDS:-60}"
MAX_MEASUREMENTS_PER_SESSION="${MAX_MEASUREMENTS_PER_SESSION:-1}"
PERMISSION_WATCH_INTERVAL="${PERMISSION_WATCH_INTERVAL:-1.5}"
PERMISSION_WATCH_WINDOW="${PERMISSION_WATCH_WINDOW:-30}"
PERMISSION_WATCH_POST_ACCEPT_SECONDS="${PERMISSION_WATCH_POST_ACCEPT_SECONDS:-5}"

ios runwda \
    --bundleid="$RUNNER_BUNDLE_IDENTIFIER" \
    --testrunnerbundleid="$RUNNER_BUNDLE_IDENTIFIER" \
    --xctestconfig=RemoteControlTest.xctest \
    --env="SERVER_PORT=$SERVER_PORT" \
    --env="MAX_SESSION_SECONDS=$MAX_SESSION_SECONDS" \
    --env="MAX_MEASUREMENT_SECONDS=$MAX_MEASUREMENT_SECONDS" \
    --env="MAX_MEASUREMENTS_PER_SESSION=$MAX_MEASUREMENTS_PER_SESSION" \
    --env="PERMISSION_WATCH_INTERVAL=$PERMISSION_WATCH_INTERVAL" \
    --env="PERMISSION_WATCH_WINDOW=$PERMISSION_WATCH_WINDOW" \
    --env="PERMISSION_WATCH_POST_ACCEPT_SECONDS=$PERMISSION_WATCH_POST_ACCEPT_SECONDS" \
    --udid="$DEVICE_UDID" &
GO_IOS_PID=$!

graceful_shutdown() {
    if [[ -n "$DEVICE_IP" ]]; then
        curl --fail --silent --show-error --max-time 3 \
            "http://$DEVICE_IP:$SERVER_PORT/api/exit" >/dev/null 2>&1 || true
        sleep 1
    fi
    kill -TERM "$GO_IOS_PID" >/dev/null 2>&1 || true
}

trap graceful_shutdown INT TERM
set +e
wait "$GO_IOS_PID"
STATUS=$?
set -e
trap - INT TERM
exit "$STATUS"
