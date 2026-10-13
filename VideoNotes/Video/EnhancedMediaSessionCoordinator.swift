import Combine
import CryptoKit
import Foundation

/// Reads the system's private now-playing state for the separately distributed
/// Enhanced build.
///
/// Important: this source belongs only to the `VideoNotes Enhanced` target. The
/// App Store target neither compiles this file nor contains the private API
/// names embedded in the AppleScript below.
final class EnhancedMediaSessionCoordinator: ObservableObject {

    static let shared = EnhancedMediaSessionCoordinator()

    /// A display snapshot for the lightweight indicator in the input panel and
    /// Settings. All writes happen on the main queue.
    @Published private(set) var currentDisplay: MediaCaptureContext?

    private struct RefreshRequest: Equatable {
        let expectedSourceBundleIdentifier: String?

        init(expectedSourceBundleIdentifier: String?) {
            let normalized = expectedSourceBundleIdentifier?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            self.expectedSourceBundleIdentifier = normalized?.isEmpty == false
                ? normalized
                : nil
        }
    }

    private struct NowPlayingPayload: Decodable {
        let bundleIdentifier: String?
        let parentApplicationBundleIdentifier: String?
        let applicationName: String?
        let title: String?
        let elapsedTime: Double?
        let duration: Double?
        let playbackRate: Double?
        let timestamp: Double?
        let assetURL: String?
        let externalContentIdentifier: String?
        let uniqueIdentifier: String?
        let contentItemIdentifier: String?
        let isPlaying: Bool?
    }

    private struct CachedMedia {
        let sessionID: UUID
        let title: String
        let url: String?
        let elapsedTime: TimeInterval
        let duration: TimeInterval?
        let isPlaying: Bool
        let playbackRate: Double
        let anchorDate: Date
        let receivedAt: Date
        let sourceBundleIdentifier: String?
        let parentApplicationBundleIdentifier: String?
        let sourceApplicationName: String?

        func matches(sourceBundleIdentifier expected: String?) -> Bool {
            guard let expected = Self.normalizedBundleIdentifier(expected) else {
                return true
            }

            return [sourceBundleIdentifier, parentApplicationBundleIdentifier]
                .compactMap(Self.normalizedBundleIdentifier)
                .contains(expected)
        }

        func context(at date: Date) -> MediaCaptureContext {
            let elapsedSinceAnchor = max(0, date.timeIntervalSince(anchorDate))
            let projectedElapsed = elapsedTime + elapsedSinceAnchor * playbackRate
            let nonnegativeElapsed = max(0, projectedElapsed)
            let boundedElapsed = duration.map { min(nonnegativeElapsed, $0) }
                ?? nonnegativeElapsed

            return MediaCaptureContext(
                sessionID: sessionID,
                title: title,
                url: url,
                elapsedTime: boundedElapsed,
                duration: duration,
                isPlaying: isPlaying,
                sourceBundleIdentifier: sourceBundleIdentifier,
                sourceApplicationName: sourceApplicationName,
                capturedAt: date
            )
        }

        private static func normalizedBundleIdentifier(_ value: String?) -> String? {
            let normalized = value?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            return normalized?.isEmpty == false ? normalized : nil
        }
    }

    private let stateQueue = DispatchQueue(
        label: "com.videonotes.enhanced.media-session",
        qos: .utility
    )
    private let cacheLifetime: TimeInterval = 30
    private let processTimeout: TimeInterval = 3

    private var isStarted = false
    private var cachedMedia: CachedMedia?
    private var runningProcess: Process?
    private var runningRequest: RefreshRequest?
    private var pendingRequest: RefreshRequest?

    private init() {}

    /// Enables automatic media capture and performs one initial refresh. Media
    /// polling is deliberately avoided; the input panel and Settings request
    /// refreshes only when the result is useful.
    func start() {
        stateQueue.async { [weak self] in
            guard let self, !self.isStarted else { return }
            self.isStarted = true
            self.enqueueRefresh(
                RefreshRequest(expectedSourceBundleIdentifier: nil)
            )
        }
    }

    /// Stops new reads, terminates an in-flight helper, and removes any cached
    /// state. Calling this method never waits for the helper process to exit.
    func stop() {
        stateQueue.sync {
            self.isStarted = false
            self.pendingRequest = nil
            self.runningRequest = nil
            self.cachedMedia = nil

            let process = self.runningProcess
            self.runningProcess = nil
            if process?.isRunning == true {
                process?.terminate()
            }

            self.publish(nil)
        }
    }

