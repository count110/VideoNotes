import AppKit

// MARK: - ScreenshotService

/// 截图 / 图片附件服务。
///
/// 为避免系统屏幕录制权限带来的摩擦，第一版不内置截图捕获，只负责：
/// 1. 把用户粘贴到输入框里的截图保存到本地 PNG；
/// 2. 统一截图附件的存储目录，方便以后重新接入 ScreenCaptureKit / OCR。
final class ScreenshotService {

    static let shared = ScreenshotService()

    private init() {}

    // MARK: - Public

    /// 把用户粘贴的图片保存到本地截图目录，返回文件 URL。
    func savePastedImage(_ image: NSImage) -> URL? {
        NSLog("[VNPasteDiag] step6a: savePastedImage input size=\(image.size.width)x\(image.size.height)")
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            NSLog("[VNPasteDiag] step6a-fail: cannot create CGImage")
            return nil
        }
        let url = savePNG(cgImage)
        NSLog("[VNPasteDiag] step6a-ok: savePNG returned=\(url?.path ?? "nil")")
        return url
    }

    // MARK: - Persistence

    private func savePNG(_ image: CGImage) -> URL? {
        let screenshotsDirectory = ApplicationStorage.directory
            .appendingPathComponent("Screenshots", isDirectory: true)

        do {
            try FileManager.default.createDirectory(
                at: screenshotsDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            NSLog("[ScreenshotService] 无法创建截图目录: \(error.localizedDescription)")
            return nil
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let filename = "clip-\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(8)).png"
        let fileURL = screenshotsDirectory.appendingPathComponent(filename)

        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            NSLog("[ScreenshotService] PNG 编码失败")
            return nil
        }

        do {
            try data.write(to: fileURL, options: .atomic)
            return fileURL
        } catch {
            NSLog("[ScreenshotService] 截图写入失败: \(error.localizedDescription)")
            return nil
        }
    }
}
