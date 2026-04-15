import Foundation

enum AudioValidationError: Error, Equatable, Sendable {
    case fileNotFound
    case notReadable
    case unsupportedFormat
    case emptyFile

    var errorDescription: String {
        switch self {
        case .fileNotFound: "File does not exist at path"
        case .notReadable: "File is not readable"
        case .unsupportedFormat: "Unsupported audio format"
        case .emptyFile: "File is empty"
        }
    }

    var errorCode: String {
        switch self {
        case .fileNotFound: "file_not_found"
        case .notReadable: "not_readable"
        case .unsupportedFormat: "unsupported_format"
        case .emptyFile: "empty_file"
        }
    }
}

enum AudioValidator {
    static let supportedExtensions: Set<String> = ["mp3", "wav", "m4a", "aiff"]

    static func validate(path: String) -> Result<String, AudioValidationError> {
        let fm = FileManager.default

        guard fm.fileExists(atPath: path) else {
            return .failure(.fileNotFound)
        }

        guard fm.isReadableFile(atPath: path) else {
            return .failure(.notReadable)
        }

        let ext = (path as NSString).pathExtension.lowercased()
        guard supportedExtensions.contains(ext) else {
            return .failure(.unsupportedFormat)
        }

        guard let attrs = try? fm.attributesOfItem(atPath: path),
              let size = attrs[.size] as? UInt64,
              size > 0 else {
            return .failure(.emptyFile)
        }

        return .success(path)
    }
}