    /// Refreshes in the background. Concurrent requests are coalesced so only
    /// one `osascript` process can exist at a time. When the source changes
    /// during an in-flight request, only the most recent source is queried next.
    func refresh(expectedSourceBundleIdentifier: String? = nil) {
        let request = RefreshRequest(
            expectedSourceBundleIdentifier: expectedSourceBundleIdentifier
        )

        stateQueue.async { [weak self] in
            guard let self, self.isStarted else { return }
            self.enqueueRefresh(request)
        }
    }

    /// Returns a cheap, locally projected capture from the latest media
    /// snapshot. No process or private query is performed on the caller's
    /// thread, which keeps typing and IME composition responsive.
    func captureContext(
        at date: Date,
        expectedSourceBundleIdentifier: String? = nil
    ) -> MediaCaptureContext? {
        stateQueue.sync {
            // Do not use an older snapshot while a foreground-triggered query
            // is in flight. Two videos inside the same player have the same
            // bundle identifier, so source matching alone cannot tell that the
            // user just switched videos. Skipping automatic attachment for
            // this brief window is safer than writing a note to the prior one.
            guard runningProcess == nil,
                  pendingRequest == nil,
                  let cachedMedia,
                  date.timeIntervalSince(cachedMedia.receivedAt) <= cacheLifetime,
                  cachedMedia.matches(
                    sourceBundleIdentifier: expectedSourceBundleIdentifier
                  ) else {
                return nil
            }

            return cachedMedia.context(at: date)
        }
    }

    // MARK: - Refresh orchestration

    private func enqueueRefresh(_ request: RefreshRequest) {
        guard runningProcess == nil else {
            // Repeated SwiftUI appearances can ask for the same refresh while
            // one is already running. The pending slot always reflects the
            // newest request; returning to the in-flight source cancels an
            // older pending request because the running result is sufficient.
            pendingRequest = request == runningRequest ? nil : request
            return
        }

        launchRefresh(request)
    }

    private func launchRefresh(_ request: RefreshRequest) {
        guard isStarted else { return }

        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", Self.nowPlayingAppleScript]
        process.standardOutput = standardOutput
        process.standardError = standardError

        process.terminationHandler = { [weak self] completedProcess in
            guard let self else { return }
            let output = standardOutput.fileHandleForReading.readDataToEndOfFile()
            let errorOutput = standardError.fileHandleForReading.readDataToEndOfFile()

            self.stateQueue.async {
                self.finishRefresh(
                    process: completedProcess,
                    request: request,
                    terminationStatus: completedProcess.terminationStatus,
                    output: output,
                    errorOutput: errorOutput
                )
            }
        }

        runningProcess = process
        runningRequest = request

        do {
            try process.run()
        } catch {
            runningProcess = nil
            runningRequest = nil
            clearCachedMedia(
                reason: "无法启动媒体读取进程：\(error.localizedDescription)"
            )
            launchPendingRefreshIfNeeded()
            return
        }

        stateQueue.asyncAfter(deadline: .now() + processTimeout) { [weak self, weak process] in
            guard let self,
                  let process,
                  self.runningProcess === process,
                  process.isRunning else {
                return
            }
            NSLog("[EnhancedMedia] 媒体读取超时，已终止本次请求")
            process.terminate()
        }
    }

