import OSLog

enum Log {
    static let http = Logger(subsystem: "com.gsmlg.airbridge", category: "http")
    static let playback = Logger(subsystem: "com.gsmlg.airbridge", category: "playback")
    static let server = Logger(subsystem: "com.gsmlg.airbridge", category: "server")
}
