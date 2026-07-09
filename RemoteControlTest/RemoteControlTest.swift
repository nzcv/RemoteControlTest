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
///   *    /api/screenshot/start?interval=1&limit=0 begin periodic screenshots
///   *    /api/screenshot/stop                     stop periodic screenshots
///   *    /api/tap?x=0.5&y=0.5&bundleId=...         tap a normalized point (anchored to the app's orientation)
///   GET  /api/measuring/start?bundleId=...        open an XCTMemoryMetric window on an app
///   GET  /api/measuring/period/{seconds}?bundleId=...  measure for a fixed duration, then auto-close
///   GET  /api/measuring/stop                      close the measured window
///   GET  /api/measuring/status                    report the current measuring state
///   GET  /api/exit                                quit the runner
///
/// `bundleId`, `interval`, and `limit` may be supplied as query parameters or
/// in a JSON request body; `*` accepts any HTTP method.
final class RemoteControlTest: XCTestCase {
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    private let broker = CommandBroker()
    private var server: HttpServer?

    /// Periodic-screenshot schedule. Touched only on the main test thread.
    private var periodic: PeriodicSchedule?

    /// An app whose memory the next loop iteration should open a measured
    /// window on. Armed by a `startMeasuring` command, consumed on the main
    /// test thread (XCTest's `measure` may only run there).
    private var pendingMeasureApp: XCUIApplication?
    /// Optional auto-close duration (seconds) for the pending window; `nil`
    /// leaves it open until an explicit `stopMeasuring`.
    private var pendingMeasureDuration: TimeInterval?
    /// True while a `measure` window is open and draining the broker itself.
    private var measuringActive = false
    /// Coarse measuring lifecycle reported by `/api/measuring/status`:
    /// `idle` before any measurement, `started` while a window is open,
    /// `stopped` after one closes.
    private var measuringState = MeasuringState.idle
    /// Set by a `stopMeasuring` command to close the open window.
    private var measureStopRequested = false

    /// Next due time for the system-permission watcher that auto-accepts
    /// prompts a foregrounded app (e.g. a freshly launched game) raises —
    /// notifications, App tracking, location, photos, Bluetooth, etc. Polled
    /// between commands on the main test thread.
    private var nextPermissionCheck = Date()
    /// The watcher only runs until this deadline. Permission prompts arrive
    /// shortly after an app comes to the foreground, so rather than poll
    /// SpringBoard for the whole (multi-hour) session we open a bounded window
    /// on each launch/activate, then stop. `distantPast` keeps it off until the
    /// first app is foregrounded.
    private var permissionWatchUntil = Date.distantPast

    override func setUpWithError() throws {
        continueAfterFailure = false
        try startServer()
    }

    override func tearDownWithError() throws {
        server?.stop()
        server = nil
    }

    /// The single main-thread consumer. Drains the broker, executing each
    /// command's UI work here, and fires due periodic screenshots between
    /// commands. Runs until a client hits `/api/exit` or the session cap.
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
            drivePeriodicScreenshots()
            drivePermissionPrompts()
            if let app = pendingMeasureApp {
                let duration = pendingMeasureDuration
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
        resetScreenshotsDirectory()
        acceptLocalNetworkPromptIfNeeded()
        XCUIDevice.shared.press(.home)
    }

    /// Wipes any screenshots left on the device by a previous session so the
    /// on-device directory never accumulates across runs. Recreated lazily by
    /// `Config.screenshotsDirectory` on the next capture.
    private func resetScreenshotsDirectory() {
        try? FileManager.default.removeItem(at: Config.screenshotsDirectory)
    }