    private func finishRefresh(
        process: Process,
        request: RefreshRequest,
        terminationStatus: Int32,
        output: Data,
        errorOutput: Data
    ) {
        // A stopped or superseded process must never publish stale state.
        guard runningProcess === process else { return }
        runningProcess = nil
        runningRequest = nil
        guard isStarted else { return }

        // If the foreground source changed while this query was running, skip
        // publishing its result and immediately serve the newest request.
        if pendingRequest != nil {
            launchPendingRefreshIfNeeded()
            return
        }

        guard terminationStatus == 0 else {
            let message = String(data: errorOutput, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            clearCachedMedia(
                reason: message?.isEmpty == false
                    ? message!
                    : "媒体读取进程退出码 \(terminationStatus)"
            )
            return
        }

        do {
            let payload = try JSONDecoder().decode(
                NowPlayingPayload.self,
                from: output
            )
            guard let media = Self.makeCachedMedia(
                from: payload,
                receivedAt: Date()
            ) else {
                clearCachedMedia(reason: nil)
                return
            }

            guard media.matches(
                sourceBundleIdentifier: request.expectedSourceBundleIdentifier
            ) else {
                clearCachedMedia(reason: nil)
                return
            }

            cachedMedia = media
            publish(media.context(at: media.receivedAt))
        } catch {
            clearCachedMedia(
                reason: "媒体信息解析失败：\(error.localizedDescription)"
            )
        }
    }

    private func launchPendingRefreshIfNeeded() {
        guard isStarted, let request = pendingRequest else { return }
        pendingRequest = nil
        launchRefresh(request)
    }

    private func clearCachedMedia(reason: String?) {
        cachedMedia = nil
        publish(nil)
        if let reason {
            NSLog("[EnhancedMedia] \(reason)")
        }
    }

    private func publish(_ context: MediaCaptureContext?) {
        DispatchQueue.main.async { [weak self] in
            self?.currentDisplay = context
        }
    }

    // MARK: - Payload normalization

    private static func makeCachedMedia(
        from payload: NowPlayingPayload,
        receivedAt: Date
    ) -> CachedMedia? {
        guard let title = normalizedText(payload.title) else { return nil }

        let elapsed = finiteNonnegative(payload.elapsedTime) ?? 0
        let duration = finitePositive(payload.duration)
        let isPlaying = payload.isPlaying ?? false
        let reportedRate = payload.playbackRate.flatMap { value in
            value.isFinite ? max(0, value) : nil
        }
        let playbackRate: Double
        if isPlaying {
            // A few players briefly publish `isPlaying = true` together with a
            // zero/missing rate while transitioning. Advancing at normal speed
            // is a safer short-lived projection until the next refresh.
            playbackRate = (reportedRate ?? 0) > 0 ? reportedRate! : 1
        } else {
            playbackRate = 0
        }
        let anchorDate = payload.timestamp.flatMap { timestamp -> Date? in
            guard timestamp.isFinite, timestamp > 0 else { return nil }
            return Date(timeIntervalSince1970: timestamp)
        } ?? receivedAt
        let normalizedURL = normalizedURLString(payload.assetURL)
        let bundleIdentifier = normalizedText(payload.bundleIdentifier)
        let parentBundleIdentifier = normalizedText(
            payload.parentApplicationBundleIdentifier
        )
        let applicationName = normalizedText(payload.applicationName)

        let identitySource = bundleIdentifier
            ?? parentBundleIdentifier
            ?? applicationName
            ?? "unknown-player"
        let identity: String
        if let normalizedURL {
            identity = "url|\(identitySource.lowercased())|\(normalizedURL)"
        } else if let externalIdentifier = normalizedText(
            payload.externalContentIdentifier
        ) {
            identity = "external|\(identitySource.lowercased())|\(externalIdentifier)"
        } else if let uniqueIdentifier = normalizedText(payload.uniqueIdentifier) {
            identity = "unique|\(identitySource.lowercased())|\(uniqueIdentifier)"
        } else {
            // `contentItemIdentifier` is intentionally not preferred: several
            // players generate a new UUID for every playback instance. Title
            // plus rounded duration gives the history view a more stable group.
            let roundedDuration = duration.map { String(Int($0.rounded())) }
                ?? "unknown-duration"
            identity = "title|\(identitySource.lowercased())|\(normalizedIdentityText(title))|\(roundedDuration)"
        }

        return CachedMedia(
            sessionID: versionFiveUUID(for: identity),
            title: title,
            url: normalizedURL,
            elapsedTime: duration.map { min(elapsed, $0) } ?? elapsed,
            duration: duration,
            isPlaying: isPlaying,
            playbackRate: playbackRate,
            anchorDate: anchorDate,
            receivedAt: receivedAt,
            sourceBundleIdentifier: bundleIdentifier,
            parentApplicationBundleIdentifier: parentBundleIdentifier,
            sourceApplicationName: applicationName
        )
    }

    private static func normalizedText(_ value: String?) -> String? {
        let value = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    private static func normalizedIdentityText(_ value: String) -> String {
        value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()
    }

    private static func finiteNonnegative(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return max(0, value)
    }

    private static func finitePositive(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    private static func normalizedURLString(_ value: String?) -> String? {
        guard let value = normalizedText(value) else { return nil }
        guard var components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              components.host?.isEmpty == false else {
            // Players also expose file URLs, internal asset identifiers, and
            // custom callback schemes through AssetURL. They are not portable
            // video links and must not be written into a note as though they
            // could reopen the source video.
            return nil
        }

        components.scheme = scheme
        components.host = components.host?.lowercased()
        components.fragment = nil
        if let queryItems = components.queryItems, !queryItems.isEmpty {
            components.queryItems = queryItems.sorted {
                if $0.name == $1.name {
                    return ($0.value ?? "") < ($1.value ?? "")
                }
                return $0.name < $1.name
            }
        }
        return components.string ?? value
    }

    /// A deterministic UUID with RFC 4122 version/variant bits. The fixed
    /// namespace keeps the same media identity grouped across app launches.
    private static func versionFiveUUID(for identity: String) -> UUID {
        let namespace = "VideoNotes.Enhanced.MediaSession.v1"
        let digest = Insecure.SHA1.hash(
            data: Data("\(namespace)|\(identity)".utf8)
        )
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80

        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    // MARK: - Private bridge

    /// AppleScriptObjC is used instead of linking MediaRemote. Direct
    /// `MRMediaRemoteGetNowPlayingInfo` calls return no data for ordinary
    /// third-party processes on newer macOS releases, while the system's own
    /// osascript host can still query MRNowPlayingRequest.
    private static let nowPlayingAppleScript = #"""
use scripting additions
use framework "/System/Library/PrivateFrameworks/MediaRemote.framework"

set MRNowPlayingRequest to current application's NSClassFromString("MRNowPlayingRequest")
if MRNowPlayingRequest is missing value then return "{}"

set itemObj to MRNowPlayingRequest's localNowPlayingItem()
if itemObj is missing value then return "{}"

set infoDict to itemObj's nowPlayingInfo()
if infoDict is missing value then return "{}"

set playerPath to MRNowPlayingRequest's localNowPlayingPlayerPath()
set clientObj to missing value
if playerPath is not missing value then set clientObj to playerPath's client()

set payload to current application's NSMutableDictionary's dictionary()

if clientObj is not missing value then
    set bundleID to clientObj's bundleIdentifier()
    if bundleID is not missing value then payload's setObject:bundleID forKey:"bundleIdentifier"

    set appName to clientObj's displayName()
    if appName is not missing value then payload's setObject:appName forKey:"applicationName"

    if (clientObj's respondsToSelector:"parentApplicationBundleIdentifier") as boolean then
        set parentBundleID to clientObj's parentApplicationBundleIdentifier()
        if parentBundleID is not missing value then payload's setObject:parentBundleID forKey:"parentApplicationBundleIdentifier"
    end if
end if

payload's setObject:(MRNowPlayingRequest's localIsPlaying()) forKey:"isPlaying"

repeat with mapping in {{"kMRMediaRemoteNowPlayingInfoTitle", "title"}, {"kMRMediaRemoteNowPlayingInfoElapsedTime", "elapsedTime"}, {"kMRMediaRemoteNowPlayingInfoDuration", "duration"}, {"kMRMediaRemoteNowPlayingInfoPlaybackRate", "playbackRate"}, {"kMRMediaRemoteNowPlayingInfoTimestamp", "timestamp"}, {"kMRMediaRemoteNowPlayingInfoAssetURL", "assetURL"}, {"kMRMediaRemoteNowPlayingInfoExternalContentIdentifier", "externalContentIdentifier"}, {"kMRMediaRemoteNowPlayingInfoUniqueIdentifier", "uniqueIdentifier"}, {"kMRMediaRemoteNowPlayingInfoContentItemIdentifier", "contentItemIdentifier"}}
    set sourceKey to item 1 of mapping
    set outputKey to item 2 of mapping
    set valueObj to infoDict's objectForKey:sourceKey

    if valueObj is not missing value then
        if outputKey is "timestamp" then
            set valueObj to valueObj's timeIntervalSince1970()
        else if outputKey is "assetURL" then
            if (valueObj's respondsToSelector:"absoluteString") as boolean then
                set valueObj to valueObj's absoluteString()
            else
                set valueObj to valueObj's description()
            end if
        end if
        payload's setObject:valueObj forKey:outputKey
    end if
end repeat

set jsonData to current application's NSJSONSerialization's dataWithJSONObject:payload options:0 |error|:(missing value)
if jsonData is missing value then return "{}"
return (current application's NSString's alloc()'s initWithData:jsonData encoding:(current application's NSUTF8StringEncoding)) as text
"""#
}
