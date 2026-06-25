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
| any | `/api/screenshot/start` | `interval` (s, default `1`), `limit` (0 = unlimited) | Begin periodic screenshots |
| any | `/api/screenshot/stop` | – | Stop periodic screenshots |
| GET | `/api/startMeasuring` | `bundleId` | Open an `XCTMemoryMetric` window on an app; other commands keep working while it is open |
| GET | `/api/dtMeasuring/{seconds}` | `seconds` (path), `bundleId` | Open a measured window that auto-closes after `seconds` |
| GET | `/api/stopMeasuring` | – | Close the measured window (footprint is harvested into the `.xcresult`) |
| GET | `/api/exit` | – | Quit the runner |

Periodic and on-demand screenshots are attached to the `.xcresult` bundle and
also written to a `RemoteControlScreenshots` folder in the runner's temp
directory on the device.

## Environment variables

| Variable | Default | Purpose |
| -------- | ------- | ------- |
| `SERVER_PORT` | `18200` | Port the swifter server binds |
| `MAX_SESSION_SECONDS` | `21600` | Hard cap on how long the runner stays alive |

## Running

```bash
# Build + run on a connected device via xcodebuild (resolves swifter via SPM).
DEVICE_UDID=<udid> ./launch_with_xcodebuild.sh

# Or, after building once, launch the installed runner via go-ios.
./launch.sh
```

Example client calls:

```bash
curl "http://192.168.1.5:18200/api/health"
curl "http://192.168.1.5:18200/api/launch?bundleId=com.rm42.TrashDash"
curl -X POST "http://192.168.1.5:18200/api/activate" -d '{"bundleId":"com.rm42.TrashDash"}' -H "Content-Type: application/json"
curl -X POST "http://192.168.1.5:18200/api/terminate" -d '{"bundleId":"com.rm42.TrashDash"}' -H "Content-Type: application/json"
curl "http://192.168.1.5:18200/api/terminate/com.rm42.TrashDash"
curl "http://192.168.1.5:18200/api/screenshot" -o shot.png
curl "http://192.168.1.5:18200/api/screenshot/start?interval=2&limit=10"
curl "http://192.168.1.5:18200/api/startMeasuring?bundleId=com.rm42.TrashDash"
curl "http://192.168.1.5:18200/api/dtMeasuring/10?bundleId=com.rm42.TrashDash"
curl "http://192.168.1.5:18200/api/stopMeasuring"
curl "http://192.168.1.5:18200/api/exit"
```
