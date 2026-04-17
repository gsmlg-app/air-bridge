import Foundation
import Hummingbird
import MultipartKit
import NIOCore
import os

enum MultipartFileParser {
    struct UploadedFile {
        let filename: String
        let data: Data
        let contentType: String?
    }

    static func extractFile(from request: Request, maxSize: Int = 50 * 1024 * 1024) async throws -> UploadedFile {
        // Validate content type
        guard let contentTypeHeader = request.headers[.contentType],
              contentTypeHeader.contains("multipart/form-data") else {
            throw MultipartUploadError.notMultipart
        }

        guard let boundary = extractBoundary(from: contentTypeHeader) else {
            throw MultipartUploadError.noBoundary
        }

        // Collect body into a ByteBuffer
        let bodyBuffer = try await request.body.collect(upTo: maxSize)

        // Use MultipartKit 4.x callback-based API:
        //   MultipartParser.onHeader(name, value)  — called for each header in a part
        //   MultipartParser.onBody(ByteBuffer)      — called with body chunks
        //   MultipartParser.onPartComplete()        — called when a part is finished
        //   MultipartParser.execute(ByteBuffer)     — drives the parse
        let parser = MultipartKit.MultipartParser(boundary: boundary)

        // Accumulated parts
        struct ParsedPart {
            var headers: [(name: String, value: String)] = []
            var bodyBuffer: ByteBuffer = ByteBuffer()
        }

        var parts: [ParsedPart] = []
        var currentPart = ParsedPart()

        parser.onHeader = { name, value in
            currentPart.headers.append((name: name, value: value))
        }

        parser.onBody = { chunk in
            currentPart.bodyBuffer.writeBuffer(&chunk)
        }

        parser.onPartComplete = {
            parts.append(currentPart)
            currentPart = ParsedPart()
        }

        try parser.execute(bodyBuffer)

        // Find the part with Content-Disposition name="file"
        guard let filePart = parts.first(where: { part in
            guard let disposition = part.headers.first(where: { $0.name.lowercased() == "content-disposition" })?.value else {
                return false
            }
            return extractParam("name", from: disposition) == "file"
        }) else {
            throw MultipartUploadError.noFileField
        }

        guard filePart.bodyBuffer.readableBytes > 0 else {
            throw MultipartUploadError.emptyFile
        }

        let disposition = filePart.headers.first(where: { $0.name.lowercased() == "content-disposition" })?.value
        let filename = disposition.flatMap { extractParam("filename", from: $0) } ?? "upload"
        let data = Data(buffer: filePart.bodyBuffer)

        let partContentType = filePart.headers.first(where: { $0.name.lowercased() == "content-type" })?.value

        Log.http.info("Parsed multipart upload: \(filename, privacy: .public), \(data.count) bytes")

        return UploadedFile(
            filename: filename,
            data: data,
            contentType: partContentType
        )
    }

    private static func extractBoundary(from contentType: String) -> String? {
        return extractParam("boundary", from: contentType)
    }

    /// Extracts a named parameter value from a header value string like:
    ///   form-data; name="file"; filename="audio.mp3"
    ///   multipart/form-data; boundary=----WebKitFormBoundary
    private static func extractParam(_ param: String, from header: String) -> String? {
        let parts = header.components(separatedBy: ";")
        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            let prefix = "\(param)="
            guard trimmed.hasPrefix(prefix) else { continue }
            var value = String(trimmed.dropFirst(prefix.count))
            // Strip surrounding quotes if present
            if value.hasPrefix("\"") && value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            return value
        }
        return nil
    }
}

enum MultipartUploadError: Error, Sendable {
    case notMultipart
    case noBoundary
    case noFileField
    case emptyFile
    case tooLarge

    var errorCode: String {
        switch self {
        case .notMultipart: return "not_multipart"
        case .noBoundary: return "invalid_multipart"
        case .noFileField: return "missing_file_field"
        case .emptyFile: return "empty_file"
        case .tooLarge: return "file_too_large"
        }
    }
}
