import Foundation
import SwiftUI

enum LogLevel: String, Codable, Sendable {
    case info
    case success
    case warn
    case error

    var color: Color {
        switch self {
        case .info: return Theme.textSecondary
        case .success: return Theme.green
        case .warn: return Theme.orange
        case .error: return Theme.aqua
        }
    }

    var glyph: String {
        switch self {
        case .info: return "•"
        case .success: return "✓"
        case .warn: return "▲"
        case .error: return "✕"
        }
    }
}

struct LogEntry: Identifiable, Sendable {
    let id = UUID()
    let time: Date
    let level: LogLevel
    let source: String
    let message: String
}

protocol LogSink: Sendable {
    func emit(_ level: LogLevel, _ source: String, _ message: String)
}

@MainActor
final class SystemLog: ObservableObject, @unchecked Sendable {
    @Published private(set) var entries: [LogEntry] = []
    static let capacity = 600

    func post(_ level: LogLevel, _ source: String, _ message: String) {
        entries.append(LogEntry(time: Date(), level: level, source: source, message: message))
        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
        }
    }

    func clear() {
        entries.removeAll()
    }
}

extension SystemLog: LogSink {
    nonisolated func emit(_ level: LogLevel, _ source: String, _ message: String) {
        Task { @MainActor in
            self.post(level, source, message)
        }
    }
}

struct ConsoleLogSink: LogSink {
    func emit(_ level: LogLevel, _ source: String, _ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        print("[\(stamp)] [\(level.rawValue.uppercased())] [\(source)] \(message)")
    }
}
