import Foundation

/// 简易日志器：同时输出到 stderr 和 ~/Library/Logs/DoubaoVoiceApp/app.log。
final class Logger {
    enum Level: String {
        case debug = "DEBUG"
        case info = "INFO"
        case warn = "WARN"
        case error = "ERROR"
    }

    static let shared = Logger()

    private let queue = DispatchQueue(label: "com.doubaovoiceapp.logger")
    private let dateFormatter: DateFormatter
    private let fileURL: URL?
    private var fileHandle: FileHandle?

    private init() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        dateFormatter = formatter

        let fm = FileManager.default
        if let logsDir = fm.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("DoubaoVoiceApp", isDirectory: true)
        {
            try? fm.createDirectory(at: logsDir, withIntermediateDirectories: true)
            let url = logsDir.appendingPathComponent("app.log")
            if !fm.fileExists(atPath: url.path) {
                fm.createFile(atPath: url.path, contents: nil)
            }
            fileURL = url
            fileHandle = try? FileHandle(forWritingTo: url)
            _ = try? fileHandle?.seekToEnd()
        } else {
            fileURL = nil
            fileHandle = nil
        }
    }

    var logFilePath: String? { fileURL?.path }

    func debug(_ message: @autoclosure () -> String) { write(.debug, message()) }
    func info(_ message: @autoclosure () -> String) { write(.info, message()) }
    func warn(_ message: @autoclosure () -> String) { write(.warn, message()) }
    func error(_ message: @autoclosure () -> String) { write(.error, message()) }

    private func write(_ level: Level, _ message: String) {
        let timestamp = dateFormatter.string(from: Date())
        let line = "\(timestamp) [\(level.rawValue)] \(message)\n"
        queue.async { [weak self] in
            FileHandle.standardError.write(Data(line.utf8))
            if let handle = self?.fileHandle, let data = line.data(using: .utf8) {
                try? handle.write(contentsOf: data)
            }
        }
    }
}
