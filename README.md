# RemoteControlTest

An independent XCUITest project that turns an iOS device into a remotely
controlled agent. On launch the test stands up a tiny [`swifter`](https://github.com/httpswift/swifter)
HTTP server on the LAN and then parks on a command broker, executing UI work
on the test's main thread in response to external HTTP requests.

UI automation in XCUITest must run on the test's main thread, while the server
answers each request on a background thread. A thread-safe `CommandBroker`
bridges the two: server handlers enqueue a command and block until the
main-thread consumer in `testRemoteControl()` produces a result.

## Endpoints

The server listens on `http://{device-ip}:{SERVER_PORT}` (default `18200`).
Parameters may be passed as query string values or in a JSON request body.

| Method | Route | Parameters | Description |
| ------ | ----- | ---------- | ----------- |
| GET | `/api/health` | – | Liveness probe |
| any | `/api/launch` | `bundleId` | Terminate (if running) and relaunch an app to the foreground |
| any | `/api/activate` | `bundleId` | Foreground an app, launching it if it has exited |
| any | `/api/terminate` | `bundleId` | Terminate an app |
| GET | `/api/terminate/{bundleId}` | `bundleId` (path) | Terminate an app, with `bundleId` as a path segment |
| GET | `/api/screenshot` | – | Capture one screenshot, returned as `image/png` |
| any | `/api/tap` | `x`, `y` (normalized `[0, 1]`), `bundleId` (optional) | Tap a normalized point (`0,0` top-left, `1,1` bottom-right). Pass the foreground `bundleId` so the offset is anchored to that app's orientation (required for correct landscape taps; defaults to SpringBoard's portrait frame otherwise) |
| GET | `/api/measuring/start` | `bundleId` | Open a bounded `XCTMemoryMetric` window on an app; other commands keep working while it is open |
| GET | `/api/measuring/period/{seconds}` | `seconds` (path), `bundleId` | Open a measured window that auto-closes after `seconds` (clamped to `MAX_MEASUREMENT_SECONDS`) |
| GET | `/api/measuring/stop` | – | Close the measured window (footprint is harvested into the `.xcresult`) |
| GET | `/api/measuring/status` | – | Report the measuring `state`: `idle`, `started`, or `stopped` |
| GET | `/api/exit` | – | Quit the runner |

On-demand screenshots (`GET /api/screenshot`) are returned as `image/png` over
HTTP only — nothing is written to the device (same as WebDriverAgent).

`/api/measuring/status` reports a single `state` that walks through `idle`
(before any measurement), `started` (while a measured window is open), and
`stopped` (once a window has closed), e.g. `{"state":"started"}`.

## Environment variables

| Variable | Default | Purpose |
| -------- | ------- | ------- |
| `SERVER_PORT` | `18200` | Port the swifter server binds |
| `MAX_SESSION_SECONDS` | `3600` | Hard cap on how long the runner stays alive |
| `MAX_MEASUREMENT_SECONDS` | `60` | Hard cap for one memory-measurement window |
| `MAX_MEASUREMENTS_PER_SESSION` | `1` | Maximum measurement windows before a fresh XCTest session is required |
| `PERMISSION_WATCH_INTERVAL` | `1.5` | Seconds between SpringBoard permission checks |
| `PERMISSION_WATCH_WINDOW` | `30` | Maximum permission-watch duration after launch/activate |
| `PERMISSION_WATCH_POST_ACCEPT_SECONDS` | `5` | Remaining grace period after accepting a prompt |

`launch_with_xcodebuild.sh` also accepts
`ENABLE_PERFORMANCE_TEST_DIAGNOSTICS=YES`. It defaults to `NO` because enabling
performance diagnostics may generate large pre/post memgraphs. Both launch
scripts accept `DEVICE_IP`; when supplied, Ctrl-C first calls `/api/exit` so
XCTest can finish normally before the launcher is terminated.

### Reducing iOS "System Data"

The runner can accumulate on-device storage when misconfigured. To keep usage
light (comparable to WebDriverAgent):

1. Automatic XCTest screenshots and diagnostic recordings are disabled at
   runner startup; on-demand screenshots remain HTTP-only.
2. Keep `ENABLE_PERFORMANCE_TEST_DIAGNOSTICS=NO` for normal remote-control
   sessions. Enable it only for a dedicated memory-diagnostics run.
3. Use a fresh XCTest session after the configured measurement limit.
4. Call `/api/exit` when done so XCTest can tear down cleanly.
5. Periodically clear test data in Xcode → Devices, or reboot the device.

## Running

```bash
# Build + run on a connected device via xcodebuild (resolves swifter via SPM).
DEVICE_UDID=<udid> DEVICE_IP=<device-ip> ./launch_with_xcodebuild.sh

# Or, after building once, launch the installed runner via go-ios.
DEVICE_UDID=<udid> DEVICE_IP=<device-ip> ./launch.sh

# Dedicated memgraph run (large XCTest attachments are expected).
ENABLE_PERFORMANCE_TEST_DIAGNOSTICS=YES \
  DEVICE_UDID=<udid> DEVICE_IP=<device-ip> ./launch_with_xcodebuild.sh
```

Example client calls:

```bash
curl "http://192.168.1.5:18200/api/health"
curl "http://192.168.1.5:18200/api/launch?bundleId=com.rm42.TrashDash"
curl -X POST "http://192.168.1.5:18200/api/activate" -d '{"bundleId":"com.rm42.TrashDash"}' -H "Content-Type: application/json"
curl -X POST "http://192.168.1.5:18200/api/terminate" -d '{"bundleId":"com.rm42.TrashDash"}' -H "Content-Type: application/json"
curl "http://192.168.1.5:18200/api/terminate/com.rm42.TrashDash"
curl "http://192.168.1.5:18200/api/screenshot" -o shot.png
curl "http://192.168.1.5:18200/api/tap?x=0.5&y=0.5&bundleId=com.rm42.TrashDash"
curl "http://192.168.1.5:18200/api/measuring/start?bundleId=com.rm42.TrashDash"
curl "http://192.168.1.5:18200/api/measuring/period/10?bundleId=com.rm42.TrashDash"
curl "http://192.168.1.5:18200/api/measuring/stop"
curl "http://192.168.1.5:18200/api/measuring/status"
curl "http://192.168.1.5:18200/api/exit"
```
