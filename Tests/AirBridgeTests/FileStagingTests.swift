import Foundation
import Testing
@testable import AirBridge

struct FileStagingTests {
    @Test func stage_createsFileWithUUIDName() throws {
        let data = Data("test audio data".utf8)
        let (url, id) = try FileStaging.stage(data: data, filename: "hello.mp3")
        defer { FileStaging.remove(url: url) }

        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(url.pathExtension == "mp3")
        #expect(url.lastPathComponent.contains(id.uuidString))
    }

    @Test func stage_preservesExtension() throws {
        let data = Data("wav data".utf8)
        let (url, _) = try FileStaging.stage(data: data, filename: "song.wav")
        defer { FileStaging.remove(url: url) }

        #expect(url.pathExtension == "wav")
    }

    @Test func stage_noExtension_usesEmptyExtension() throws {
        let data = Data("data".utf8)
        let (url, _) = try FileStaging.stage(data: data, filename: "noext")
        defer { FileStaging.remove(url: url) }

        #expect(url.pathExtension == "")
    }

    @Test func remove_deletesFile() throws {
        let data = Data("delete me".utf8)
        let (url, _) = try FileStaging.stage(data: data, filename: "temp.mp3")
        FileStaging.remove(url: url)

        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func clearAll_removesAllFiles() throws {
        let data = Data("data".utf8)
        let (url1, _) = try FileStaging.stage(data: data, filename: "a.mp3")
        let (url2, _) = try FileStaging.stage(data: data, filename: "b.mp3")

        FileStaging.clearAll()

        #expect(!FileManager.default.fileExists(atPath: url1.path))
        #expect(!FileManager.default.fileExists(atPath: url2.path))
    }
}
