import Foundation
import Combine

// MARK: - Video Session

/// A locally timed study session for one video.
///
/// VideoNotes deliberately does not inspect a browser or media player's playback
/// position. The elapsed time is therefore based on the user's explicit session
/// controls and remains predictable across different video apps.
struct VideoSession: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    let startedAt: Date
    var accumulatedDuration: TimeInterval
    var resumedAt: Date?
    var endedAt: Date?

    init(title: String, startedAt: Date = Date()) {
        self.id = UUID()
        self.title = title
        self.startedAt = startedAt
        self.accumulatedDuration = 0
        self.resumedAt = startedAt
        self.endedAt = nil
    }

    var isRunning: Bool {
        resumedAt != nil && endedAt == nil
    }

    var isPaused: Bool {
        resumedAt == nil && endedAt == nil
    }

    func elapsedTime(at date: Date = Date()) -> TimeInterval {
        let runningDuration = resumedAt.map { max(0, date.timeIntervalSince($0)) } ?? 0
        return max(0, accumulatedDuration + runningDuration)
    }

    mutating func pause(at date: Date = Date()) {
        guard let resumedAt else { return }
        accumulatedDuration += max(0, date.timeIntervalSince(resumedAt))
        self.resumedAt = nil
    }

    mutating func resume(at date: Date = Date()) {
        guard endedAt == nil, resumedAt == nil else { return }
        resumedAt = date
    }

    mutating func end(at date: Date = Date()) {
        pause(at: date)
        endedAt = date
    }

    static func formattedTimestamp(for interval: TimeInterval) -> String {
        let totalSeconds = max(0, Int(interval.rounded(.down)))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

// MARK: - Video Session Manager

/// Owns the current session and persists session state separately from notes.
/// Completed sessions remain available so existing notes can always resolve
/// their title, even after the app is relaunched.
final class VideoSessionManager: ObservableObject {

    static let shared = VideoSessionManager()

    @Published private(set) var sessions: [VideoSession] = []
    @Published private(set) var currentSessionID: UUID?
    @Published private(set) var elapsedTime: TimeInterval = 0

    var currentSession: VideoSession? {
        guard let currentSessionID else { return nil }
        return sessions.first { $0.id == currentSessionID }
    }

    var isRunning: Bool {
        currentSession?.isRunning == true
    }

    private let storageFile: URL
    private var timer: Timer?
    private var lastCheckpointDate: Date?
    private let checkpointInterval: TimeInterval = 15

    private struct PersistedState: Codable {
        var sessions: [VideoSession]
        var currentSessionID: UUID?
    }

    private init() {
        let fileManager = FileManager.default
        let storageDirectory = ApplicationStorage.directory
        storageFile = storageDirectory.appendingPathComponent("video_sessions.json")

        try? fileManager.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        load()
        refreshElapsedTime()
        updateTimer()
    }

    deinit {
        timer?.invalidate()
    }

    // MARK: - Session controls

    @discardableResult
    func start(title: String, at date: Date = Date()) -> VideoSession? {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty, currentSession == nil else { return nil }

        let session = VideoSession(title: normalizedTitle, startedAt: date)
        sessions.insert(session, at: 0)
        currentSessionID = session.id
        elapsedTime = 0
        save()
        lastCheckpointDate = date
        updateTimer()
        return session
    }

    func pause(at date: Date = Date()) {
        updateCurrentSession { $0.pause(at: date) }
    }

    func resume(at date: Date = Date()) {
        updateCurrentSession { $0.resume(at: date) }
    }

    @discardableResult
    func endCurrentSession(at date: Date = Date()) -> VideoSession? {
        guard let index = currentSessionIndex else { return nil }
        sessions[index].end(at: date)
        let endedSession = sessions[index]
        currentSessionID = nil
        elapsedTime = 0
        save()
        updateTimer()
        return endedSession
    }

    func timestampForCurrentSession(at date: Date = Date()) -> (session: VideoSession, elapsed: TimeInterval)? {
        guard let session = currentSession else { return nil }
        return (session, session.elapsedTime(at: date))
    }

    /// A running timer must not count the time while VideoNotes is not running.
    /// The session remains selected, but is restored as paused at the next launch.
    func pauseForApplicationTermination(at date: Date = Date()) {
        pause(at: date)
    }

    /// Replaces or imports session state from a portable VideoNotes backup.
    /// Any session that was running in the backup is restored as paused so a
    /// computer-to-computer move never counts time while the app was closed.
    func restore(
        sessions importedSessions: [VideoSession],
        currentSessionID importedCurrentSessionID: UUID?
    ) {
        timer?.invalidate()
        timer = nil

        sessions = importedSessions.sorted { $0.startedAt > $1.startedAt }
        currentSessionID = importedCurrentSessionID.flatMap { id in
            sessions.contains { $0.id == id && $0.endedAt == nil } ? id : nil
        }

        if let index = currentSessionIndex, sessions[index].isRunning {
            sessions[index].pause(at: Date())
        }

        refreshElapsedTime()
        save()
        updateTimer()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: storageFile) else { return }

        do {
            let state = try JSONDecoder().decode(PersistedState.self, from: data)
            sessions = state.sessions.sorted { $0.startedAt > $1.startedAt }
            currentSessionID = state.currentSessionID.flatMap { id in
                sessions.contains(where: { $0.id == id && $0.endedAt == nil }) ? id : nil
            }

            // A process may be terminated without receiving
            // applicationWillTerminate(_:). Never count the time while it was
            // not running as video time; restore that session as explicitly
            // paused instead.
            if let index = currentSessionIndex, sessions[index].isRunning {
                sessions[index].resumedAt = nil
                save()
            }
        } catch {
            print("[VideoSessionManager] 加载失败: \(error)")
        }
    }

    private func save() {
        do {
            let state = PersistedState(sessions: sessions, currentSessionID: currentSessionID)
            let data = try JSONEncoder().encode(state)
            try data.write(to: storageFile, options: .atomic)
        } catch {
            print("[VideoSessionManager] 保存失败: \(error)")
        }
    }

    // MARK: - Clock

    private var currentSessionIndex: Int? {
        guard let currentSessionID else { return nil }
        return sessions.firstIndex { $0.id == currentSessionID }
    }

    private func updateCurrentSession(_ update: (inout VideoSession) -> Void) {
        guard let index = currentSessionIndex else { return }
        update(&sessions[index])
        refreshElapsedTime()
        save()
        lastCheckpointDate = sessions[index].isRunning ? Date() : nil
        updateTimer()
    }

    private func refreshElapsedTime(at date: Date = Date()) {
        elapsedTime = currentSession?.elapsedTime(at: date) ?? 0
    }

    private func updateTimer() {
        timer?.invalidate()
        timer = nil

        guard isRunning else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = Date()
            self.refreshElapsedTime(at: now)
            self.checkpointRunningSession(at: now)
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Checkpointing keeps an unexpected termination from losing an entire
    /// session. The recorded resume point is advanced to the checkpoint, so a
    /// later launch can safely restore the session as paused without counting
    /// the time while VideoNotes was not running.
    private func checkpointRunningSession(at date: Date) {
        guard let index = currentSessionIndex,
              sessions[index].isRunning,
              lastCheckpointDate == nil || date.timeIntervalSince(lastCheckpointDate!) >= checkpointInterval else {
            return
        }

        sessions[index].pause(at: date)
        sessions[index].resume(at: date)
        lastCheckpointDate = date
        save()
    }
}
