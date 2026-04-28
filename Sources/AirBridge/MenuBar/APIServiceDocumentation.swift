import Foundation

struct APIServiceExample: Identifiable, Equatable {
    let id: String
    let title: String
    let description: String
    let command: String
}

enum APIServiceDocumentation {
    static let sampleFilePath = "/Users/gao/Downloads/female_professional.mp3"
    static let authHeaderExample = #"Authorization: Bearer <token>"#

    static func baseURL(address: String, port: String) -> String {
        let trimmedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let host: String
        switch trimmedAddress {
        case "", "0.0.0.0", "::":
            host = "127.0.0.1"
        default:
            host = trimmedAddress
        }

        let trimmedPort = port.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPort = Int(trimmedPort).map(String.init) ?? "9876"
        return "http://\(host):\(normalizedPort)"
    }

    static func examples(baseURL: String) -> [APIServiceExample] {
        [
            APIServiceExample(
                id: "status",
                title: "Status",
                description: "Check playback and queue state.",
                command: "curl \(baseURL)/status"
            ),
            APIServiceExample(
                id: "play",
                title: "Play now",
                description: "Upload one file and replace the current queue with it.",
                command: #"curl -X POST \#(baseURL)/play -F "file=@\#(sampleFilePath)""#
            ),
            APIServiceExample(
                id: "enqueue",
                title: "Add to queue",
                description: "Upload one file without replacing the queue.",
                command: #"curl -X POST \#(baseURL)/queue -F "file=@\#(sampleFilePath)""#
            ),
            APIServiceExample(
                id: "queue",
                title: "Queue",
                description: "List queued tracks and the current index.",
                command: "curl \(baseURL)/queue"
            ),
            APIServiceExample(
                id: "delete-track",
                title: "Remove track",
                description: "Remove a queued track by ID.",
                command: "curl -X DELETE \(baseURL)/queue/<track-id>"
            ),
            APIServiceExample(
                id: "next",
                title: "Next track",
                description: "Skip to the next queued track.",
                command: "curl -X POST \(baseURL)/queue/next"
            ),
            APIServiceExample(
                id: "previous",
                title: "Previous track",
                description: "Return to the previous track, or restart the first track.",
                command: "curl -X POST \(baseURL)/queue/prev"
            ),
            APIServiceExample(
                id: "move",
                title: "Move track",
                description: "Move a queued track to a zero-based position.",
                command: #"curl -X POST \#(baseURL)/queue/move -H "Content-Type: application/json" -d '{"id":"<track-id>","position":0}'"#
            ),
            APIServiceExample(
                id: "outputs",
                title: "Outputs",
                description: "List local CoreAudio outputs and the current target.",
                command: "curl \(baseURL)/outputs"
            ),
            APIServiceExample(
                id: "current-output",
                title: "Current output",
                description: "Show the active output target.",
                command: "curl \(baseURL)/outputs/current"
            ),
            APIServiceExample(
                id: "set-output",
                title: "Set output",
                description: "Pin playback to a local output UID, or use null for system routing.",
                command: #"curl -X PUT \#(baseURL)/outputs/current -H "Content-Type: application/json" -d '{"id":null}'"#
            ),
            APIServiceExample(
                id: "pause",
                title: "Pause",
                description: "Pause current playback.",
                command: "curl -X POST \(baseURL)/pause"
            ),
            APIServiceExample(
                id: "resume",
                title: "Resume",
                description: "Resume paused playback.",
                command: "curl -X POST \(baseURL)/resume"
            ),
            APIServiceExample(
                id: "stop",
                title: "Stop",
                description: "Stop playback and clear the queue.",
                command: "curl -X POST \(baseURL)/stop"
            ),
        ]
    }
}
