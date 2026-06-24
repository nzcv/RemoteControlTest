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
///   GET  /api/screenshot                          capture one screenshot (PNG)
///   *    /api/screenshot/start?interval=1&limit=0 begin periodic screenshots
///   *    /api/screenshot/stop                     stop periodic screenshots
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

    override func setUpWithError() throws {
        continueAfterFailure = false
        try startServer()
        acceptLocalNetworkPromptIfNeeded()
    }

    override func tearDownWithError() throws {
        server?.stop()
        server = nil
    }

    /// The single main-thread consumer. Drains the broker, executing each
    /// command's UI work here, and fires due periodic screenshots between
    /// commands. Runs until a client hits `/api/exit` or the session cap.
    func testRemoteControl() throws {
        // enter background
        XCUIDevice.shared.press(.home)
        // loop
        let deadline = Date().addingTimeInterval(Config.maxSessionSeconds)
        while !broker.shouldExit, Date() < deadline {
            if let command = broker.next(timeout: 0.2) {
                execute(command)
            }
            drivePeriodicScreenshots()
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
            self?.jsonResponse(["status": "ok", "uptime": ProcessInfo.processInfo.systemUptime]) ?? .internalServerError
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

    /// Merges query parameters and a JSON request body into one lookup table.
    private func params(_ request: HttpRequest) -> [String: String] {
        var result: [String: String] = [:]
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
        XCUIApplication(bundleIdentifier: Config.runnerBundleIdentifier).activate()

        let deadline = Date().addingTimeInterval(8)
        repeat {
            triggerLocalNetworkTraffic()

            let alert = springboard.alerts.firstMatch
            if alert.waitForExistence(timeout: 2) {
                for label in ["Allow", "允许", "允許"] {
                    let button = alert.buttons[label]
                    if button.exists { return button.tap() }
                }
                return alert.buttons.allElementsBoundByIndex.last?.tap() ?? ()
            }
        } while Date() < deadline
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
    private let condition = NSCondition()
    private var queue: [Command] = []
    private var exitRequested = false

    var shouldExit: Bool {
        condition.lock(); defer { condition.unlock() }
        return exitRequested
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

/// Mutable schedule for periodic screenshots, owned by the main thread.
private struct PeriodicSchedule {
    let interval: TimeInterval
    let limit: Int?
    var captured = 0
    var nextFireDate = Date()
}

// MARK: - Configuration

private enum Config {
    static var serverPort: in_port_t { env("SERVER_PORT").flatMap { in_port_t($0) } ?? 18200 }
    static var testBundleIdentifier: String { env("TEST_BUNDLE_IDENTIFIER") ?? "com.idevice.RemoteControlTest" }
    static var runnerBundleIdentifier: String { env("RUNNER_BUNDLE_IDENTIFIER") ?? testBundleIdentifier + ".xctrunner" }
    static var maxSessionSeconds: TimeInterval { env("MAX_SESSION_SECONDS").flatMap(TimeInterval.init) ?? 6 * 60 * 60 }

    static var screenshotsDirectory: URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("RemoteControlScreenshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func env(_ key: String) -> String? {
        ProcessInfo.processInfo.environment[key]
    }
}
