import Foundation
import os

enum FileStaging {
    static var directory: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".airbridge")
            .appendingPathComponent("queue")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func stage(data: Data, filename: String) throws -> (URL, UUID) {
        let id = UUID()
        let ext = (filename as NSString).pathExtension
        let name = ext.isEmpty ? id.uuidString : "\(id.uuidString).\(ext)"
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        Log.queue.info("Staged \(filename, privacy: .public) → \(url.lastPathComponent, privacy: .public)")
        return (url, id)
    }

    static func remove(url: URL) {
        try? FileManager.default.removeItem(at: url)
        Log.queue.info("Removed staged file: \(url.lastPathComponent, privacy: .public)")
    }

    static func clearAll() {
        let dir = directory
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return
        }
        for file in files {
            try? FileManager.default.removeItem(at: file)
        }
        Log.queue.info("Cleared all staged files")
    }
}
