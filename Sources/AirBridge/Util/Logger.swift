import OSLog

enum Log {
    static let http = Logger(subsystem: "com.gsmlg.airbridge", category: "http")
    static let playback = Logger(subsystem: "com.gsmlg.airbridge", category: "playback")
    static let server = Logger(subsystem: "com.gsmlg.airbridge", category: "server")
    static let queue = Logger(subsystem: "com.gsmlg.airbridge", category: "queue")
    static let output = Logger(subsystem: "com.gsmlg.airbridge", category: "output")
}
