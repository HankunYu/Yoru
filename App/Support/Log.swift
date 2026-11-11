import os

/// Unified logging categories. Streamed by `ios-run` / Console.app under subsystem `com.hankunyu.Yoru`.
enum Log {
    static let app = Logger(subsystem: "com.hankunyu.Yoru", category: "app")
    static let mpv = Logger(subsystem: "com.hankunyu.Yoru", category: "mpv")
    static let player = Logger(subsystem: "com.hankunyu.Yoru", category: "player")
}
