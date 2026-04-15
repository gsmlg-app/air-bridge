import SwiftUI

struct MenuBarView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            statusRow
            Divider()

            if let file = appState.playbackState.currentFile {
                Label(URL(fileURLWithPath: file).lastPathComponent, systemImage: "music.note")
                    .font(.caption)
                    .lineLimit(1)
            }

            if appState.playbackState.isPlaying {
                Button("Stop") {
                    Task { await appState.stop() }
                }
            }

            if case .error(let msg) = appState.playbackState {
                Label(msg, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundColor(.red)
            }

            Divider()
            Label("Route: \(appState.currentRoute)", systemImage: "airplayaudio")
                .font(.caption)
            Label("Listening on \(appState.listenAddress):\(appState.serverPort)", systemImage: "network")
                .font(.caption)
                .foregroundColor(.secondary)
            Divider()
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(8)
        .frame(width: 240)
    }

    private var statusRow: some View {
        HStack {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text("AirBridge — \(appState.playbackState.statusString)")
                .font(.headline)
        }
    }

    private var statusColor: Color {
        switch appState.playbackState {
        case .idle: .green
        case .playing: .blue
        case .paused: .yellow
        case .error: .red
        }
    }
}
