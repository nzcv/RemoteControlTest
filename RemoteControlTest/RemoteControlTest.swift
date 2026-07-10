import XCTest
import Foundation
import Swifter

/// Turns an XCUITest runner into a long-lived, remotely controlled agent.
///
/// On launch the test stands up a tiny `swifter` HTTP server on the LAN
/// (`http://{device-ip}:{SERVER_PORT}`) and then parks on a command broker.
/// UI automation in XCUITest must run on the test's main thread, but the
/// server answers each request on its own background thread; the two are
/// bridged by `CommandBroker`, which hands work to the single main-thread
/// consumer in `testRemoteControl()` and blocks the request until the result
/// is ready.
///
///   GET  /api/health                              liveness probe
///   *    /api/launch?bundleId=...                 (re)launch an app to foreground
///   *    /api/activate?bundleId=...               foreground an app (launch if dead)
///   *    /api/terminate?bundleId=...              terminate an app
///   GET  /api/terminate/{bundleId}               terminate an app (path param)
///   GET  /api/screenshot                          capture one screenshot (PNG)
///   *    /api/tap?x=0.5&y=0.5&bundleId=...         tap a normalized point (anchored to the app's orientation)
///   GET  /api/measuring/start?bundleId=...        open an XCTMemoryMetric window on an app
///   GET  /api/measuring/period/{seconds}?bundleId=...  measure for a fixed duration, then auto-close
///   GET  /api/measuring/stop                      close the measured window
///   GET  /api/measuring/status                    report the current measuring state
///   GET  /api/exit                                quit the runner
///
/// `bundleId` may be supplied as a query parameter or in a JSON request body;
/// `*` accepts any HTTP method.
final class RemoteControlTest: XCTestCase {
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    private let broker = CommandBroker()
    private var server: HttpServer?

    /// An app whose memory the next loop iteration should open a measured
    /// window on. Armed by a `startMeasuring` command, consumed on the main
    /// test thread (XCTest's `measure` may only run there).
    private var pendingMeasureApp: XCUIApplication?
    /// Auto-close duration (seconds) for the pending window. Every measurement
    /// is capped by `Config.maxMeasurementSeconds`.
    private var pendingMeasureDuration: TimeInterval?
    /// True while a `measure` window is open and draining the broker itself.
    private var measuringActive = false
    /// Coarse measuring lifecycle reported by `/api/measuring/status`:
    /// `idle` before any measurement, `started` while a window is open,
    /// `stopped` after one closes.
    private var measuringState = MeasuringState.idle
    /// Set by a `stopMeasuring` command to close the open window.
    private var measureStopRequested = false
    /// Number of measurement windows opened in this XCTest session. Memory
    /// diagnostics can create large test attachments, so the count is bounded.
    private var measurementCount = 0

    /// Next due time for the system-permission watcher that auto-accepts
    /// prompts a foregrounded app (e.g. a freshly launched game) raises —
    /// notifications, App tracking, location, photos, Bluetooth, etc. Polled
    /// between commands on the main test thread.
    private var nextPermissionCheck = Date()
    /// The watcher only runs until this deadline. Permission prompts arrive
    /// shortly after an app comes to the foreground, so rather than poll
    /// SpringBoard for the whole long-lived session we open a bounded window
    /// on each launch/activate, then stop. `distantPast` keeps it off until the
    /// first app is foregrounded.
    private var permissionWatchUntil = Date.distantPast

    override func setUpWithError() throws {
        // Match WDA's storage-conservative XCTest defaults. These switches only
        // affect XCTest's automatic diagnostics; the explicit /api/screenshot
        // endpoint continues to return image bytes normally.
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: "DisableScreenshots")
        defaults.set(true, forKey: "DisableDiagnosticScreenRecordings")

