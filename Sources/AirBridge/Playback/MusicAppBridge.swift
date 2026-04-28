import AVFoundation
import Foundation

struct MusicAirPlayDevice: Identifiable, Sendable, Equatable {
    let id: String
    let name: String
    let kind: String
    let available: Bool
    var selected: Bool
    let supportsAudio: Bool
    let isProtected: Bool
}

protocol AppleScriptRunning: Sendable {
    func run(_ source: String) async throws -> String
}

protocol MusicAppControlling: Sendable {
    func devices() async throws -> [MusicAirPlayDevice]
    func play(fileURL: URL, deviceIDs: [String]) async throws
    func stop() async throws
    func pause() async throws
    func resume() async throws
}

struct NSAppleScriptRunner: AppleScriptRunning {
    func run(_ source: String) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            var errorInfo: NSDictionary?
            guard let script = NSAppleScript(source: source) else {
                throw MusicAppBridgeError.scriptCompilationFailed
            }

            let result = script.executeAndReturnError(&errorInfo)
            if let errorInfo, errorInfo.count > 0 {
                throw MusicAppBridgeError.scriptFailed(Self.errorMessage(from: errorInfo))
            }

            return result.stringValue ?? ""
        }.value
    }

    private static func errorMessage(from errorInfo: NSDictionary) -> String {
        if let message = errorInfo[NSAppleScript.errorMessage] as? String {
            return message
        }
        return errorInfo.description
    }
}

enum MusicAppBridgeError: Error, LocalizedError, Sendable {
    case scriptCompilationFailed
    case scriptFailed(String)
    case noSelectedDevices

    var errorDescription: String? {
        switch self {
        case .scriptCompilationFailed:
            return "Failed to compile Music automation script."
        case .scriptFailed(let message):
            return "Music automation failed: \(message)"
        case .noSelectedDevices:
            return "No HomePod or AirPlay device is selected."
        }
    }
}

struct MusicAppBridge: MusicAppControlling {
    private let runner: any AppleScriptRunning

    init(runner: any AppleScriptRunning = NSAppleScriptRunner()) {
        self.runner = runner
    }

    func devices() async throws -> [MusicAirPlayDevice] {
        let output = try await runner.run(Self.devicesScript)
        return Self.parseDevices(output)
    }

    func play(fileURL: URL, deviceIDs: [String]) async throws {
        guard !deviceIDs.isEmpty else {
            throw MusicAppBridgeError.noSelectedDevices
        }
        _ = try await runner.run(Self.playScript(fileURL: fileURL, deviceIDs: deviceIDs))
    }

    func stop() async throws {
        _ = try await runner.run(#"tell application "Music" to stop"#)
    }

    func pause() async throws {
        _ = try await runner.run(#"tell application "Music" to pause"#)
    }

    func resume() async throws {
        _ = try await runner.run(#"tell application "Music" to resume"#)
    }

    static let devicesScript = """
    set oldDelimiters to AppleScript's text item delimiters
    set tabDelimiter to ASCII character 9
    set outputRows to {}
    tell application "Music"
        repeat with airplayDevice in AirPlay devices
            set deviceID to persistent ID of airplayDevice as text
            set deviceName to name of airplayDevice as text
            set deviceKind to kind of airplayDevice as text
            set deviceAvailable to available of airplayDevice as text
            set deviceSelected to selected of airplayDevice as text
            set deviceSupportsAudio to supports audio of airplayDevice as text
            set deviceProtected to protected of airplayDevice as text
            set AppleScript's text item delimiters to tabDelimiter
            copy ({deviceID, deviceName, deviceKind, deviceAvailable, deviceSelected, deviceSupportsAudio, deviceProtected} as text) to end of outputRows
        end repeat
    end tell
    set AppleScript's text item delimiters to linefeed
    set resultText to outputRows as text
    set AppleScript's text item delimiters to oldDelimiters
    return resultText
    """

    static func parseDevices(_ output: String) -> [MusicAirPlayDevice] {
        output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { row -> MusicAirPlayDevice? in
                let fields = row.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard fields.count >= 7 else { return nil }

                let device = MusicAirPlayDevice(
                    id: fields[0],
                    name: fields[1],
                    kind: fields[2],
                    available: parseBool(fields[3]),
                    selected: parseBool(fields[4]),
                    supportsAudio: parseBool(fields[5]),
                    isProtected: parseBool(fields[6])
                )

                guard device.supportsAudio, device.kind.lowercased() != "computer" else {
                    return nil
                }
                return device
            }
    }

    static func playScript(fileURL: URL, deviceIDs: [String]) -> String {
        let idList = deviceIDs
            .map { #""\#(appleScriptString($0))""# }
            .joined(separator: ", ")
        let path = appleScriptString(fileURL.path)

        return """
        set wantedIDs to {\(idList)}
        tell application "Music"
            set targetDevices to {}
            repeat with airplayDevice in AirPlay devices
                set deviceID to persistent ID of airplayDevice as text
                if wantedIDs contains deviceID and (available of airplayDevice) and (supports audio of airplayDevice) then
                    copy airplayDevice to end of targetDevices
                end if
            end repeat
            if (count of targetDevices) is 0 then error "No selected Music AirPlay devices are available"
            set current AirPlay devices to targetDevices
            play POSIX file "\(path)" once true
        end tell
        """
    }

    private static func parseBool(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "true"
    }

    private static func appleScriptString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
