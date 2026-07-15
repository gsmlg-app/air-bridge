import Foundation
import Hummingbird
import MultipartKit
import NIOCore
import os

enum MultipartFileParser {
    static let defaultMaxFileBytes = 50 * 1024 * 1024
    static let maxRequestOverheadBytes = 64 * 1024
    static let maxMultipartMetadataBytes = 16 * 1024
    static let maxFilenameBytes = 1024
    static let maxBoundaryBytes = 70
    static let fileWriteBufferBytes = 64 * 1024

    struct UploadedFile {
        let filename: String
        let url: URL
        let id: UUID
        let contentType: String?
    }

    static func extractFile(from request: Request, maxSize: Int = defaultMaxFileBytes) async throws -> UploadedFile {
        // Validate content type
        guard let contentTypeHeader = request.headers[.contentType],
              contentTypeHeader.contains("multipart/form-data") else {
            throw MultipartUploadError.notMultipart
        }

        guard let boundary = extractBoundary(from: contentTypeHeader) else {
            throw MultipartUploadError.noBoundary
        }
        guard isValidBoundary(boundary) else {
            throw MultipartUploadError.invalidBoundary
        }

        let (maxRequestBytes, requestLimitOverflow) = maxSize.addingReportingOverflow(maxRequestOverheadBytes)
        guard maxSize >= 0, !requestLimitOverflow else {
            throw MultipartUploadError.requestTooLarge
        }

        // Use MultipartKit 4.x callback-based API:
        //   MultipartParser.onHeader(name, value)  — called for each header in a part
        //   MultipartParser.onBody(ByteBuffer)      — called with body chunks
        //   MultipartParser.onPartComplete()        — called when a part is finished
        //   MultipartParser.execute(ByteBuffer)     — drives the parse
        let parser = MultipartKit.MultipartParser(boundary: boundary)
        var metadataLimiter = MultipartMetadataLimiter(
            boundary: boundary,
            maxMetadataBytes: maxMultipartMetadataBytes
        )

        struct CurrentPart {
            var headers: [(name: String, value: String)] = []
            private(set) var isSelectedFile = false
            private(set) var selectedFilename = "upload"
            private(set) var selectedContentType: String?
            private var didResolveSelection = false

            mutating func resolveSelection() {
                guard !didResolveSelection else { return }
                didResolveSelection = true
                guard fieldName == "file" else { return }
                isSelectedFile = true
                selectedFilename = filename
                selectedContentType = contentType
            }

            private var fieldName: String? {
                disposition.flatMap { MultipartFileParser.extractParam("name", from: $0) }
            }

            private var filename: String {
                disposition.flatMap { MultipartFileParser.extractParam("filename", from: $0) } ?? "upload"
            }

            private var contentType: String? {
                headers.first { $0.name.lowercased() == "content-type" }?.value
            }

            private var disposition: String? {
                headers.first { $0.name.lowercased() == "content-disposition" }?.value
            }
        }

        var currentPart = CurrentPart()
        var stagedFile: (url: URL, id: UUID)?
        var uploadedFilename = "upload"
        var uploadedContentType: String?
        var fileHandle: FileHandle?
        var fileWriteBuffer = MultipartFileWriteBuffer(capacity: fileWriteBufferBytes)
        var isWritingSelectedFile = false
        var sawFileField = false
        var bytesWritten = 0
        var pendingError: Error?
        var completed = false
        var totalBytesReceived = 0

        func recordError(_ error: Error) {
            if pendingError == nil {
                pendingError = error
            }
        }

        func closeFileHandle(flushBufferedBytes: Bool) {
            if let handle = fileHandle {
                if flushBufferedBytes, pendingError == nil {
                    do {
                        try fileWriteBuffer.flush { data in
                            try handle.write(contentsOf: data)
                        }
                    } catch {
                        recordError(error)
                    }
                }
                try? handle.close()
            }
            fileWriteBuffer.discard()
            fileHandle = nil
            isWritingSelectedFile = false
        }

        defer {
            closeFileHandle(flushBufferedBytes: false)
            if !completed, let stagedFile {
                FileStaging.remove(url: stagedFile.url)
            }
        }

        parser.onHeader = { name, value in
            currentPart.headers.append((name: name, value: value))
        }

        parser.onBody = { chunk in
            guard pendingError == nil else { return }
            currentPart.resolveSelection()
            guard currentPart.isSelectedFile else { return }
            sawFileField = true

            do {
                if stagedFile == nil {
                    let filename = currentPart.selectedFilename
                    guard filename.utf8.count <= maxFilenameBytes else {
                        recordError(MultipartUploadError.filenameTooLong)
                        return
                    }
                    let reserved = try FileStaging.reserve(filename: filename)
                    stagedFile = reserved
                    uploadedFilename = filename
                    uploadedContentType = currentPart.selectedContentType
                    fileHandle = try FileHandle(forWritingTo: reserved.url)
                    isWritingSelectedFile = true
                }

                guard isWritingSelectedFile, let fileHandle else { return }
                let readableBytes = chunk.readableBytes
                guard readableBytes > 0 else { return }
                guard bytesWritten <= maxSize, readableBytes <= maxSize - bytesWritten else {
                    recordError(MultipartUploadError.tooLarge)
                    return
                }

                try fileWriteBuffer.append(chunk) { data in
                    try fileHandle.write(contentsOf: data)
                }
                bytesWritten += readableBytes
            } catch {
                recordError(error)
            }
        }

        parser.onPartComplete = {
            currentPart.resolveSelection()
            if currentPart.isSelectedFile {
                sawFileField = true
                closeFileHandle(flushBufferedBytes: true)
            }
            currentPart = CurrentPart()
        }

        for try await chunk in request.body {
            let chunkBytes = chunk.readableBytes
            guard totalBytesReceived <= maxRequestBytes,
                  chunkBytes <= maxRequestBytes - totalBytesReceived else {
                throw MultipartUploadError.requestTooLarge
            }
            totalBytesReceived += chunkBytes

            try metadataLimiter.consume(chunk)
            do {
                try parser.execute(chunk)
            } catch {
                throw MultipartUploadError.malformedMultipart
            }
            if let pendingError {
                throw pendingError
            }
        }

        if let pendingError {
            throw pendingError
        }

        guard metadataLimiter.hasClosingBoundary else {
            throw MultipartUploadError.malformedMultipart
        }

        guard sawFileField else {
            throw MultipartUploadError.noFileField
        }

        guard let stagedFile, bytesWritten > 0 else {
            throw MultipartUploadError.emptyFile
        }

        completed = true
        Log.http.info("Parsed multipart upload: \(uploadedFilename, privacy: .public), \(bytesWritten) bytes")

        return UploadedFile(
            filename: uploadedFilename,
            url: stagedFile.url,
            id: stagedFile.id,
            contentType: uploadedContentType
        )
    }