        // A command-level XCTest issue should not immediately tear down and
        // relaunch this long-lived agent, which would generate more diagnostics.
        continueAfterFailure = true
        try startServer()
    }

    override func tearDownWithError() throws {
        server?.stop()
        server = nil
    }

    /// The single main-thread consumer. Drains the broker, executing each
    /// command's UI work here. Runs until a client hits `/api/exit` or the
    /// session cap.
    func testRemoteControl() throws {
        // The consumer loop owns initialization: accept the Local Network prompt
        // and background the runner here (serial main-thread work) while health
        // reports `initializing`, then flip to `ready` before draining commands.
        broker.markInitializing()
        prepareSession()
        broker.markReady()

        let deadline = Date().addingTimeInterval(Config.maxSessionSeconds)
        while !broker.shouldExit, Date() < deadline {
            if let command = broker.next(timeout: 0.2) {
                execute(command)
            }
            drivePermissionPrompts()
            if let app = pendingMeasureApp {
                let duration = pendingMeasureDuration ?? Config.maxMeasurementSeconds
                pendingMeasureApp = nil
                pendingMeasureDuration = nil
                runMeasurement(app: app, sessionDeadline: deadline, duration: duration)
            }
        }
    }

    /// Main-thread initialization run as the first step of the consumer loop:
    /// accept the one-time Local Network privacy prompt (cheap on warm launches),
    /// then background the runner so the device returns to SpringBoard.
    private func prepareSession() {
        acceptLocalNetworkPromptIfNeeded()
        XCUIDevice.shared.press(.home)
    }

    /// Opens the bounded permission-watch window, after which
    /// `drivePermissionPrompts()` stops polling SpringBoard. Armed on each
    /// launch/activate, since prompts only appear once an app is foregrounded.
    private func armPermissionWatch() {
        nextPermissionCheck = Date()
        permissionWatchUntil = Date().addingTimeInterval(Config.permissionWatchWindow)
    }

    /// Opens a single `XCTMemoryMetric` window on `app`.
    ///
    /// `measure` runs its block synchronously on this (main test) thread, so the
    /// block itself keeps draining the broker — every other command, including
    /// the `stopMeasuring` that closes the window, still executes while the
    /// measurement is live.
    ///
    /// The window closes on the first of: an explicit `stopMeasuring`, the
    /// bounded `duration` elapsing, the session deadline, or an exit request.
    private func runMeasurement(app: XCUIApplication, sessionDeadline: Date, duration: TimeInterval) {
        let options = XCTMeasureOptions()
        options.invocationOptions = [.manuallyStart, .manuallyStop]
        options.iterationCount = 1

        measuringActive = true
        measuringState = .started
        measureStopRequested = false
        defer {
            measuringActive = false
            measuringState = .stopped
        }

        measure(metrics: [XCTMemoryMetric(application: app)], options: options) {
            startMeasuring()
            let windowDeadline = Date().addingTimeInterval(duration)
            while !measureStopRequested, !broker.shouldExit, Date() < sessionDeadline {
                if Date() >= windowDeadline { break }
                if let command = broker.next(timeout: 0.2) {
                    execute(command)
                }
                drivePermissionPrompts()
            }
            stopMeasuring()
        }
    }

    // MARK: - Command execution (main thread)

    private func execute(_ command: Command) {
        switch command.action {
        case .launch(let bundleId):
            armPermissionWatch()
            let app = XCUIApplication(bundleIdentifier: bundleId)
            if app.state != .notRunning { app.terminate() }
            app.launch()
            let ok = app.wait(for: .runningForeground, timeout: 30)
            command.finish(.json([
                "status": ok ? "ok" : "error",
                "action": "launch",
                "bundleId": bundleId,
                "state": describe(app.state),
            ]))

        case .activate(let bundleId):
            armPermissionWatch()
            let app = XCUIApplication(bundleIdentifier: bundleId)
            app.activate()
            let ok = app.wait(for: .runningForeground, timeout: 30)
            command.finish(.json([
                "status": ok ? "ok" : "error",
                "action": "activate",
                "bundleId": bundleId,
                "state": describe(app.state),
            ]))

        case .terminate(let bundleId):
            let app = XCUIApplication(bundleIdentifier: bundleId)
            app.terminate()
            command.finish(.json([
                "status": "ok",
                "action": "terminate",
                "bundleId": bundleId,
                "state": describe(app.state),
            ]))

        case .screenshot:
            let data = captureScreenshot()
            command.finish(.png(data))

        case .tap(let x, let y, let bundleId):
            // Tap an absolute screen point given as a normalized offset
            // ([0,1] fractions of the screen, resolution/scale independent).
            //
            // The offset is anchored to the foreground app's frame when a
            // bundleId is supplied, otherwise to SpringBoard. This matters for
            // orientation: SpringBoard is portrait-locked, so anchoring there
            // taps the wrong physical point for a landscape app. The app's own
            // frame tracks the current interface orientation and lines up with
            // `XCUIScreen.main.screenshot()`, which callers normalize against.
            let anchor: XCUIApplication = (bundleId?.isEmpty == false)
                ? XCUIApplication(bundleIdentifier: bundleId!)
                : springboard
            let coordinate = anchor.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y))
            coordinate.tap()
            command.finish(.json([
                "status": "ok",
                "action": "tap",
                "x": x,
                "y": y,
            ]))

        case .startMeasuring(let bundleId):
            if measuringActive || pendingMeasureApp != nil {
                command.finish(.json([
                    "status": "error",
                    "action": "startMeasuring",
                    "reason": "a measurement is already in progress",
                ]))
            } else if measurementCount >= Config.maxMeasurementsPerSession {
                command.finish(.json([
                    "status": "error",
                    "action": "startMeasuring",
                    "reason": "measurement limit reached for this session",
                    "limit": Config.maxMeasurementsPerSession,
                ]))
            } else {
                measurementCount += 1
                pendingMeasureApp = XCUIApplication(bundleIdentifier: bundleId)
                pendingMeasureDuration = Config.maxMeasurementSeconds
                command.finish(.json([
                    "status": "ok",
                    "action": "startMeasuring",
                    "bundleId": bundleId,
                    "maxSeconds": Config.maxMeasurementSeconds,
                ]))
            }

        case .timedMeasuring(let bundleId, let seconds):
            if measuringActive || pendingMeasureApp != nil {
                command.finish(.json([
                    "status": "error",
                    "action": "dtMeasuring",
                    "reason": "a measurement is already in progress",
                ]))
            } else if measurementCount >= Config.maxMeasurementsPerSession {
                command.finish(.json([
                    "status": "error",
                    "action": "dtMeasuring",
                    "reason": "measurement limit reached for this session",
                    "limit": Config.maxMeasurementsPerSession,
                ]))
            } else {
                let boundedSeconds = min(seconds, Config.maxMeasurementSeconds)
                measurementCount += 1
                pendingMeasureApp = XCUIApplication(bundleIdentifier: bundleId)
                pendingMeasureDuration = boundedSeconds
                command.finish(.json([
                    "status": "ok",
                    "action": "dtMeasuring",
                    "bundleId": bundleId,
                    "seconds": boundedSeconds,
                    "requestedSeconds": seconds,
                ]))
            }

        case .measuringStatus:
            command.finish(.json([
                "status": "ok",
                "action": "measuringStatus",
                "state": measuringState.rawValue,
            ]))

        case .stopMeasuring:
            if measuringActive {
                measureStopRequested = true
                command.finish(.json(["status": "ok", "action": "stopMeasuring"]))
            } else {
                command.finish(.json([
                    "status": "error",
                    "action": "stopMeasuring",
                    "reason": "no measurement in progress",
                ]))
            }

        case .exit:
            command.finish(.json(["status": "ok", "action": "exit"]))
            broker.requestExit()
        }
    }

    /// System-permission watcher. While the watch window is open (armed on
    /// each launch/activate), periodically accepts any
    /// permission prompt a foregrounded app (e.g. a freshly launched game)
    /// raises — notifications, App tracking, location, photos, Bluetooth,
    /// camera/microphone, etc. — by tapping the most permissive "allow"
    /// button. Throttled by `permissionWatchInterval` and uses a non-blocking
    /// existence check so it never stalls the command loop.
    private func drivePermissionPrompts() {
        guard Date() < permissionWatchUntil else { return }
        guard Date() >= nextPermissionCheck else { return }
        nextPermissionCheck = Date().addingTimeInterval(Config.permissionWatchInterval)
        if dismissPermissionAlertIfPresent(waitTimeout: 0) {
            // Leave a short grace period for a second prompt that may follow,
            // rather than continuing the full watch window.
            permissionWatchUntil = min(
                permissionWatchUntil,
                Date().addingTimeInterval(Config.permissionWatchPostAcceptWindow)
            )
        }
    }

    /// Captures a full-screen PNG and returns it to the caller (served directly
    /// over HTTP by `/api/screenshot`). Nothing is written to the device —
    /// matching WebDriverAgent's in-memory-only screenshot path.
    @discardableResult
    private func captureScreenshot() -> Data {
        XCUIScreen.main.screenshot().pngRepresentation
    }

    // MARK: - swifter server

    private func startServer() throws {
        let server = HttpServer()

        server["/api/health"] = { [weak self] _ in
            guard let self else { return .internalServerError }
            let phase = self.broker.currentPhase
            guard phase == .ready else {
                return self.jsonResponse(
                    ["status": "not_ready", "reason": phase.rawValue],
                    code: 503,
                    reason: "Service Unavailable"
                )
            }
            return self.jsonResponse(["status": "ok", "uptime": ProcessInfo.processInfo.systemUptime])
        }
        server["/api/launch"] = { [weak self] request in
            self?.appCommand(request) { .launch(bundleId: $0) } ?? .internalServerError
        }
        server["/api/activate"] = { [weak self] request in
            self?.appCommand(request) { .activate(bundleId: $0) } ?? .internalServerError
        }
        server["/api/terminate"] = { [weak self] request in
            self?.appCommand(request) { .terminate(bundleId: $0) } ?? .internalServerError
        }
        server.GET["/api/terminate/:bundleId"] = { [weak self] request in
            self?.appCommand(request) { .terminate(bundleId: $0) } ?? .internalServerError
        }
        server["/api/screenshot"] = { [weak self] _ in
            guard let self else { return .internalServerError }
            return self.httpResponse(for: self.broker.submit(.screenshot))
        }
        server["/api/tap"] = { [weak self] request in
            guard let self else { return .internalServerError }
            let params = self.params(request)
            guard let x = params["x"].flatMap(Double.init),
                  let y = params["y"].flatMap(Double.init) else {
                return self.jsonResponse(["status": "error", "reason": "missing or invalid x/y"], code: 400, reason: "Bad Request")
            }
            guard (0...1).contains(x), (0...1).contains(y) else {
                return self.jsonResponse(["status": "error", "reason": "x and y must be normalized in [0, 1]"], code: 400, reason: "Bad Request")
            }
            return self.httpResponse(for: self.broker.submit(.tap(x: x, y: y, bundleId: params["bundleId"])))
        }
        server.GET["/api/measuring/start"] = { [weak self] request in
            self?.appCommand(request) { .startMeasuring(bundleId: $0) } ?? .internalServerError
        }
        server.GET["/api/measuring/period/:seconds"] = { [weak self] request in
            guard let self else { return .internalServerError }
            let params = self.params(request)
            guard let bundleId = params["bundleId"], !bundleId.isEmpty else {
                return self.jsonResponse(["status": "error", "reason": "missing bundleId"], code: 400, reason: "Bad Request")
            }
            guard let seconds = params["seconds"].flatMap(Double.init), seconds > 0 else {
                return self.jsonResponse(["status": "error", "reason": "invalid seconds"], code: 400, reason: "Bad Request")
            }
            return self.httpResponse(for: self.broker.submit(.timedMeasuring(bundleId: bundleId, seconds: seconds)))
        }
        server.GET["/api/measuring/stop"] = { [weak self] _ in
            guard let self else { return .internalServerError }
            return self.httpResponse(for: self.broker.submit(.stopMeasuring))
        }
        server.GET["/api/measuring/status"] = { [weak self] _ in
            guard let self else { return .internalServerError }
            return self.httpResponse(for: self.broker.submit(.measuringStatus))
        }
        server["/api/exit"] = { [weak self] _ in
            guard let self else { return .internalServerError }
            return self.httpResponse(for: self.broker.submit(.exit))
        }

        try server.start(Config.serverPort, forceIPv4: true)
        self.server = server
    }

    /// Shared handler for the app-targeting routes: resolves a `bundleId`,
    /// builds the action, and bridges the result back into an HTTP response.
    private func appCommand(_ request: HttpRequest,
                            _ make: (String) -> Command.Action) -> HttpResponse {
        guard let bundleId = params(request)["bundleId"], !bundleId.isEmpty else {
            return jsonResponse(["status": "error", "reason": "missing bundleId"], code: 400, reason: "Bad Request")
        }
        return httpResponse(for: broker.submit(make(bundleId)))
    }

    // MARK: - Request / response helpers

    /// Merges path placeholders, query parameters, and a JSON request body into
    /// one lookup table. Path placeholders (e.g. `:bundleId`) are exposed under
    /// their bare name (`bundleId`).
    private func params(_ request: HttpRequest) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in request.params {
            result[key.hasPrefix(":") ? String(key.dropFirst()) : key] = value
        }
        for (key, value) in request.queryParams { result[key] = value }
        if !request.body.isEmpty,
           let json = try? JSONSerialization.jsonObject(with: Data(request.body)) as? [String: Any] {
            for (key, value) in json { result[key] = String(describing: value) }
        }
        return result
    }

    private func httpResponse(for result: CommandResult) -> HttpResponse {
        switch result {
        case .json(let object):
            return jsonResponse(object)
        case .png(let data):
            return rawResponse(200, "OK", contentType: "image/png", body: data)
        case .error(let message):
            return jsonResponse(["status": "error", "reason": message], code: 500, reason: "Internal Server Error")
        }
    }

    private func jsonResponse(_ object: [String: Any], code: Int = 200, reason: String = "OK") -> HttpResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        return rawResponse(code, reason, contentType: "application/json", body: data)
    }

    private func rawResponse(_ code: Int, _ reason: String, contentType: String, body: Data) -> HttpResponse {
        .raw(code, reason, ["Content-Type": contentType, "Connection": "close"]) { writer in
            try writer.write(body)
        }
    }

    private func describe(_ state: XCUIApplication.State) -> String {
        switch state {
        case .notRunning: return "notRunning"
        case .runningForeground: return "runningForeground"
        case .runningBackground: return "runningBackground"
        case .runningBackgroundSuspended: return "runningBackgroundSuspended"
        case .unknown: return "unknown"
        @unknown default: return "unknown"
        }
    }

    // MARK: - System permission prompts (Local Network / wireless data)

    /// iOS gates LAN access behind one-time privacy prompts the XCTRunner never
    /// answers on its own: the Local Network prompt and, on cellular-capable
    /// devices, a "use wireless data" prompt. Bring the runner forward, generate
    /// outbound LAN traffic to raise them, then accept; the choice is cached for
    /// subsequent launches.
    ///
    /// The prompt only fires on *outbound* local-network traffic, and a single
    /// connection to our own unicast IP is an unreliable trigger. Apple's
    /// guidance is to send an IPv4 UDP broadcast, so we do that (plus a poke at
    /// our now-live server) and retry in a short loop while polling for the alert.
    private func acceptLocalNetworkPromptIfNeeded() {
        // 1) Already granted on a previous launch: the system caches the choice,
        //    so skip the whole dance (the big win on warm relaunches).
        if Config.localNetworkGranted { return }

        XCUIApplication(bundleIdentifier: Config.runnerBundleIdentifier).activate()

        // 2) Probe first: if we can already reach our own server over the LAN,
        //    access is granted and no prompt will appear, so don't waste time.
        if probeLocalServer(timeout: 0.6) {
            Config.localNetworkGranted = true
            return
        }

        // 3) Provoke and accept the prompt(s), retrying briefly. Two different
        //    system alerts can block the LAN server — the Local Network prompt
        //    and the cellular "use wireless data" prompt — and they may appear
        //    one after another, so we dismiss whatever is on screen each pass
        //    and keep going until the server is actually reachable.
        let deadline = Date().addingTimeInterval(5)
        repeat {
            triggerLocalNetworkTraffic()
            dismissPermissionAlertIfPresent()

            // The server becoming reachable over the LAN is the real signal
            // that access was granted, so let it short-circuit the loop.
            if probeLocalServer(timeout: 0.3) {
                Config.localNetworkGranted = true
                return
            }
        } while !broker.shouldExit && Date() < deadline
    }

    /// Most permissive "allow" buttons, in priority order, across the system
    /// permission alerts we auto-accept. Two situations rely on this list: the
    /// runner's own Local Network / cellular prompts during init, and the
    /// prompts a foregrounded game raises after launch (notifications, App
    /// tracking, location, photos, Bluetooth, camera/microphone, ...). For
    /// each alert the first matching label is tapped, so more-specific /
    /// more-permissive labels come first; a Wi-Fi-only or one-time-allow
    /// choice is kept as a sufficient fallback. The explicit allow-list also
    /// means we never tap "Don't Allow" / "不允许".
    private static let permissionAllowLabels = [
        // Cellular "use wireless data" prompt — prefer full access.
        "无线局域网与蜂窝网络", "WLAN 与蜂窝网络", "WLAN与蜂窝网络",
        "Wi-Fi & Cellular Data", "Wi-Fi & Cellular",
        // Wi-Fi-only choice on the same prompt is sufficient for LAN access.
        "仅限无线局域网", "无线局域网", "WLAN", "Wi-Fi",
        // Location prompt — prefer the most persistent grant.
        "始终允许", "Always Allow",
        "使用App时允许", "使用 App 时允许", "Allow While Using App",
        "允许一次", "Allow Once",
        // Photos prompt — full library access.
        "允许访问所有照片", "Allow Access to All Photos",
        // Generic allow / confirm for the remaining prompts (notifications,
        // App tracking, Bluetooth, camera, microphone, contacts, ...).
        "允许", "允許", "好", "好的", "确定",
        "Allow", "OK",
    ]

    /// Taps the most permissive allow button on any system permission alert
    /// currently shown by SpringBoard, using `permissionAllowLabels`. No-op
    /// when no alert is present or none of the known buttons match. Returns
    /// whether a button was tapped. `waitTimeout` of 0 does a non-blocking
    /// existence check (used by the in-loop watcher); a positive value waits
    /// for the alert to appear (used during one-shot init).
    @discardableResult
    private func dismissPermissionAlertIfPresent(waitTimeout: TimeInterval = 1) -> Bool {
        let alert = springboard.alerts.firstMatch
        let present = waitTimeout > 0 ? alert.waitForExistence(timeout: waitTimeout) : alert.exists
        guard present else { return false }
        for label in Self.permissionAllowLabels where alert.buttons[label].exists {
            alert.buttons[label].tap()
            return true
        }
        return false
    }

    /// Synchronously probes our own server's `/api/health` over the LAN unicast
    /// address with a short timeout. Returns `true` on any HTTP response (the
    /// connection succeeding is what signals Local Network access is granted).
    private func probeLocalServer(timeout: TimeInterval) -> Bool {
        guard let ip = primaryIPAddress(),
              let url = URL(string: "http://\(ip):\(Config.serverPort)/api/health") else {
            return false
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = timeout

        let semaphore = DispatchSemaphore(value: 0)
        var reachable = false
        let task = URLSession.shared.dataTask(with: request) { _, response, _ in
            reachable = (response as? HTTPURLResponse) != nil
            semaphore.signal()
        }
        task.resume()
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            task.cancel()
            return false
        }
        return reachable
    }

    /// Emits outbound LAN traffic to provoke the Local Network privacy prompt:
    /// an IPv4 UDP broadcast (Apple's recommended trigger) plus a request to our
    /// own server over its unicast LAN address.
    private func triggerLocalNetworkTraffic() {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        if fd >= 0 {
            var enabled: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &enabled, socklen_t(MemoryLayout<Int32>.size))

            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = Config.serverPort.bigEndian
            addr.sin_addr.s_addr = in_addr_t(0xffff_ffff) // 255.255.255.255

            let payload = Array("ping".utf8)
            _ = withUnsafePointer(to: &addr) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    sendto(fd, payload, payload.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            close(fd)
        }

        if let ip = primaryIPAddress(),
           let url = URL(string: "http://\(ip):\(Config.serverPort)/api/health") {
            URLSession.shared.dataTask(with: url) { _, _, _ in }.resume()
        }
    }

    /// First IPv4 address on the primary Wi-Fi interface (en0).
    private func primaryIPAddress() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        defer { freeifaddrs(ifaddr) }

        var address: String?
        var pointer = ifaddr
        while let interface = pointer?.pointee {
            defer { pointer = interface.ifa_next }
            guard interface.ifa_addr.pointee.sa_family == UInt8(AF_INET),
                  String(cString: interface.ifa_name) == "en0" else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                           &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                address = String(cString: host)
            }
        }
        return address
    }
}

