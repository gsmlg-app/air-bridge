import Foundation
import Hummingbird
import NIOCore
import Testing
@testable import AirBridge

struct MultipartFileParserTests {
    @Test func fileWriteBuffer_coalescesSmallParserChunks() throws {
        var writeBuffer = MultipartFileWriteBuffer(capacity: 8)
        var writes: [Data] = []

        for byte in UInt8(0)..<UInt8(10) {
            try writeBuffer.append(ByteBuffer(bytes: [byte])) { writes.append($0) }
        }
        try writeBuffer.flush { writes.append($0) }

        #expect(writes.map(\.count) == [8, 2])
        #expect(Data(writes.joined()) == Data(UInt8(0)..<UInt8(10)))
    }

    @Test func extractFile_streamsMultipartUploadToStagedFile() async throws {
        let payload = Data((0..<4096).map { UInt8($0 % 251) })
        let request = makeMultipartRequest(filename: "sample.mp3", contentType: "audio/mpeg", fileData: payload)

        let upload = try await MultipartFileParser.extractFile(from: request)
        defer { FileStaging.remove(url: upload.url) }

        #expect(upload.filename == "sample.mp3")
        #expect(upload.contentType == "audio/mpeg")
        #expect(FileManager.default.fileExists(atPath: upload.url.path))
        #expect(try Data(contentsOf: upload.url) == payload)
    }

    @Test func extractFile_preservesPartialBoundaryPrefixesWithByteSizedChunks() async throws {
        let boundary = "AirBridgeByteSplitBoundary"
        let partialBoundary = Data("\r\n--\(boundary.dropLast())X".utf8)
        var payload = Data()
        for index in 0..<128 {
            payload.append(Data([0x0D, UInt8(index % 251)]))
            payload.append(partialBoundary)
        }
        let request = makeMultipartRequest(
            filename: "boundary-prefix.mp3",
            contentType: "audio/mpeg",
            fileData: payload,
            boundary: boundary,
            chunkSize: 1
        )

        let upload = try await MultipartFileParser.extractFile(from: request)
        defer { FileStaging.remove(url: upload.url) }

        #expect(try Data(contentsOf: upload.url) == payload)
    }

    @Test func extractFile_selectsFileAfterAnotherPartWithByteSizedChunks() async throws {
        let boundary = "AirBridgeMultiplePartsBoundary"
        let payload = Data([0x01, 0x0D, 0x02, 0x03])
        var body = Data("--\(boundary)\r\n".utf8)
        body.append(Data("Content-Disposition: form-data; name=\"metadata\"\r\n\r\n".utf8))
        body.append(Data("before-file".utf8))
        body.append(Data("\r\n--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"multiple.mp3\"\r\n".utf8))
        body.append(Data("Content-Type: audio/mpeg\r\n\r\n".utf8))
        body.append(payload)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        let request = makeMultipartRequest(body: body, boundary: boundary, chunkSize: 1)

        let upload = try await MultipartFileParser.extractFile(from: request)
        defer { FileStaging.remove(url: upload.url) }

        #expect(upload.filename == "multiple.mp3")
        #expect(upload.contentType == "audio/mpeg")
        #expect(try Data(contentsOf: upload.url) == payload)
    }

    @Test func extractFile_rejectsMalformedHeaderSyntax() async throws {
        let boundary = "AirBridgeMalformedHeaderBoundary"
        var body = Data("--\(boundary)\r\n".utf8)
        body.append(Data("Invalid Header: value\r\n\r\n".utf8))
        body.append(Data([0x01]))
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        let request = makeMultipartRequest(body: body, boundary: boundary, chunkSize: 1)

        await expectUploadErrorCode("malformed_multipart", from: request)
    }

