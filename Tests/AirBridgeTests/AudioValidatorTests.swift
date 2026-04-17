import Testing
import Foundation
@testable import AirBridge

@Test func validate_fileNotFound_returnsError() throws {
    let result = AudioValidator.validate(path: "/nonexistent/file.mp3")
    #expect(result == .failure(.fileNotFound))
}

@Test func validate_unsupportedFormat_returnsError() throws {
    let tmpDir = FileManager.default.temporaryDirectory
    let file = tmpDir.appendingPathComponent("test.ogg")
    try Data([0x01]).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }

    let result = AudioValidator.validate(path: file.path)
    #expect(result == .failure(.unsupportedFormat))
}

@Test func validate_emptyFile_returnsError() throws {
    let tmpDir = FileManager.default.temporaryDirectory
    let file = tmpDir.appendingPathComponent("empty.mp3")
    try Data().write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }

    let result = AudioValidator.validate(path: file.path)
    #expect(result == .failure(.emptyFile))
}

@Test func validate_validMp3_returnsSuccess() throws {
    let tmpDir = FileManager.default.temporaryDirectory
    let file = tmpDir.appendingPathComponent("valid.mp3")
    try Data([0xFF, 0xFB, 0x90, 0x00]).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }

    let result = AudioValidator.validate(path: file.path)
    #expect(result == .success(file.path))
}

@Test func validate_supportedExtensions() {
    let supported = AudioValidator.supportedExtensions
    #expect(supported.contains("mp3"))
    #expect(supported.contains("wav"))
    #expect(supported.contains("m4a"))
    #expect(supported.contains("aiff"))
}

@Test func validationError_descriptions() {
    #expect(AudioValidationError.fileNotFound.errorDescription != nil)
    #expect(AudioValidationError.notReadable.errorDescription != nil)
    #expect(AudioValidationError.unsupportedFormat.errorDescription != nil)
    #expect(AudioValidationError.emptyFile.errorDescription != nil)
}

@Test func validateExtension_supported() {
    let result = AudioValidator.validateExtension("test.mp3")
    #expect(result == .success("mp3"))
}

@Test func validateExtension_unsupported() {
    let result = AudioValidator.validateExtension("test.ogg")
    #expect(result == .failure(.unsupportedFormat))
}