// MARK: - Command broker

/// A unit of UI work requested by the server and executed on the main thread.
/// The originating server thread blocks on `wait(timeout:)` until the main
/// thread calls `finish(_:)`, giving each HTTP request a synchronous result.
private final class Command {
    enum Action {
        case launch(bundleId: String)
        case activate(bundleId: String)
        case terminate(bundleId: String)
        case screenshot
        case tap(x: Double, y: Double, bundleId: String?)
        case startMeasuring(bundleId: String)
        case timedMeasuring(bundleId: String, seconds: TimeInterval)
        case stopMeasuring
        case measuringStatus
        case exit
    }

    let action: Action
    private let semaphore = DispatchSemaphore(value: 0)
    private var result: CommandResult = .error("no result")

    init(_ action: Action) { self.action = action }

    func finish(_ result: CommandResult) {
        self.result = result
        semaphore.signal()
    }

    func wait(timeout: TimeInterval) -> CommandResult {
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            return .error("command timed out")
        }
        return result
    }
}

private enum CommandResult {
    case json([String: Any])
    case png(Data)
    case error(String)
}

/// Thread-safe FIFO bridging the server's background threads to the single
/// main-thread consumer.
private final class CommandBroker {
    /// Lifecycle of the main-thread consumer, surfaced via `/api/health`:
    /// `notStarted` before the loop, `initializing` during setup
    /// (prompt accept / backgrounding), `ready` once commands are drained.
    enum Phase: String {
        case notStarted
        case initializing
        case ready
    }

