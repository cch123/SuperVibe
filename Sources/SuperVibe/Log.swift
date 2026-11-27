import Foundation

private let logTimestamp: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "HH:mm:ss.SSS"
    return f
}()
private let logLock = NSLock()

/// Timestamped line on stderr – always visible in a terminal, never buffered.
func log(_ message: String) {
    logLock.lock()
    defer { logLock.unlock() }
    let line = "\(logTimestamp.string(from: Date())) \(message)\n"
    FileHandle.standardError.write(Data(line.utf8))
}
