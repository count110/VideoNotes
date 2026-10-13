import Combine
import Foundation

// MARK: - Platform subtitle extraction

/// One caption track advertised by a video platform through yt-dlp. The app
/// presents creator-provided tracks before automatic tracks so the user never
/// mistakes a machine transcript for the original subtitle.
struct VideoPlatformSubtitleTrack: Identifiable, Hashable {
    let languageCode: String
    let languageName: String
    let captionKind: VideoSubtitleCaptionKind
    let preferredExtension: String
    let availableExtensions: [String]

    var id: String { "\(captionKind.rawValue)|\(languageCode)" }

    var formatSummary: String {
        availableExtensions.map { $0.uppercased() }.joined(separator: " / ")
    }
}

/// Optional local bridge to the open-source yt-dlp executable.
///
/// VideoNotes can use its managed local copy of yt-dlp, or an executable the
/// user explicitly selects. It never configures cookies or logs into yt-dlp;
/// every extraction runs with `--ignore-config`, `--skip-download` and a
/// temporary output path. Therefore it can only retrieve a public subtitle
/// track that the platform already exposes, never a video file or a protected
/// stream.
final class YTDLPSubtitleClient: ObservableObject {

    static let shared = YTDLPSubtitleClient()

    @Published private(set) var isRunning = false
    @Published private(set) var lastError: String?

    private static let executablePathKey = "ytDLPSubtitleExecutablePath"
    private static let metadataTimeout: TimeInterval = 90
    private static let subtitleDownloadTimeout: TimeInterval = 4 * 60

    private let activeRunLock = NSLock()
    private var activeProcess: Process?
    private var activeRunState: SubtitleProcessRunState?

