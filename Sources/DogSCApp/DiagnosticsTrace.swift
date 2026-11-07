import Foundation

/// Intel Mac bring-up aid: `log show` and `lsof` are unavailable inside the
/// sandbox this app was built from, so the recorder also mirrors its lifecycle
/// milestones into a plain text file that can be tail'd from Terminal.
/// This is diagnostics-only and never affects the capture pipeline.
enum DiagnosticsTrace {
    private static let queue = DispatchQueue(label: "cn.laogou.dogsc.trace")
    private static let lock = NSLock()
    private static var directoryCreated = false

    private static var fileURL: URL? {
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }
        let directory = base.appendingPathComponent("DogSC", isDirectory: true)
        if !directoryCreated {
            try? FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            directoryCreated = true
        }
        return directory.appendingPathComponent("diagnostics.log")
    }

    static func write(_ message: String) {
        queue.async {
            guard let url = fileURL else { return }
            lock.lock()
            defer { lock.unlock() }
            let stamp = ISO8601DateFormatter().string(from: Date())
            let line = "[\(stamp)] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            if FileManager.default.fileExists(atPath: url.path) {
                if let handle = try? FileHandle(forWritingTo: url) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    try? handle.synchronize()
                    handle.closeFile()
                }
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }
}
