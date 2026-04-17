import SwiftUI

struct MenuBarView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            statusRow

            // Current track
            if let file = appState.playbackState.currentFile {
                HStack {
                    Image(systemName: "music.note")
                    Text(file)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.caption)
            }

            Divider()

            // Queue
            QueueListView(queueState: appState.queueState)

            // Skip controls
            if appState.queueState.tracks.count > 1 {
                HStack {
                    Button(action: {
                        Task { _ = await appState.queue.previous() }
                    }) {
                        Image(systemName: "backward.fill")
                    }
                    .buttonStyle(.borderless)

                    Button(action: {
                        Task { _ = await appState.queue.next() }
                    }) {
                        Image(systemName: "forward.fill")
                    }
                    .buttonStyle(.borderless)
                }
            }

            Divider()

            // Engine target
            HStack {
                Text("Playing through:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(appState.currentOutputName)
                    .font(.caption)
                    .bold()

                if !appState.currentOutputUID.isEmpty {
                    let defaultUID = AudioDeviceManager.deviceUID(for: AudioDeviceManager.getDefaultOutputDeviceID())
                    if appState.currentOutputUID != defaultUID {
                        Image(systemName: "info.circle")
                            .font(.caption2)
                            .foregroundColor(.orange)
                            .help("Engine target differs from system default")
                    }
                }
            }

            // Error
            if let error = appState.playbackState.errorMessage {
                Text(error)
                    .foregroundColor(.red)
                    .font(.caption)
            }

            Divider()

            // Server info
            HStack {
                Image(systemName: "network")
                Text("\(appState.listenAddress):\(appState.serverPort)")
            }
            .font(.caption)
            .foregroundColor(.secondary)

            Button("Quit") {
                FileStaging.clearAll()
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(8)
        .frame(width: 260)
    }

    private var statusRow: some View {
        HStack {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(appState.playbackState.statusString.capitalized)
                .font(.headline)

            Spacer()

            if !appState.queueState.isEmpty {
                Text("\(appState.queueState.tracks.count) tracks")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var statusColor: Color {
        switch appState.playbackState {
        case .idle: return .green
        case .playing: return .blue
        case .paused: return .yellow
        case .error: return .red
        }
    }
}
