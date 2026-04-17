import Foundation
import os

actor PlaybackQueue {
    private var state = QueueState()
    private let engine: PlaybackEngine

    init(engine: PlaybackEngine) {
        self.engine = engine

        Task {
            await engine.setTrackFinishedCallback { [weak self] in
                guard let self else { return }
                await self.advanceToNext()
            }
        }
    }

    func enqueue(track: QueueTrack) async -> (id: UUID, position: Int) {
        state.tracks.append(track)
        let position = state.tracks.count - 1
        Log.queue.info("Enqueued '\(track.originalFilename, privacy: .public)' at position \(position)")

        // Auto-start if queue was idle
        if state.currentIndex == nil {
            state.currentIndex = 0
            await playCurrentTrack()
        }

        return (track.id, position)
    }

    func playNow(track: QueueTrack) async {
        let insertIndex = (state.currentIndex ?? -1) + 1
        state.tracks.insert(track, at: insertIndex)
        state.currentIndex = insertIndex
        Log.queue.info("Play now: '\(track.originalFilename, privacy: .public)' at position \(insertIndex)")
        await playCurrentTrack()
    }

    func remove(id: UUID) async -> Bool {
        guard let idx = state.tracks.firstIndex(where: { $0.id == id }) else {
            return false
        }

        let track = state.tracks[idx]
        let isCurrentTrack = state.currentIndex == idx

        state.tracks.remove(at: idx)
        FileStaging.remove(url: URL(fileURLWithPath: track.stagedPath))

        // Adjust currentIndex
        if let current = state.currentIndex {
            if idx < current {
                state.currentIndex = current - 1
            } else if isCurrentTrack {
                _ = await engine.stop()
                if state.tracks.isEmpty {
                    state.currentIndex = nil
                } else {
                    state.currentIndex = min(current, state.tracks.count - 1)
                    await playCurrentTrack()
                }
            }
        }

        Log.queue.info("Removed '\(track.originalFilename, privacy: .public)'")
        return true
    }

    func move(id: UUID, toPosition: Int) async throws {
        guard let fromIdx = state.tracks.firstIndex(where: { $0.id == id }) else {
            throw QueueError.trackNotFound
        }
        let clampedTo = max(0, min(toPosition, state.tracks.count - 1))

        // Remember current playing track
        let currentTrackID = state.currentTrack?.id

        let track = state.tracks.remove(at: fromIdx)
        state.tracks.insert(track, at: clampedTo)

        // Restore currentIndex to point to the same playing track
        if let playingID = currentTrackID {
            state.currentIndex = state.tracks.firstIndex(where: { $0.id == playingID })
        }

        Log.queue.info("Moved '\(track.originalFilename, privacy: .public)' to position \(clampedTo)")
    }

    func clear() async {
        _ = await engine.stop()
        for track in state.tracks {
            FileStaging.remove(url: URL(fileURLWithPath: track.stagedPath))
        }
        state = QueueState()
        Log.queue.info("Queue cleared")
    }

    func next() async -> QueueTrack? {
        guard let current = state.currentIndex, current + 1 < state.tracks.count else {
            return nil
        }
        state.currentIndex = current + 1
        await playCurrentTrack()
        return state.currentTrack
    }

    func previous() async -> QueueTrack? {
        guard let current = state.currentIndex else { return nil }
        if current > 0 {
            state.currentIndex = current - 1
        }
        // At position 0, restart current track
        await playCurrentTrack()
        return state.currentTrack
    }

    func list() -> QueueState {
        state
    }

    // MARK: - Private

    private func advanceToNext() async {
        guard let current = state.currentIndex else { return }
        let nextIdx = current + 1
        if nextIdx < state.tracks.count {
            state.currentIndex = nextIdx
            await playCurrentTrack()
        } else {
            state.currentIndex = nil
            Log.queue.info("Queue exhausted")
        }
    }

    private func playCurrentTrack() async {
        guard let track = state.currentTrack else { return }
        do {
            try await engine.play(track: track)
        } catch {
            Log.playback.error("Failed to play '\(track.originalFilename, privacy: .public)': \(error)")
        }
    }
}

enum QueueError: Error, Sendable {
    case trackNotFound
}

extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
