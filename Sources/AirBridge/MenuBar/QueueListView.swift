import SwiftUI

struct QueueListView: View {
    let queueState: QueueState

    var body: some View {
        if queueState.tracks.isEmpty {
            Text("Queue empty")
                .foregroundColor(.secondary)
                .font(.caption)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(queueState.tracks.indices, id: \.self) { idx in
                        let track = queueState.tracks[idx]
                        HStack(spacing: 6) {
                            Text("\(idx + 1).")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .frame(width: 20, alignment: .trailing)

                            statusIcon(for: idx)

                            Text(track.originalFilename)
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)

                            Spacer()
                        }
                        .padding(.vertical, 1)
                    }
                }
            }
            .frame(maxHeight: 100)
        }
    }

    private func statusIcon(for index: Int) -> some View {
        Group {
            if let current = queueState.currentIndex {
                if index < current {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.secondary)
                } else if index == current {
                    Image(systemName: "play.circle.fill")
                        .foregroundColor(.blue)
                } else {
                    Image(systemName: "circle")
                        .foregroundColor(.secondary)
                }
            } else {
                Image(systemName: "circle")
                    .foregroundColor(.secondary)
            }
        }
        .font(.caption2)
    }
}