    private let condition = NSCondition()
    private var queue: [Command] = []
    private var exitRequested = false
    private var phase: Phase = .notStarted

    var shouldExit: Bool {
        condition.lock(); defer { condition.unlock() }
        return exitRequested
    }

    var currentPhase: Phase {
        condition.lock(); defer { condition.unlock() }
        return phase
    }

    func markInitializing() {
        condition.lock()
        phase = .initializing
        condition.unlock()
    }

    func markReady() {
        condition.lock()
        phase = .ready
        condition.unlock()
    }

    /// Called on a server thread: enqueues work and blocks until it completes.
    func submit(_ action: Command.Action, timeout: TimeInterval = 60) -> CommandResult {
        let command = Command(action)
        condition.lock()
        queue.append(command)
        condition.signal()
        condition.unlock()
        return command.wait(timeout: timeout)
    }

    /// Called on the main thread: returns the next command, waiting up to
    /// `timeout` seconds for one to arrive.
    func next(timeout: TimeInterval) -> Command? {
        condition.lock()
        defer { condition.unlock() }
        if queue.isEmpty {
            condition.wait(until: Date().addingTimeInterval(timeout))
        }
        return queue.isEmpty ? nil : queue.removeFirst()
    }

    func requestExit() {
        condition.lock()
        exitRequested = true
        condition.signal()
        condition.unlock()
    }
}

