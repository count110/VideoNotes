import Foundation

/// Persists an explicitly generated daily AI review where the local Feishu
/// companion can read it later. This is intentionally an archive of the
/// derived review, not a second store for raw notes. The companion owns the
/// date label it sends to Feishu, so this file intentionally contains only
/// the review body.
///
/// The Enhanced target is not sandboxed, so a predictable Documents location
/// gives the user's local automation a narrow, user-visible hand-off point.
enum DailyReviewArchive {

    enum RelativeDay {
        case today
        case yesterday
    }

    private static let reviewDirectoryName = "DailyReview"
    private static let timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current

    static func date(for relativeDay: RelativeDay, relativeTo referenceDate: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        switch relativeDay {
        case .today:
            return referenceDate
        case .yesterday:
            return calendar.date(byAdding: .day, value: -1, to: referenceDate) ?? referenceDate
        }
    }

    @discardableResult
    static func write(
        markdown: String,
        reviewDate: Date,
        noteCount _: Int,
        generatedAt _: Date = Date()
    ) throws -> URL {
        let fileManager = FileManager.default
        let directory = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent(reviewDirectoryName, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let fileURL = directory
            .appendingPathComponent("\(dayString(for: reviewDate)).md", isDirectory: false)
        // The bot already adds its own date wrapper. Keeping this hand-off
        // file to the generated prose avoids duplicate titles and metadata in
        // group replies, and leaves the archive useful as a clean review file.
        let body = markdown.trimmingCharacters(in: .whitespacesAndNewlines)

        // Atomic replacement means a crash cannot leave the bot with a
        // partially-written Markdown file. A later explicit generation for
        // the same day intentionally refreshes this derived review.
        try Data(body.utf8).write(to: fileURL, options: .atomic)
        return fileURL
    }

    private static func dayString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

}
