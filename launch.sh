#!/usr/bin/env bash
set -euo pipefail

# Launch the prebuilt RemoteControlTest runner on a physical device via go-ios.
# Build it once with launch_with_xcodebuild.sh (or `xcodebuild build-for-testing`)
# so the .xctest bundle is installed, then drive it over the LAN.

ios runwda \
    --bundleid=com.idevice.RemoteControlTest.xctrunner \
    --testrunnerbundleid=com.idevice.RemoteControlTest.xctrunner \
    --xctestconfig=RemoteControlTest.xctest \
    --env=SERVER_PORT=18200 \
    --udid=00008101-00161DAE14B8001E