/// Coarse measuring lifecycle exposed by `/api/measuring/status`.
private enum MeasuringState: String {
    case idle
    case started
    case stopped
}

// MARK: - Configuration

private enum Config {
    static var serverPort: in_port_t { env("SERVER_PORT").flatMap { in_port_t($0) } ?? 18100 }
    static var testBundleIdentifier: String { env("TEST_BUNDLE_IDENTIFIER") ?? "com.idevice.RemoteControlTest" }
    static var runnerBundleIdentifier: String { env("RUNNER_BUNDLE_IDENTIFIER") ?? testBundleIdentifier + ".xctrunner" }
    static var maxSessionSeconds: TimeInterval { positiveTimeInterval("MAX_SESSION_SECONDS") ?? 60 * 60 }

    /// Hard cap for one XCTMemoryMetric window. A client may request a shorter
    /// period, but never a longer one.
    static var maxMeasurementSeconds: TimeInterval { positiveTimeInterval("MAX_MEASUREMENT_SECONDS") ?? 60 }

    /// Large memory diagnostics scale with measurement count, so a fresh XCTest
    /// session is required after this many windows.
    static var maxMeasurementsPerSession: Int {
        guard let value = env("MAX_MEASUREMENTS_PER_SESSION").flatMap(Int.init), value > 0 else {
            return 1
        }
        return value
    }

