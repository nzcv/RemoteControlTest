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
        acceptLocalNetworkPromptIfNeeded()
        XCUIDevice.shared.press(.home)
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
            }
            stopMeasuring()
        }
    }

    // MARK: - Command execution (main thread)

    private func execute(_ command: Command) {
        switch command.action {
        case .launch(let bundleId):
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

    /// Captures a full-screen PNG, attaches it to the result bundle, and also
    /// writes it to a temp directory on the device for out-of-band retrieval.
    @discardableResult
    private func captureScreenshot(tag: String) -> Data {
        let screenshot = XCUIScreen.main.screenshot()
        let data = screenshot.pngRepresentation

        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = tag
        attachment.lifetime = .keepAlways
        add(attachment)

        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let url = Config.screenshotsDirectory.appendingPathComponent("\(tag)-\(stamp).png")
        try? data.write(to: url)
        return data
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

    // MARK: - Local Network privacy prompt

    /// iOS gates LAN access behind a one-time Local Network privacy prompt that
    /// the XCTRunner never answers on its own. Bring the runner forward, generate
    /// outbound LAN traffic to raise the prompt, then accept it; the choice is
    /// cached for subsequent launches.
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

        // 3) Provoke and accept the prompt, retrying briefly. Re-probe each pass
        //    so a silent grant short-circuits the loop.
        let deadline = Date().addingTimeInterval(5)
        repeat {
            triggerLocalNetworkTraffic()

            let alert = springboard.alerts.firstMatch
            if alert.waitForExistence(timeout: 1) {
                for label in ["Allow", "允许", "允許"] {
                    let button = alert.buttons[label]
                    if button.exists {
                        button.tap()
                        Config.localNetworkGranted = true
                        return
                    }
                }
                alert.buttons.allElementsBoundByIndex.last?.tap()
                Config.localNetworkGranted = true
                return
            }

            if probeLocalServer(timeout: 0.3) {
                Config.localNetworkGranted = true
                return
            }
        } while !broker.shouldExit && Date() < deadline
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

    static var screenshotsDirectory: URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("RemoteControlScreenshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
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
