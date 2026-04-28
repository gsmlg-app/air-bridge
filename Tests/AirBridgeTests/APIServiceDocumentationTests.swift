import Testing
@testable import AirBridge

struct APIServiceDocumentationTests {
    @Test func loopbackBaseURLUsesConfiguredPort() {
        let baseURL = APIServiceDocumentation.baseURL(address: "0.0.0.0", port: "9876")

        #expect(baseURL == "http://127.0.0.1:9876")
    }

    @Test func examplesIncludePlayEndpointWithMultipartUpload() {
        let examples = APIServiceDocumentation.examples(baseURL: "http://127.0.0.1:9876")

        let play = examples.first { $0.title == "Play now" }

        #expect(play?.command == #"curl -X POST http://127.0.0.1:9876/play -F "file=@/Users/gao/Downloads/female_professional.mp3""#)
    }

    @Test func examplesCoverCoreServiceRoutes() {
        let commands = APIServiceDocumentation.examples(baseURL: "http://127.0.0.1:9876")
            .map(\.command)
            .joined(separator: "\n")

        let routes = [
            "/status",
            "/play",
            "/queue",
            "/queue/next",
            "/queue/prev",
            "/queue/move",
            "/outputs",
            "/outputs/current",
            "/pause",
            "/resume",
            "/stop",
        ]

        for route in routes {
            #expect(commands.contains(route))
        }
    }

    @Test func authHeaderExampleIsDocumented() {
        #expect(APIServiceDocumentation.authHeaderExample == #"Authorization: Bearer <token>"#)
    }
}