    /// How often the in-loop watcher scans SpringBoard for a system-permission
    /// alert to auto-accept. Lower is more responsive but queries the UI tree
    /// more often.
    static var permissionWatchInterval: TimeInterval { positiveTimeInterval("PERMISSION_WATCH_INTERVAL") ?? 1.5 }

    /// How long the permission watcher keeps polling after it is armed (each
    /// launch/activate). Prompts arrive soon after an app comes to the
    /// foreground, so a short window suffices; polling stops afterward.
    static var permissionWatchWindow: TimeInterval { positiveTimeInterval("PERMISSION_WATCH_WINDOW") ?? 30 }

    /// After accepting one prompt, keep watching briefly for a chained prompt.
    static var permissionWatchPostAcceptWindow: TimeInterval {
        positiveTimeInterval("PERMISSION_WATCH_POST_ACCEPT_SECONDS") ?? 5
    }

    /// Whether the one-time Local Network privacy prompt has already been
    /// accepted. iOS persists the system permission per app, so caching our own
    /// decision lets warm relaunches skip the prompt-provoking loop entirely.
    private static let localNetworkGrantedKey = "RemoteControl.localNetworkGranted"
    static var localNetworkGranted: Bool {
        get { UserDefaults.standard.bool(forKey: localNetworkGrantedKey) }
        set { UserDefaults.standard.set(newValue, forKey: localNetworkGrantedKey) }
    }

    private static func env(_ key: String) -> String? {
        ProcessInfo.processInfo.environment[key]
    }

    private static func positiveTimeInterval(_ key: String) -> TimeInterval? {
        guard let value = env(key).flatMap(TimeInterval.init), value > 0 else { return nil }
        return value
    }
}
