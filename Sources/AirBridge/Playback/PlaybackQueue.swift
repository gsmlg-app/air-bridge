import Foundation
import os

actor PlaybackQueue {
    private var state = QueueState()
    private let engine: PlaybackEngine
    private var didInstallTrackFinishedCallback = false
    private(set) var activePlaybackToken: UUID?

    init(engine: PlaybackEngine) {
        self.engine = engine
    }

    func enqueue(track: QueueTrack) async -> (id: UUID, position: Int) {
        state.tracks.append(track)
        let position = state.tracks.count - 1
        Log.queue.info("Enqueued '\(track.originalFilename, privacy: .public)' at position \(position)")

        // Auto-start if queue was idle
        if state.currentIndex == nil {
            state.currentIndex = 0
            _ = await playCurrentTrack()
        }

        return (track.id, position)
    }

    func playNow(track: QueueTrack) async {
        let replacedTracks = state.tracks
        state.tracks = [track]
        state.currentIndex = 0
        Log.queue.info("Play now: '\(track.originalFilename, privacy: .public)' as the only queue item")
        _ = await playCurrentTrack()

        for replacedTrack in replacedTracks where replacedTrack.stagedPath != track.stagedPath {
            FileStaging.remove(url: URL(fileURLWithPath: replacedTrack.stagedPath))
        }
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
                activePlaybackToken = nil
                _ = await engine.stop()
                if state.tracks.isEmpty {
                    state.currentIndex = nil
                } else {
                    state.currentIndex = min(current, state.tracks.count - 1)
                    _ = await playCurrentTrack()
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
        activePlaybackToken = nil
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
        let didStart = await playCurrentTrack()
        if didStart {
            pruneCompletedHistory()
        }
        return state.currentTrack
    }

    func previous() async -> QueueTrack? {
        guard let current = state.currentIndex else { return nil }
        if current > 0 {
            state.currentIndex = current - 1
        }
        // At position 0, restart current track
        _ = await playCurrentTrack()
        return state.currentTrack
    }

    func list() -> QueueState {
        state
    }

    // MARK: - Private

    func handleTrackFinished(token: UUID) async {
        guard activePlaybackToken == token else { return }
        activePlaybackToken = nil
        await advanceToNext()
    }

    private func advanceToNext() async {
        guard let current = state.currentIndex else { return }
        let nextIdx = current + 1
        if nextIdx < state.tracks.count {
            state.currentIndex = nextIdx
            let didStart = await playCurrentTrack()
            if didStart {
                pruneCompletedHistory()
            }
        } else {
            await finishExhaustedQueue()
        }
    }

    private func playCurrentTrack() async -> Bool {
        await ensureTrackFinishedCallbackInstalled()

        while let track = state.currentTrack {
            let token = UUID()
            activePlaybackToken = token
            do {
                try await engine.play(track: track, token: token)
                guard activePlaybackToken == token,
                      state.currentTrack?.id == track.id else {
                    return false
                }
                return true
            } catch {
                Log.playback.error("Failed to play '\(track.originalFilename, privacy: .public)': \(error)")

                guard activePlaybackToken == token,
                      state.currentTrack?.id == track.id,
                      let failedIndex = state.currentIndex else {
                    return false
                }
                activePlaybackToken = nil

                state.tracks.remove(at: failedIndex)
                FileStaging.remove(url: URL(fileURLWithPath: track.stagedPath))

                if state.tracks.indices.contains(failedIndex) {
                    state.currentIndex = failedIndex
                } else {
                    await finishExhaustedQueue()
                    return false
                }
            }
        }
        return false
    }

    private func pruneCompletedHistory() {
        guard let currentIndex = state.currentIndex else { return }
        let removalCount = max(0, currentIndex - 1)
        guard removalCount > 0 else { return }

        let removedTracks = Array(state.tracks.prefix(removalCount))
        state.tracks.removeFirst(removalCount)
        state.currentIndex = currentIndex - removalCount
        for track in removedTracks {
            FileStaging.remove(url: URL(fileURLWithPath: track.stagedPath))
        }
    }

    private func finishExhaustedQueue() async {
        let exhaustedTracks = state.tracks
        activePlaybackToken = nil
        state = QueueState()
        for track in exhaustedTracks {
            FileStaging.remove(url: URL(fileURLWithPath: track.stagedPath))
        }
        await engine.resetPlaybackError()
        Log.queue.info("Queue exhausted and cleared")
    }

    private func ensureTrackFinishedCallbackInstalled() async {
        guard !didInstallTrackFinishedCallback else { return }
        didInstallTrackFinishedCallback = true
        await engine.setTrackFinishedCallback { [weak self] token in
            guard let self else { return }
            await self.handleTrackFinished(token: token)
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
