import Foundation

enum CWLog {
    enum Domain: String {
        case app = "APP"
        case auth = "AUTH"
        case net = "NET"
        case cable = "CABLE"
        case ws = "WS"
        case sync = "SYNC"
        case send = "SEND"
        case ui = "UI"
    }

    private static let lock = NSLock()
    private static var sink: LogSink?
    private static var consoleEnabled = false

    static func install(sink: LogSink?, console: Bool) {
        lock.lock()
        self.sink = sink
        self.consoleEnabled = console
        lock.unlock()
    }

    static func d(_ domain: Domain, _ line: @autoclosure () -> String) { log(.debug, domain, line()) }
    static func i(_ domain: Domain, _ line: @autoclosure () -> String) { log(.info, domain, line()) }
    static func w(_ domain: Domain, _ line: @autoclosure () -> String) { log(.warning, domain, line()) }
    static func e(_ domain: Domain, _ line: @autoclosure () -> String) { log(.error, domain, line()) }

    private static func log(_ level: LogLevel, _ domain: Domain, _ line: String) {
        lock.lock()
        let sink = self.sink
        let console = consoleEnabled
        lock.unlock()
        if console {
            print("[Chatwoot][\(domain.rawValue)] \(line)")
        }
        if level >= .info {
            sink?.log(level: level, domain: domain.rawValue, line: line, error: nil)
        }
    }
}