    private static func extractBoundary(from contentType: String) -> String? {
        return extractParam("boundary", from: contentType)
    }

    private static func isValidBoundary(_ boundary: String) -> Bool {
        let bytes = Array(boundary.utf8)
        guard !bytes.isEmpty, bytes.count <= maxBoundaryBytes, bytes.last != 0x20 else {
            return false
        }

        return bytes.allSatisfy { byte in
            switch byte {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A:
                return true
            case 0x20, 0x27, 0x28, 0x29, 0x2B, 0x2C, 0x2D, 0x2E,
                 0x2F, 0x3A, 0x3D, 0x3F, 0x5F:
                return true
            default:
                return false
            }
        }
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

struct MultipartFileWriteBuffer {
    private let capacity: Int
    private var storage: Data

    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
        self.storage = Data()
        self.storage.reserveCapacity(capacity)
    }

    mutating func append(
        _ chunk: ByteBuffer,
        write: (Data) throws -> Void
    ) throws {
        let bytes = chunk.readableBytesView
        var index = bytes.startIndex

        while index < bytes.endIndex {
            let count = min(capacity - storage.count, bytes.distance(from: index, to: bytes.endIndex))
            let endIndex = bytes.index(index, offsetBy: count)
            storage.append(contentsOf: bytes[index..<endIndex])
            index = endIndex

            if storage.count == capacity {
                try flush(write: write)
            }
        }
    }

    mutating func flush(write: (Data) throws -> Void) throws {
        guard !storage.isEmpty else { return }
        try write(storage)
        storage.removeAll(keepingCapacity: true)
    }

    mutating func discard() {
        storage.removeAll(keepingCapacity: true)
    }
}

/// Bounds partial multipart headers before MultipartKit stores them internally.
/// The state transitions mirror MultipartKit's preamble/body boundary matching,
/// while retaining only integer match indexes.
private struct MultipartMetadataLimiter {
    private enum State {
        case preamble(boundaryMatchIndex: Int)
        case afterBoundary
        case closingBoundary
        case headers(terminatorMatchIndex: Int)
        case body
        case boundary(boundaryMatchIndex: Int)
        case epilogue
    }

    private static let headerTerminator: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A]

    private let boundary: [UInt8]
    private let maxMetadataBytes: Int
    private var state: State = .preamble(boundaryMatchIndex: 0)
    private var metadataBytes = 0
    private(set) var hasClosingBoundary = false

    init(boundary: String, maxMetadataBytes: Int) {
        self.boundary = Array("\r\n--\(boundary)".utf8)
        self.maxMetadataBytes = maxMetadataBytes
    }