    @Test func extractFile_rejectsMissingFinalBoundary() async throws {
        let boundary = "AirBridgeMissingFinalBoundary"
        var body = Data("--\(boundary)\r\n".utf8)
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"truncated.mp3\"\r\n".utf8))
        body.append(Data("Content-Type: audio/mpeg\r\n\r\n".utf8))
        body.append(Data([0x01, 0x02, 0x03]))
        let request = makeMultipartRequest(body: body, boundary: boundary, chunkSize: 1)

        await expectUploadErrorCode("malformed_multipart", from: request)
    }

    @Test func extractFile_throwsTooLargeWhenFileExceedsLimit() async throws {
        let payload = Data(repeating: 0xAB, count: 128)
        let request = makeMultipartRequest(filename: "large.mp3", contentType: "audio/mpeg", fileData: payload)

        do {
            _ = try await MultipartFileParser.extractFile(from: request, maxSize: 64)
            Issue.record("Expected upload to exceed the parser limit")
        } catch let error as MultipartUploadError {
            guard case .tooLarge = error else {
                Issue.record("Expected .tooLarge, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected MultipartUploadError.tooLarge, got \(error)")
        }
    }

    @Test func extractFile_acceptsFileAtLimitWithNormalMultipartFraming() async throws {
        let payload = Data(repeating: 0x5A, count: 1024)
        let request = makeMultipartRequest(filename: "at-limit.mp3", contentType: "audio/mpeg", fileData: payload)

        let upload = try await MultipartFileParser.extractFile(from: request, maxSize: payload.count)
        defer { FileStaging.remove(url: upload.url) }

        #expect(try Data(contentsOf: upload.url) == payload)
    }

    @Test func extractFile_rejectsMultipartMetadataBeyondBudget() async throws {
        let request = makeMultipartRequest(
            filename: "metadata.mp3",
            contentType: "audio/mpeg",
            fileData: Data([0x01]),
            extraHeaders: ["X-AirBridge-Metadata: \(String(repeating: "x", count: 17 * 1024))"]
        )

        await expectUploadErrorCode("multipart_metadata_too_large", from: request)
    }

    @Test func extractFile_rejectsUnterminatedHeaderBeforeTotalRequestBudget() async throws {
        let boundary = "AirBridgeUnterminatedHeaderBoundary"
        var body = Data("--\(boundary)\r\nX-Unterminated-Metadata: ".utf8)
        body.append(Data(repeating: 0x78, count: 70 * 1024))
        let request = makeMultipartRequest(body: body, boundary: boundary, chunkSize: 127)

        await expectUploadErrorCode("multipart_metadata_too_large", from: request, maxSize: 1)
    }

    @Test func extractFile_rejectsOverlongFilename() async throws {
        let filename = String(repeating: "f", count: 1025) + ".mp3"
        let request = makeMultipartRequest(filename: filename, contentType: "audio/mpeg", fileData: Data([0x01]))

        await expectUploadErrorCode("filename_too_long", from: request)
    }

    @Test func extractFile_rejectsOverlongBoundary() async throws {
        let boundary = String(repeating: "b", count: 71)
        let request = makeMultipartRequest(
            filename: "boundary.mp3",
            contentType: "audio/mpeg",
            fileData: Data([0x01]),
            boundary: boundary
        )

        await expectUploadErrorCode("invalid_boundary", from: request)
    }

    @Test func extractFile_rejectsTotalRequestBeyondBudgetAndRemovesStagedFile() async throws {
        let uniqueExtension = "cleanup\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let filename = "request-budget.\(uniqueExtension)"
        let request = makeMultipartRequest(
            filename: filename,
            contentType: "application/octet-stream",
            fileData: Data(repeating: 0x33, count: 32),
            trailingFieldData: Data(repeating: 0x44, count: 65 * 1024)
        )

        await expectUploadErrorCode("request_too_large", from: request, maxSize: 32)

        let leftovers = try FileManager.default.contentsOfDirectory(
            at: FileStaging.directory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == uniqueExtension }
        #expect(leftovers.isEmpty)
    }

    private func expectUploadErrorCode(
        _ expectedCode: String,
        from request: Request,
        maxSize: Int = 50 * 1024 * 1024
    ) async {
        do {
            let upload = try await MultipartFileParser.extractFile(from: request, maxSize: maxSize)
            FileStaging.remove(url: upload.url)
            Issue.record("Expected multipart upload error \(expectedCode)")
        } catch let error as MultipartUploadError {
            #expect(error.errorCode == expectedCode)
        } catch {
            Issue.record("Expected MultipartUploadError, got \(error)")
        }
    }

    private func makeMultipartRequest(
        filename: String,
        contentType: String,
        fileData: Data,
        extraHeaders: [String] = [],
        trailingFieldData: Data? = nil,
        boundary: String = "AirBridgeTestBoundary",
        chunkSize: Int = 17
    ) -> Request {
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".utf8))
        body.append(Data("Content-Type: \(contentType)\r\n".utf8))
        for header in extraHeaders {
            body.append(Data("\(header)\r\n".utf8))
        }
        body.append(Data("\r\n".utf8))
        body.append(fileData)
        if let trailingFieldData {
            body.append(Data("\r\n--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"metadata\"\r\n\r\n".utf8))
            body.append(trailingFieldData)
        }
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        return makeMultipartRequest(body: body, boundary: boundary, chunkSize: chunkSize)
    }

    private func makeMultipartRequest(body: Data, boundary: String, chunkSize: Int = 17) -> Request {
        let (requestBody, source) = RequestBody.makeStream()
        Task {
            for chunk in body.chunks(ofCount: chunkSize) {
                await source.yield(ByteBuffer(data: Data(chunk)))
            }
            source.finish()
        }

        return Request(
            head: .init(
                method: .post,
                scheme: "http",
                authority: "localhost",
                path: "/queue",
                headerFields: [.contentType: "multipart/form-data; boundary=\(boundary)"]
            ),
            body: requestBody
        )
    }
}
