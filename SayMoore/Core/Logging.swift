import Foundation
import os

enum Log {
    static let subsystem = "com.seemoretmoore.saymoore"

    static let app         = Logger(subsystem: subsystem, category: "app")
    static let hotkey      = Logger(subsystem: subsystem, category: "hotkey")
    static let audio       = Logger(subsystem: subsystem, category: "audio")
    static let vad         = Logger(subsystem: subsystem, category: "vad")
    static let transcribe  = Logger(subsystem: subsystem, category: "transcribe")
    static let cleanup     = Logger(subsystem: subsystem, category: "cleanup")
    static let paste       = Logger(subsystem: subsystem, category: "paste")
    static let context     = Logger(subsystem: subsystem, category: "context")
    static let presets     = Logger(subsystem: subsystem, category: "presets")
    static let history     = Logger(subsystem: subsystem, category: "history")
    static let permissions = Logger(subsystem: subsystem, category: "permissions")
    static let model       = Logger(subsystem: subsystem, category: "model")
    static let pipeline    = Logger(subsystem: subsystem, category: "pipeline")
}