    /// Opens the bounded permission-watch window, after which
    /// `drivePermissionPrompts()` stops polling SpringBoard. Armed on each
    /// launch/activate, since prompts only appear once an app is foregrounded.
    private func armPermissionWatch() {
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
    /// optional fixed `duration` elapsing, the session deadline, or an exit
    /// request.
    private func runMeasurement(app: XCUIApplication, sessionDeadline: Date, duration: TimeInterval?) {
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
            let windowDeadline = duration.map { Date().addingTimeInterval($0) }
            while !measureStopRequested, !broker.shouldExit, Date() < sessionDeadline {
                if let windowDeadline, Date() >= windowDeadline { break }
                if let command = broker.next(timeout: 0.2) {
                    execute(command)
                }
                drivePeriodicScreenshots()
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
            let data = captureScreenshot(tag: "on-demand")
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

        case .startPeriodicScreenshots(let interval, let limit):
            periodic = PeriodicSchedule(interval: interval, limit: limit)
            command.finish(.json([
                "status": "ok",
                "action": "startScreenshots",
                "interval": interval,
                "limit": limit ?? 0,
            ]))

        case .stopPeriodicScreenshots:
            let captured = periodic?.captured ?? 0
            periodic = nil
            command.finish(.json([
                "status": "ok",
                "action": "stopScreenshots",
                "captured": captured,
            ]))

        case .startMeasuring(let bundleId):
            if measuringActive {
                command.finish(.json([
                    "status": "error",
                    "action": "startMeasuring",
                    "reason": "a measurement is already in progress",
                ]))
            } else {
                pendingMeasureApp = XCUIApplication(bundleIdentifier: bundleId)
                pendingMeasureDuration = nil
                command.finish(.json([
                    "status": "ok",
                    "action": "startMeasuring",
                    "bundleId": bundleId,
                ]))
            }

        case .timedMeasuring(let bundleId, let seconds):
            if measuringActive {
                command.finish(.json([
                    "status": "error",
                    "action": "dtMeasuring",
                    "reason": "a measurement is already in progress",
                ]))
            } else {
                pendingMeasureApp = XCUIApplication(bundleIdentifier: bundleId)
                pendingMeasureDuration = seconds
                command.finish(.json([
                    "status": "ok",
                    "action": "dtMeasuring",
                    "bundleId": bundleId,
                    "seconds": seconds,
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

    /// Fires the next periodic screenshot if its interval has elapsed, and
    /// retires the schedule once an optional capture limit is reached.
    private func drivePeriodicScreenshots() {
        guard var schedule = periodic, Date() >= schedule.nextFireDate else { return }
        captureScreenshot(tag: "periodic-\(schedule.captured)")
        schedule.captured += 1
        schedule.nextFireDate = Date().addingTimeInterval(schedule.interval)
        if let limit = schedule.limit, schedule.captured >= limit {
            periodic = nil
        } else {
            periodic = schedule
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
        dismissPermissionAlertIfPresent(waitTimeout: 0)
    }

    /// Captures a full-screen PNG and writes it to a temp directory on the
    /// device for out-of-band retrieval. The PNG is also returned to the caller
    /// (served directly over HTTP by `/api/screenshot`).
    ///
    /// It is *not* attached to the test result bundle by default:
    /// `XCTAttachment`s live for the whole (multi-hour) session and never get a
    /// chance to be pruned before the runner exits, so keeping every screenshot
    /// would inflate the on-device result bundle (and iOS "System Data") without
    /// bound. The HTTP response and the size-capped temp directory already cover
    /// retrieval; set `ATTACH_SCREENSHOTS=1` to opt back in when debugging.
    @discardableResult
    private func captureScreenshot(tag: String) -> Data {
        let screenshot = XCUIScreen.main.screenshot()
        let data = screenshot.pngRepresentation

        if Config.attachScreenshots {
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = tag
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let url = Config.screenshotsDirectory.appendingPathComponent("\(tag)-\(stamp).png")
        try? data.write(to: url)
        pruneDeviceScreenshots()
        return data
    }

    /// Enforces `Config.maxDeviceScreenshots` on the on-device screenshot
    /// directory by deleting the oldest PNGs once the count exceeds the cap.
    /// A cap of zero or less leaves the directory unbounded.
    private func pruneDeviceScreenshots() {
        let cap = Config.maxDeviceScreenshots
        guard cap > 0 else { return }

        let fm = FileManager.default
        let dir = Config.screenshotsDirectory
        guard let files = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        guard files.count > cap else { return }

        let sorted = files.sorted { lhs, rhs in
            let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lhsDate < rhsDate
        }

        for url in sorted.prefix(files.count - cap) {
            try? fm.removeItem(at: url)
        }
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
        server["/api/screenshot/start"] = { [weak self] request in
            guard let self else { return .internalServerError }
            let params = self.params(request)
            let interval = params["interval"].flatMap(Double.init) ?? 1.0
            let limit = params["limit"].flatMap(Int.init).flatMap { $0 > 0 ? $0 : nil }
            return self.httpResponse(for: self.broker.submit(.startPeriodicScreenshots(interval: interval, limit: limit)))
        }
        server["/api/screenshot/stop"] = { [weak self] _ in
            guard let self else { return .internalServerError }
            return self.httpResponse(for: self.broker.submit(.stopPeriodicScreenshots))
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
        case startPeriodicScreenshots(interval: TimeInterval, limit: Int?)
        case stopPeriodicScreenshots
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

/// Mutable schedule for periodic screenshots, owned by the main thread.
private struct PeriodicSchedule {
    let interval: TimeInterval
    let limit: Int?
    var captured = 0
    var nextFireDate = Date()
}

// MARK: - Configuration

private enum Config {
    static var serverPort: in_port_t { env("SERVER_PORT").flatMap { in_port_t($0) } ?? 18100 }
    static var testBundleIdentifier: String { env("TEST_BUNDLE_IDENTIFIER") ?? "com.idevice.RemoteControlTest" }
    static var runnerBundleIdentifier: String { env("RUNNER_BUNDLE_IDENTIFIER") ?? testBundleIdentifier + ".xctrunner" }
    static var maxSessionSeconds: TimeInterval { env("MAX_SESSION_SECONDS").flatMap(TimeInterval.init) ?? 6 * 60 * 60 }

    /// How often the in-loop watcher scans SpringBoard for a system-permission
    /// alert to auto-accept. Lower is more responsive but queries the UI tree
    /// more often.
    static var permissionWatchInterval: TimeInterval { env("PERMISSION_WATCH_INTERVAL").flatMap(TimeInterval.init) ?? 1.5 }

    /// How long the permission watcher keeps polling after it is armed (each
    /// launch/activate). Prompts arrive soon after an app comes to the
    /// foreground, so a short window suffices; polling stops afterward.
    static var permissionWatchWindow: TimeInterval { env("PERMISSION_WATCH_WINDOW").flatMap(TimeInterval.init) ?? 5 * 60 }

    static var screenshotsDirectory: URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("RemoteControlScreenshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Upper bound on how many PNGs the on-device screenshot directory keeps;
    /// older files past this count are pruned after each capture. A value of
    /// zero or less disables the cap. Override with `MAX_DEVICE_SCREENSHOTS`.
    static var maxDeviceScreenshots: Int { env("MAX_DEVICE_SCREENSHOTS").flatMap(Int.init) ?? 200 }

    /// Whether captured screenshots are also attached to the test result
    /// bundle. Attachments are `keepAlways` and persist for the whole session,
    /// so they accumulate without bound over a multi-hour run and are redundant
    /// with the HTTP response and the size-capped temp directory. Off by
    /// default; enable with `ATTACH_SCREENSHOTS=1` for debugging.
    static var attachScreenshots: Bool {
        switch env("ATTACH_SCREENSHOTS")?.lowercased() {
        case "1", "true", "yes": return true
        default: return false
        }
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
}