    enum SubtitleExtractorError: LocalizedError {
        case executableNotFound
        case invalidVideoURL
        case invalidMetadata
        case noSupportedSubtitles
        case noDownloadedSubtitle
        case processLaunchFailed(String)
        case processFailed(Int32, String)
        case timedOut(TimeInterval)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .executableNotFound:
                return "没有找到 yt-dlp。请在设置 → 字幕中选择它的可执行文件，或使用自动检测。"
            case .invalidVideoURL:
                return "平台提取需要当前视频的公开 HTTPS 链接；可在导入字幕时手动填写。"
            case .invalidMetadata:
                return "平台没有返回可识别的字幕信息。"
            case .noSupportedSubtitles:
                return "这个视频没有可直接导入的 SRT、VTT、ASS、SSA、LRC、SUB 或文本字幕。"
            case .noDownloadedSubtitle:
                return "平台没有输出可读取的字幕文件。"
            case .processLaunchFailed(let message):
                return "无法启动 yt-dlp：\(message)"
            case .processFailed(let status, let message):
                if message.isEmpty {
                    return "yt-dlp 提取失败（退出码 \(status)）"
                }
                return "yt-dlp 提取失败：\(message)"
            case .timedOut:
                return "读取平台字幕超时，任务已停止。"
            case .cancelled:
                return "已取消平台字幕提取。"
            }
        }
    }

    private init() {}

    /// Empty means automatic discovery. A deliberately entered but invalid
    /// path remains visible in Settings instead of silently using another
    /// executable on the machine.
    var configuredExecutablePath: String {
        UserDefaults.standard.string(forKey: Self.executablePathKey) ?? ""
    }

    var resolvedExecutablePath: String? {
        let configured = configuredExecutablePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configured.isEmpty {
            return isExecutable(at: configured) ? configured : nil
        }

        return automaticCandidates.first(where: isExecutable(at:))
    }

    var resolvedExecutableDisplayPath: String {
        resolvedExecutablePath ?? "未找到"
    }

    func setExecutablePath(_ path: String) {
        let normalized = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.executablePathKey)
        } else {
            UserDefaults.standard.set(normalized, forKey: Self.executablePathKey)
        }
    }

    func resetToAutomaticDiscovery() {
        setExecutablePath("")
    }

    func testConnection(completion: @escaping (Result<String, Error>) -> Void) {
        run(arguments: ["--version"], timeout: 30) { result in
            switch result {
            case .success(let output):
                let version = output
                    .split(whereSeparator: \.isNewline)
                    .first
                    .map(String.init) ?? "yt-dlp"
                completion(.success(version))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    /// Lists creator-provided and automatic captions separately. Nothing is
    /// downloaded at this stage, including the video itself.
    func listAvailableSubtitles(
        for target: VideoSubtitleTarget,
        completion: @escaping (Result<[VideoPlatformSubtitleTrack], Error>) -> Void
    ) {
        let sourceURL: URL
        do {
            sourceURL = try validatedVideoURL(for: target)
        } catch {
            deliver(.failure(error), completion: completion)
            return
        }

        run(
            arguments: [
                "--ignore-config",
                "--skip-download",
                "--no-playlist",
                "--no-warnings",
                "--no-progress",
                "--dump-single-json",
                "--",
                sourceURL.absoluteString
            ],
            timeout: Self.metadataTimeout
        ) { result in
            switch result {
            case .success(let output):
                do {
                    completion(.success(try Self.parseTracks(from: output)))
                } catch {
                    completion(.failure(error))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    /// Downloads exactly one selected subtitle track into a temporary
    /// directory, parses it through VideoSubtitleParser, then deletes the
    /// temporary file. The caller is the only code that decides whether the
    /// resulting draft is persisted.
    func downloadSubtitle(
        _ track: VideoPlatformSubtitleTrack,
        for target: VideoSubtitleTarget,
        completion: @escaping (Result<VideoSubtitleDraft, Error>) -> Void
    ) {
        let sourceURL: URL
        do {
            sourceURL = try validatedVideoURL(for: target)
        } catch {
            deliver(.failure(error), completion: completion)
            return
        }

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("videonotes-platform-subtitle-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: temporaryDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            deliver(
                .failure(SubtitleExtractorError.processLaunchFailed(error.localizedDescription)),
                completion: completion
            )
            return
        }

        let outputTemplate = temporaryDirectory
            .appendingPathComponent("subtitle.%(ext)s")
            .path
        let writeArgument = track.captionKind == .creatorProvided
            ? "--write-subs"
            : "--write-auto-subs"

        run(
            arguments: [
                "--ignore-config",
                "--skip-download",
                "--no-playlist",
                "--no-warnings",
                "--no-progress",
                writeArgument,
                "--sub-langs", track.languageCode,
                "--sub-format", "\(track.preferredExtension)/best",
                "--output", outputTemplate,
                "--",
                sourceURL.absoluteString
            ],
            timeout: Self.subtitleDownloadTimeout
        ) { result in
            switch result {
            case .success:
                DispatchQueue.global(qos: .userInitiated).async {
                    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
                    do {
                        guard let subtitleURL = Self.findDownloadedSubtitle(
                            in: temporaryDirectory,
                            preferring: track.preferredExtension
                        ) else {
                            self.deliver(.failure(SubtitleExtractorError.noDownloadedSubtitle), completion: completion)
                            return
                        }

                        let provider = Self.providerName(for: sourceURL)
                        let sourceName = "\(provider) · \(track.languageName) · \(track.captionKind.displayName).\(subtitleURL.pathExtension.lowercased())"
                        let draft = try VideoSubtitleParser.draft(
                            fromPlatformFile: subtitleURL,
                            sourceName: sourceName,
                            sourceURL: sourceURL,
                            provider: provider,
                            languageCode: track.languageCode,
                            captionKind: track.captionKind
                        )
                        self.deliver(.success(draft), completion: completion)
                    } catch {
                        self.deliver(.failure(error), completion: completion)
                    }
                }
            case .failure(let error):
                try? FileManager.default.removeItem(at: temporaryDirectory)
                completion(.failure(error))
            }
        }
    }

    func cancelCurrentRun() {
        activeRunLock.lock()
        let process = activeProcess
        let state = activeRunState
        activeRunLock.unlock()

        guard let process, let state, process.isRunning else { return }
        if state.requestStop(.cancelled) {
            process.terminate()
        }
    }

    private var automaticCandidates: [String] {
        [
            ApplicationStorage.directory
                .appendingPathComponent("Tools", isDirectory: true)
                .appendingPathComponent("yt-dlp", isDirectory: false)
                .path,
            "/opt/homebrew/bin/yt-dlp",
            "/usr/local/bin/yt-dlp",
            "/usr/bin/yt-dlp"
        ]
    }

    private func isExecutable(at path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }

    private func validatedVideoURL(for target: VideoSubtitleTarget) throws -> URL {
        guard let rawURL = target.videoURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: rawURL),
              VideoSubtitleRemoteLoader.acceptsPublicHTTPSSource(url) else {
            throw SubtitleExtractorError.invalidVideoURL
        }
        return url
    }

    private struct VideoInfo: Decodable {
        let subtitles: [String: [SubtitleRepresentation]]?
        let automaticCaptions: [String: [SubtitleRepresentation]]?

        enum CodingKeys: String, CodingKey {
            case subtitles
            case automaticCaptions = "automatic_captions"
        }
    }

    private struct SubtitleRepresentation: Decodable {
        let ext: String?
        let name: String?
    }

    private static func parseTracks(from output: String) throws -> [VideoPlatformSubtitleTrack] {
        guard let data = output.data(using: .utf8),
              let info = try? JSONDecoder().decode(VideoInfo.self, from: data) else {
            throw SubtitleExtractorError.invalidMetadata
        }

        let sources: [(VideoSubtitleCaptionKind, [String: [SubtitleRepresentation]])] = [
            (.creatorProvided, info.subtitles ?? [:]),
            (.automatic, info.automaticCaptions ?? [:])
        ]

        var tracks: [VideoPlatformSubtitleTrack] = []
        for (captionKind, languageMap) in sources {
            for languageCode in languageMap.keys.sorted(by: localizedLanguageSort) {
                guard let representations = languageMap[languageCode] else { continue }
                let supportedExtensions = uniqueSupportedExtensions(from: representations)
                guard let preferredExtension = supportedExtensions.first else { continue }

                let suppliedName = representations
                    .compactMap(\.name)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first(where: { !$0.isEmpty })
                tracks.append(
                    VideoPlatformSubtitleTrack(
                        languageCode: languageCode,
                        languageName: suppliedName ?? displayLanguageName(for: languageCode),
                        captionKind: captionKind,
                        preferredExtension: preferredExtension,
                        availableExtensions: supportedExtensions
                    )
                )
            }
        }

        guard !tracks.isEmpty else {
            throw SubtitleExtractorError.noSupportedSubtitles
        }

        return tracks.sorted { lhs, rhs in
            if lhs.captionKind != rhs.captionKind {
                return lhs.captionKind == .creatorProvided
            }
            return localizedLanguageSort(lhs.languageCode, rhs.languageCode)
        }
    }

    private static func uniqueSupportedExtensions(
        from representations: [SubtitleRepresentation]
    ) -> [String] {
        let ranks: [String: Int] = [
            "vtt": 0,
            "srt": 1,
            "ass": 2,
            "ssa": 3,
            "lrc": 4,
            "sub": 5,
            "txt": 6
        ]
        let unique = Set(representations.compactMap { representation -> String? in
            guard let rawExtension = representation.ext?.lowercased(),
                  ranks[rawExtension] != nil else {
                return nil
            }
            return rawExtension
        })
        return unique.sorted { lhs, rhs in
            (ranks[lhs] ?? .max) < (ranks[rhs] ?? .max)
        }
    }

    private static func displayLanguageName(for languageCode: String) -> String {
        let normalized = languageCode.replacingOccurrences(of: "_", with: "-")
        let locale = Locale(identifier: "zh_CN")
        return locale.localizedString(forLanguageCode: normalized) ?? languageCode
    }

    private static func localizedLanguageSort(_ lhs: String, _ rhs: String) -> Bool {
        lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
    }

    private static func providerName(for videoURL: URL) -> String {
        let host = (videoURL.host ?? "视频平台")
            .lowercased()
            .replacingOccurrences(of: "www.", with: "")
        if host.contains("youtube.com") || host == "youtu.be" { return "YouTube" }
        if host.contains("bilibili.com") { return "哔哩哔哩" }
        if host.contains("vimeo.com") { return "Vimeo" }
        if host.contains("twitch.tv") { return "Twitch" }
        return host.isEmpty ? "视频平台" : host
    }

    private static func findDownloadedSubtitle(
        in directory: URL,
        preferring preferredExtension: String
    ) -> URL? {
        let fileManager = FileManager.default
        let urls = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let subtitleURLs = urls.filter { VideoSubtitleParser.isSupportedFile($0) }
        return subtitleURLs.sorted { lhs, rhs in
            let lhsPreferred = lhs.pathExtension.lowercased() == preferredExtension
            let rhsPreferred = rhs.pathExtension.lowercased() == preferredExtension
            if lhsPreferred != rhsPreferred { return lhsPreferred }
            return lhs.lastPathComponent.localizedCaseInsensitiveCompare(rhs.lastPathComponent) == .orderedAscending
        }.first
    }

    private func run(
        arguments: [String],
        timeout: TimeInterval,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard let executablePath = resolvedExecutablePath else {
            deliver(.failure(SubtitleExtractorError.executableNotFound), completion: completion)
            return
        }

        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let runState = SubtitleProcessRunState()

        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.environment = ProcessInfo.processInfo.environment

        DispatchQueue.main.async { [weak self] in
            self?.isRunning = true
            self?.lastError = nil
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                try process.run()
                self.setActiveRun(process: process, state: runState)
                defer { self.clearActiveRun(process: process) }

                // Drain both streams while yt-dlp runs. Metadata for a large
                // playlist redirect can otherwise fill stderr and falsely
                // make a subtitle-only request appear frozen.
                let readGroup = DispatchGroup()
                var outputData = Data()
                var errorData = Data()

                readGroup.enter()
                DispatchQueue.global(qos: .utility).async {
                    outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                    readGroup.leave()
                }
                readGroup.enter()
                DispatchQueue.global(qos: .utility).async {
                    errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    readGroup.leave()
                }

                let timeoutWorkItem = DispatchWorkItem {
                    if process.isRunning, runState.requestStop(.timedOut) {
                        process.terminate()
                    }
                }
                DispatchQueue.global(qos: .utility).asyncAfter(
                    deadline: .now() + timeout,
                    execute: timeoutWorkItem
                )

                process.waitUntilExit()
                timeoutWorkItem.cancel()
                readGroup.wait()

                let stdout = String(data: outputData, encoding: .utf8) ?? ""
                let stderr = String(data: errorData, encoding: .utf8) ?? ""
                guard process.terminationStatus == 0 else {
                    let result: Result<String, Error>
                    switch runState.stopReason {
                    case .timedOut:
                        result = .failure(SubtitleExtractorError.timedOut(timeout))
                    case .cancelled:
                        result = .failure(SubtitleExtractorError.cancelled)
                    case nil:
                        result = .failure(
                            SubtitleExtractorError.processFailed(
                                process.terminationStatus,
                                Self.conciseFailureMessage(stderr: stderr, stdout: stdout)
                            )
                        )
                    }
                    self.deliver(result, completion: completion)
                    return
                }

                self.deliver(
                    .success(stdout.trimmingCharacters(in: .whitespacesAndNewlines)),
                    completion: completion
                )
            } catch {
                self.deliver(
                    .failure(SubtitleExtractorError.processLaunchFailed(error.localizedDescription)),
                    completion: completion
                )
            }
        }
    }

    private func setActiveRun(process: Process, state: SubtitleProcessRunState) {
        activeRunLock.lock()
        activeProcess = process
        activeRunState = state
        activeRunLock.unlock()
    }

    private func clearActiveRun(process: Process) {
        activeRunLock.lock()
        if activeProcess === process {
            activeProcess = nil
            activeRunState = nil
        }
        activeRunLock.unlock()
    }

    private static func conciseFailureMessage(stderr: String, stdout: String) -> String {
        let source = stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? stdout
            : stderr
        let lines = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else { return "" }
        let tail = lines.suffix(10).joined(separator: "\n")
        return tail.count <= 1_500 ? tail : "…" + String(tail.suffix(1_499))
    }

    private func deliver<T>(
        _ result: Result<T, Error>,
        completion: @escaping (Result<T, Error>) -> Void
    ) {
        DispatchQueue.main.async { [weak self] in
            self?.isRunning = false
            if case .failure(let error) = result {
                self?.lastError = error.localizedDescription
            }
            completion(result)
        }
    }
}

private final class SubtitleProcessRunState {
    enum StopReason {
        case timedOut
        case cancelled
    }

    private let lock = NSLock()
    private var storedStopReason: StopReason?

    var stopReason: StopReason? {
        lock.lock()
        defer { lock.unlock() }
        return storedStopReason
    }

    @discardableResult
    func requestStop(_ reason: StopReason) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard storedStopReason == nil else { return false }
        storedStopReason = reason
        return true
    }
}