    mutating func consume(_ buffer: ByteBuffer) throws {
        for byte in buffer.readableBytesView {
            try consume(byte)
        }
    }

    private mutating func consume(_ byte: UInt8) throws {
        switch state {
        case .preamble(let boundaryMatchIndex):
            let nextMatchIndex: Int
            if boundaryMatchIndex == 0, byte == boundary[2] {
                // MultipartKit permits the initial boundary without a leading CRLF.
                nextMatchIndex = 3
            } else if byte == boundary[boundaryMatchIndex] {
                nextMatchIndex = boundaryMatchIndex + 1
            } else if boundaryMatchIndex > 0, byte == boundary[0] {
                nextMatchIndex = 1
            } else {
                nextMatchIndex = 0
            }
            state = nextMatchIndex == boundary.count
                ? .afterBoundary
                : .preamble(boundaryMatchIndex: nextMatchIndex)

        case .afterBoundary:
            if byte == 0x0D {
                try countHeaderByte(byte, terminatorMatchIndex: 0)
            } else if byte == 0x2D {
                state = .closingBoundary
            } else {
                state = .body
            }

        case .closingBoundary:
            guard byte == 0x2D else {
                throw MultipartUploadError.malformedMultipart
            }
            hasClosingBoundary = true
            state = .epilogue

        case .headers(let terminatorMatchIndex):
            try countHeaderByte(byte, terminatorMatchIndex: terminatorMatchIndex)

        case .body:
            state = byte == boundary[0]
                ? .boundary(boundaryMatchIndex: 1)
                : .body

        case .boundary(let boundaryMatchIndex):
            if byte == boundary[boundaryMatchIndex] {
                let nextMatchIndex = boundaryMatchIndex + 1
                state = nextMatchIndex == boundary.count
                    ? .afterBoundary
                    : .boundary(boundaryMatchIndex: nextMatchIndex)
            } else if byte == boundary[0] {
                state = .boundary(boundaryMatchIndex: 1)
            } else {
                state = .body
            }

        case .epilogue:
            break
        }
    }

    private mutating func countHeaderByte(_ byte: UInt8, terminatorMatchIndex: Int) throws {
        guard metadataBytes < maxMetadataBytes else {
            throw MultipartUploadError.metadataTooLarge
        }
        metadataBytes += 1

        let nextMatchIndex = Self.nextMatchIndex(
            for: byte,
            pattern: Self.headerTerminator,
            currentIndex: terminatorMatchIndex
        )
        state = nextMatchIndex == Self.headerTerminator.count
            ? .body
            : .headers(terminatorMatchIndex: nextMatchIndex)
    }

    private static func nextMatchIndex(for byte: UInt8, pattern: [UInt8], currentIndex: Int) -> Int {
        var matchIndex = currentIndex
        while matchIndex > 0, byte != pattern[matchIndex] {
            matchIndex = matchIndex == 3 ? 1 : 0
        }
        if byte == pattern[matchIndex] {
            matchIndex += 1
        }
        return matchIndex
    }
}

enum MultipartUploadError: Error, Sendable {
    case notMultipart
    case noBoundary
    case invalidBoundary
    case malformedMultipart
    case noFileField
    case emptyFile
    case tooLarge
    case requestTooLarge
    case metadataTooLarge
    case filenameTooLong

    var errorCode: String {
        switch self {
        case .notMultipart: return "not_multipart"
        case .noBoundary: return "invalid_multipart"
        case .invalidBoundary: return "invalid_boundary"
        case .malformedMultipart: return "malformed_multipart"
        case .noFileField: return "missing_file_field"
        case .emptyFile: return "empty_file"
        case .tooLarge: return "file_too_large"
        case .requestTooLarge: return "request_too_large"
        case .metadataTooLarge: return "multipart_metadata_too_large"
        case .filenameTooLong: return "filename_too_long"
        }
    }

    var message: String {
        switch self {
        case .notMultipart:
            return "Request must use multipart/form-data."
        case .noBoundary:
            return "Multipart boundary is missing."
        case .invalidBoundary:
            return "Multipart boundary is invalid."
        case .malformedMultipart:
            return "Multipart body is malformed or incomplete."
        case .noFileField:
            return "Multipart request is missing the file field."
        case .emptyFile:
            return "Uploaded file is empty."
        case .tooLarge:
            return "Uploaded file exceeds the allowed size."
        case .requestTooLarge:
            return "Multipart request exceeds the allowed size."
        case .metadataTooLarge:
            return "Multipart metadata exceeds the 16 KiB limit."
        case .filenameTooLong:
            return "Filename exceeds the 1024-byte limit."
        }
    }

    var responseStatus: HTTPResponse.Status {
        switch self {
        case .tooLarge, .requestTooLarge, .metadataTooLarge:
            return .contentTooLarge
        default:
            return .badRequest
        }
    }
}
