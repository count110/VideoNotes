import SwiftUI
import AppKit

// MARK: - Shared visual language

enum VNStyle {
    static let accent = Color(red: 0.30, green: 0.43, blue: 0.98)
    static let cyan = Color(red: 0.18, green: 0.76, blue: 0.98)
    static let violet = Color(red: 0.56, green: 0.37, blue: 0.96)
    static let inputPrimaryText = Color.white
    static let inputSecondaryText = Color.white.opacity(0.90)
    static let hudPrimaryText = Color.white.opacity(0.97)
    static let hudPlaceholderText = Color.white.opacity(0.62)
    static let hudSupportingText = Color.white.opacity(0.64)
    static let cornerRadius: CGFloat = 22

    static var appBackground: LinearGradient {
        LinearGradient(
            colors: [
                Color(nsColor: .windowBackgroundColor),
                accent.opacity(0.055),
                violet.opacity(0.035)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

// MARK: - Floating note states and layout

enum NoteOverlayState: Equatable {
    case collapsed
    case writing
    case expanded
    case saved

    var cardHeight: CGFloat {
        switch self {
        case .collapsed, .saved: return 54
        case .writing: return 142
        case .expanded: return 300
        }
    }

    var cornerRadius: CGFloat {
        switch self {
        case .collapsed, .saved: return 27
        case .writing: return 30
        case .expanded: return 31
        }
    }
}

enum FloatingInputLayout {
    static let defaultCardWidth: CGFloat = 800
    static let minimumCardWidth: CGFloat = 320
    static let maximumCardWidth: CGFloat = 820
    /// The rounded card casts a deliberately broad shadow.  The transparent
    /// window canvas must be larger than that blur, otherwise WindowServer
    /// clips the remaining shadow at the rectangular window boundary.  That
    /// clipped tail is visible as a pale gray box on white slides.
    static let shadowInset: CGFloat = 64
    /// Preserve the card's visual distance from the bottom of the screen even
    /// though the transparent shadow canvas is now larger.
    static let cardBottomInset: CGFloat = 96

    static var windowBottomInset: CGFloat {
        max(16, cardBottomInset - shadowInset)
    }

    static func cardWidth(for screen: NSScreen?) -> CGFloat {
        let availableWidth = screen?.visibleFrame.width ?? 1024
        let screenSafeWidth = max(minimumCardWidth, availableWidth - 32)
        let proportionalWidth = availableWidth * 0.64
        return min(
            maximumCardWidth,
            max(minimumCardWidth, min(screenSafeWidth, proportionalWidth))
        )
    }

    static func panelSize(cardWidth: CGFloat, state: NoteOverlayState) -> NSSize {
        NSSize(
            width: cardWidth + shadowInset * 2,
            height: state.cardHeight + shadowInset * 2
        )
    }
}

private struct FloatingHUDBackground: View {
    let opacity: Double
    let cornerRadius: CGFloat
    let isHovered: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let density = min(
            1,
            max(
                0,
                (opacity - FloatingInputAppearanceSettings.minimumOpacity)
                    / (FloatingInputAppearanceSettings.maximumOpacity
                        - FloatingInputAppearanceSettings.minimumOpacity)
            )
        )
        let glassTintOpacity = 0.15 + density * 0.10 + (isHovered ? 0.01 : 0)
        let surfaceTintOpacity = 0.06 + density * 0.08 + (isHovered ? 0.008 : 0)

        ZStack {
            if #available(macOS 26.0, *) {
                // Use the system's clear Liquid Glass as the actual surface.
                // The previous regular glass + thin material + 56% black fill
                // flattened refraction into an opaque gray slab and doubled
                // the system edge with a hand-drawn outline.
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .glassEffect(
                        .clear.tint(Color.black.opacity(glassTintOpacity)),
                        in: shape
                    )
            } else {
                shape.fill(.ultraThinMaterial)
            }

            // A restrained dark wash keeps white notes readable while leaving
            // enough of the video/slide visible for real refraction and depth.
            shape.fill(Color.black.opacity(surfaceTintOpacity))

            // Environmental light lives inside the glass instead of drawing a
            // full perimeter stroke. This removes the uniform gray rim while
            // keeping the upper-left reflection characteristic of Liquid Glass.
            shape.fill(
                LinearGradient(
                    colors: [
                        Color.white.opacity(isHovered ? 0.095 : 0.075),
                        Color.white.opacity(0.022),
                        Color.clear,
                        Color.black.opacity(0.055)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
    }
}

extension View {
    /// Native Liquid Glass on current systems with a restrained material fallback.
    @ViewBuilder
    func vnGlass<S: InsettableShape>(
        in shape: S,
        tint: Color? = nil,
        interactive: Bool = false,
        edgeHighlightOpacity: Double = 1.0
    ) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular.tint(tint).interactive(interactive), in: shape)
            .overlay {
                // Native Liquid Glass already supplies the blur and refraction;
                // this restrained highlight keeps the edge readable over both
                // dark video and bright desktop content.
                shape.strokeBorder(
                    LinearGradient(
                        colors: [
                            .white.opacity(0.22 * edgeHighlightOpacity),
                            .white.opacity(0.09 * edgeHighlightOpacity),
                            .white.opacity(0.025 * edgeHighlightOpacity),
                            .black.opacity(0.07 * edgeHighlightOpacity)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.65
                )
            }
        } else {
            self
                .background(.ultraThinMaterial, in: shape)
                .overlay {
                    shape.strokeBorder(
                        LinearGradient(
                            colors: [
                                .white.opacity(0.22 * edgeHighlightOpacity),
                                .white.opacity(0.09 * edgeHighlightOpacity),
                                .white.opacity(0.025 * edgeHighlightOpacity),
                                .black.opacity(0.07 * edgeHighlightOpacity)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.75
                    )
                }
        }
    }

    func vnCard<S: InsettableShape>(in shape: S) -> some View {
        self
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.72), in: shape)
            .overlay(shape.strokeBorder(.primary.opacity(0.07), lineWidth: 0.75))
            .shadow(color: .black.opacity(0.035), radius: 10, y: 4)
    }
}

struct VNShortcutKey: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(VNStyle.inputSecondaryText)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.white.opacity(0.13), in: RoundedRectangle(cornerRadius: 6))
            .accessibilityHidden(true)
    }
}

// MARK: - Emotion easter egg

/// A deliberately small, local-only hint of emotion in the current note.
/// Matching the last emotion word makes the response follow the sentence the
/// user is currently finishing (for example, “先紧张，后来很开心” feels happy).
enum InputEmotion: String, CaseIterable, Identifiable {
    case joy
    case sadness
    case anger
    case anxiety
    case tiredness
    case affection
    case surprise
    case calm

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .joy: return Color(red: 1.00, green: 0.82, blue: 0.18)
        case .sadness: return Color(red: 0.15, green: 0.78, blue: 1.00)
        case .anger: return Color(red: 1.00, green: 0.24, blue: 0.38)
        case .anxiety: return Color(red: 0.73, green: 0.38, blue: 1.00)
        case .tiredness: return Color(red: 0.44, green: 0.55, blue: 1.00)
        case .affection: return Color(red: 1.00, green: 0.20, blue: 0.72)
        case .surprise: return Color(red: 0.10, green: 1.00, blue: 0.89)
        case .calm: return Color(red: 0.20, green: 1.00, blue: 0.56)
        }
    }

    /// Two hand-authored 7×7 frames. They are rendered as hard-edged squares,
    /// so this stays true pixel art on every display instead of a pixel font.
    var pixelFrames: [[String]] {
        switch self {
        case .joy:
            return [
                [".#####.", "#.....#", "#.#.#.#", "#.....#", "#.#.#.#", "#..#..#", ".#####."],
                [".#####.", "#.....#", "#.....#", "#.....#", "#.#.#.#", "#..#..#", ".#####."]
            ]
        case .sadness:
            return [
                [".#####.", "#.....#", "#.#.#.#", "#.....#", "#..#..#", "#.#.#.#", ".#####."],
                [".#####.", "#.....#", "#.#.#.#", "#.....#", "#..#..#", "#.#.#.#", ".#####."]
            ]
        case .anger:
            return [
                [".#####.", "##...##", "#.#.#.#", "#.....#", "#..#..#", "#.###.#", ".#####."],
                [".#####.", "#.#.#.#", "##...##", "#.....#", "#..#..#", "#.###.#", ".#####."]
            ]
        case .anxiety:
            return [
                [".#####.", "#.....#", "#.#.#.#", "#.....#", "#.#.#.#", "##.#.##", ".#####."],
                [".#####.", "#.....#", "#.#.#.#", "#.....#", "##.#.##", "#.#.#.#", ".#####."]
            ]
        case .tiredness:
            return [
                [".#####.", "#.....#", "#.###.#", "#.....#", "#..##.#", "#.##..#", ".#####."],
                [".#####.", "#.....#", "#.....#", "#.....#", "#..##.#", "#.##..#", ".#####."]
            ]
        case .affection:
            return [
                [".#...#.", "###.###", "#######", "#######", ".#####.", "..###..", "...#..."],
                [".......", ".#...#.", "###.###", ".#####.", "..###..", "...#...", "......."]
            ]
        case .surprise:
            return [
                [".#####.", "#.....#", "#.#.#.#", "#.....#", "#..#..#", "#..#..#", ".#####."],
                [".#####.", "#.#.#.#", "#.....#", "#.....#", "#..#..#", "#..#..#", ".#####."]
            ]
        case .calm:
            return [
                ["...#...", "..###..", ".#####.", "#######", ".#####.", "..###..", "...#..."],
                ["....#..", "...###.", "..#####", ".######", "..####.", "...##..", "......."]
            ]
        }
    }

    private var keywords: [String] {
        switch self {
        case .joy:
            return ["开心", "高兴", "快乐", "愉快", "幸福", "激动", "happy", "delighted", "excited", "joyful"]
        case .sadness:
            return ["不开心", "不高兴", "不快乐", "难过", "伤心", "悲伤", "失落", "沮丧", "想哭", "sad", "unhappy", "heartbroken"]
        case .anger:
            return ["生气", "愤怒", "恼火", "火大", "气死", "angry", "furious", "annoyed"]
        case .anxiety:
            return ["焦虑", "紧张", "担心", "忐忑", "不安", "压力大", "anxious", "nervous", "worried", "stressed"]
        case .tiredness:
            return ["累了", "好累", "疲惫", "困了", "没精神", "tired", "exhausted", "sleepy"]
        case .affection:
            return ["喜欢", "爱你", "可爱", "心动", "想你", "love", "lovely", "adore"]
        case .surprise:
            return ["惊讶", "惊喜", "震惊", "居然", "没想到", "wow", "surprised", "amazed"]
        case .calm:
            return ["平静", "放松", "安心", "治愈", "舒服", "calm", "peaceful", "relaxed"]
        }
    }

    static func detect(in text: String) -> InputEmotion? {
        let normalized = text.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        var latestMatch: (emotion: InputEmotion, endPosition: Int, length: Int)?

        for emotion in allCases {
            for keyword in emotion.keywords {
                guard let range = latestRange(of: keyword, in: normalized) else { continue }

                let candidate = (
                    emotion: emotion,
                    endPosition: normalized.distance(from: normalized.startIndex, to: range.upperBound),
                    length: keyword.count
                )

                if latestMatch == nil
                    || candidate.endPosition > latestMatch!.endPosition
                    || (candidate.endPosition == latestMatch!.endPosition && candidate.length > latestMatch!.length) {
                    latestMatch = candidate
                }
            }
        }

        return latestMatch?.emotion
    }

    /// English emotion words require word boundaries, so ordinary words such
    /// as “glove” and “saddle” do not accidentally trigger love or sad.
    private static func latestRange(of keyword: String, in text: String) -> Range<String.Index>? {
        let isEnglishWord = keyword.unicodeScalars.allSatisfy {
            $0.isASCII && CharacterSet.letters.contains($0)
        }
        var searchEnd = text.endIndex

        while searchEnd > text.startIndex,
              let range = text.range(
                of: keyword,
                options: .backwards,
                range: text.startIndex..<searchEnd
              ) {
            if !isEnglishWord || hasWordBoundaries(range, in: text) {
                return range
            }
            searchEnd = range.lowerBound
        }

        return nil
    }

    private static func hasWordBoundaries(_ range: Range<String.Index>, in text: String) -> Bool {
        let startsWord = range.lowerBound == text.startIndex
            || !isEnglishWordCharacter(text[text.index(before: range.lowerBound)])
        let endsWord = range.upperBound == text.endIndex
            || !isEnglishWordCharacter(text[range.upperBound])
        return startsWord && endsWord
    }

    private static func isEnglishWordCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_")
        }
    }
}

struct EmotionEasterEggView: View {
    let emotion: InputEmotion

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.11, paused: reduceMotion)) { timeline in
            let tick = reduceMotion
                ? 0
                : Int(timeline.date.timeIntervalSinceReferenceDate * 8)

            Canvas(rendersAsynchronously: false) { context, size in
                drawCyberSprite(in: &context, size: size, tick: tick)
            }
        }
        .frame(width: 34, height: 22)
        .accessibilityHidden(true)
    }

    private func drawCyberSprite(
        in context: inout GraphicsContext,
        size: CGSize,
        tick: Int
    ) {
        let cyan = Color(red: 0.08, green: 0.95, blue: 1.00)
        let magenta = Color(red: 1.00, green: 0.12, blue: 0.75)

        let shell = pixelShell(in: size)
        context.fill(shell, with: .color(Color.black.opacity(0.76)))
        context.stroke(shell, with: .color(cyan.opacity(0.42)), lineWidth: 0.8)

        // Sparse CRT scanlines and a stepped scanner keep the effect crisp,
        // never turning the tiny footer ornament into a bright distraction.
        for y in stride(from: 3.0, to: size.height - 2, by: 4.0) {
            context.fill(
                Path(CGRect(x: 2, y: y, width: size.width - 4, height: 0.5)),
                with: .color(Color.white.opacity(0.055))
            )
        }

        if !reduceMotion {
            let scanY = CGFloat((tick * 2) % max(1, Int(size.height - 4))) + 2
            context.fill(
                Path(CGRect(x: 2, y: scanY, width: size.width - 4, height: 1)),
                with: .color(cyan.opacity(0.13))
            )
        }

        // Deliberately asymmetric border fragments give the tiny display its
        // neon terminal silhouette.
        context.fill(Path(CGRect(x: 3, y: 1, width: 7, height: 1)), with: .color(magenta.opacity(0.8)))
        context.fill(Path(CGRect(x: size.width - 8, y: size.height - 2, width: 5, height: 1)), with: .color(cyan.opacity(0.85)))

        let frameIndex = reduceMotion ? 0 : (tick / 4) % emotion.pixelFrames.count
        let sprite = emotion.pixelFrames[frameIndex]
        let cell: CGFloat = 2
        let spriteWidth = CGFloat(sprite.first?.count ?? 7) * cell
        let spriteHeight = CGFloat(sprite.count) * cell
        var origin = CGPoint(
            x: (size.width - spriteWidth) / 2,
            y: (size.height - spriteHeight) / 2
        )

        if !reduceMotion {
            switch emotion {
            case .joy, .calm: origin.y += (tick / 3).isMultiple(of: 2) ? -1 : 0
            case .anger, .anxiety: origin.x += tick.isMultiple(of: 2) ? -1 : 1
            case .sadness: origin.y += (tick / 5).isMultiple(of: 2) ? 0 : 1
            case .tiredness: origin.x += (tick / 7).isMultiple(of: 2) ? 0 : 1
            case .affection, .surprise: break
            }
        }

        let isGlitchFrame = !reduceMotion && tick % 17 == 0
        let glitchOffset: CGFloat = isGlitchFrame ? 2 : 0

        drawPixels(sprite, in: &context, origin: CGPoint(x: origin.x - 1, y: origin.y), cell: cell, color: magenta.opacity(0.34))
        drawPixels(sprite, in: &context, origin: CGPoint(x: origin.x + 1 + glitchOffset, y: origin.y), cell: cell, color: cyan.opacity(0.34))

        context.addFilter(.shadow(color: emotion.color.opacity(0.68), radius: 2))
        drawPixels(sprite, in: &context, origin: origin, cell: cell, color: emotion.color.opacity(0.96))
        drawEmotionParticles(in: &context, size: size, tick: tick, cyan: cyan, magenta: magenta)
    }

    private func drawPixels(
        _ rows: [String],
        in context: inout GraphicsContext,
        origin: CGPoint,
        cell: CGFloat,
        color: Color
    ) {
        for (rowIndex, row) in rows.enumerated() {
            for (columnIndex, pixel) in row.enumerated() where pixel == "#" {
                let rect = CGRect(
                    x: origin.x + CGFloat(columnIndex) * cell,
                    y: origin.y + CGFloat(rowIndex) * cell,
                    width: cell,
                    height: cell
                )
                context.fill(Path(rect), with: .color(color))
            }
        }
    }

    private func drawEmotionParticles(
        in context: inout GraphicsContext,
        size: CGSize,
        tick: Int,
        cyan: Color,
        magenta: Color
    ) {
        guard !reduceMotion else { return }

        let phase = tick % 4
        switch emotion {
        case .joy, .surprise:
            context.fill(Path(CGRect(x: 4 + CGFloat(phase), y: 4, width: 1.5, height: 1.5)), with: .color(cyan.opacity(0.9)))
            context.fill(Path(CGRect(x: size.width - 6, y: 14 - CGFloat(phase), width: 1.5, height: 1.5)), with: .color(magenta.opacity(0.9)))
        case .sadness:
            context.fill(Path(CGRect(x: 6, y: 7 + CGFloat(phase * 2), width: 1, height: 3)), with: .color(cyan.opacity(0.82)))
            context.fill(Path(CGRect(x: size.width - 7, y: 5 + CGFloat(((phase + 2) % 4) * 2), width: 1, height: 3)), with: .color(cyan.opacity(0.68)))
        case .anger:
            context.fill(Path(CGRect(x: 3, y: 6 + CGFloat(phase), width: 3, height: 1)), with: .color(magenta.opacity(0.88)))
            context.fill(Path(CGRect(x: size.width - 6, y: 13 - CGFloat(phase), width: 3, height: 1)), with: .color(emotion.color.opacity(0.9)))
        case .anxiety:
            context.fill(Path(CGRect(x: 3 + CGFloat(phase), y: 4, width: 1, height: 4)), with: .color(magenta.opacity(0.78)))
            context.fill(Path(CGRect(x: size.width - 5 - CGFloat(phase), y: 14, width: 1, height: 4)), with: .color(cyan.opacity(0.78)))
        case .tiredness:
            let alpha = 0.35 + Double(phase) * 0.13
            context.fill(Path(CGRect(x: size.width - 8, y: 3, width: 2, height: 1)), with: .color(cyan.opacity(alpha)))
            context.fill(Path(CGRect(x: size.width - 6, y: 2, width: 2, height: 1)), with: .color(cyan.opacity(alpha)))
        case .affection:
            context.fill(Path(CGRect(x: 4, y: 5 + CGFloat(phase), width: 1.5, height: 1.5)), with: .color(magenta.opacity(0.92)))
        case .calm:
            context.fill(Path(CGRect(x: 4 + CGFloat(phase), y: size.height - 5, width: 3, height: 1)), with: .color(cyan.opacity(0.64)))
        }
    }

    private func pixelShell(in size: CGSize) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 3, y: 0.5))
        path.addLine(to: CGPoint(x: size.width - 3, y: 0.5))
        path.addLine(to: CGPoint(x: size.width - 0.5, y: 3))
        path.addLine(to: CGPoint(x: size.width - 0.5, y: size.height - 3))
        path.addLine(to: CGPoint(x: size.width - 3, y: size.height - 0.5))
        path.addLine(to: CGPoint(x: 3, y: size.height - 0.5))
        path.addLine(to: CGPoint(x: 0.5, y: size.height - 3))
        path.addLine(to: CGPoint(x: 0.5, y: 3))
        path.closeSubpath()
        return path
    }
}

// MARK: - Typing-responsive rainbow edge

/// A restrained conic glow inspired by the blue–violet–magenta edge light of
/// the reference image. Typing cadence controls its base intensity and
/// breathing speed; user preferences tune the brightness and motion globally.
@MainActor
final class TypingPulse: ObservableObject {
    @Published private(set) var isActive = false

    private var lastInputAt: Date?
    /// Chinese/Japanese/Korean input methods can keep marked text alive while
    /// the user pauses. That pause is not the same as stopping the editor:
    /// the candidate session is still active and the typing glow should stay
    /// alive until the composition is committed or cancelled.
    private var isComposing = false
    private var speedMultiplier = FloatingInputAppearanceSettings.defaultGlowSpeed
    private var fadeTask: Task<Void, Never>?
    private var interactionID = 0
    private var intensityRamp = ScalarRamp(value: 0)
    private var breathPhase = PhaseTrack(rate: 1 / 1.55)
    private var colorRotation = PhaseTrack(rate: 10)

    func recordInput() {
        let now = Date()
        let interval = lastInputAt.map { now.timeIntervalSince($0) } ?? 0.42
        lastInputAt = now

        // Convert cadence to a stable 0…1 energy signal. Exponential smoothing
        // prevents a single paste or accidental double key from causing a flash.
        let frequency = 1.0 / max(0.055, min(interval, 1.2))
        let cadence = min(1, max(0, (frequency - 0.8) / 8.2))
        let target = 0.24 + cadence * 0.76

        let smoothedTarget = intensity(at: now) * 0.38 + target * 0.62
        intensityRamp.retarget(to: smoothedTarget, at: now, duration: 0.22)
        breathPhase.retarget(
            to: breathingRate(for: smoothedTarget),
            at: now,
            duration: 0.34
        )
        colorRotation.retarget(
            to: rotationRate(for: smoothedTarget),
            at: now,
            duration: 0.34
        )

        if !isActive {
            isActive = true
        }
        if !isComposing {
            scheduleFade()
        }
    }

    /// Changes animation speed without jumping the current phase. The
    /// intensity/brightness setting is rendered by the border view, while
    /// this multiplier only affects breathing and color movement.
    func setSpeedMultiplier(_ speed: Double) {
        let normalizedSpeed = min(
            FloatingInputAppearanceSettings.maximumGlowSpeed,
            max(FloatingInputAppearanceSettings.minimumGlowSpeed, speed)
        )
        guard abs(speedMultiplier - normalizedSpeed) > 0.001 else { return }

        let now = Date()
        speedMultiplier = normalizedSpeed
        let currentIntensity = intensity(at: now)
        breathPhase.retarget(
            to: breathingRate(for: currentIntensity),
            at: now,
            duration: 0.24
        )
        colorRotation.retarget(
            to: rotationRate(for: currentIntensity),
            at: now,
            duration: 0.24
        )
    }

    /// Keeps the glow alive for the entire native input-method composition.
    /// A marked-text session can remain open without producing any new
    /// textDidChange notifications, so the ordinary idle timer must not fade
    /// the border while this flag is true.
    func setCompositionActive(_ active: Bool) {
        guard isComposing != active else {
            if active {
                cancelScheduledFade()
            }
            return
        }

        isComposing = active

        if active {
            cancelScheduledFade()
            if !isActive {
                isActive = true
            }
        } else if isActive {
            // Start the normal idle countdown from the moment composition
            // ends, even if the user paused inside the candidate session.
            scheduleFade()
        }
    }

    func intensity(at date: Date) -> Double {
        intensityRamp.value(at: date)
    }

    func breathingPhase(at date: Date) -> Double {
        breathPhase.phase(at: date)
    }

    func colorRotation(at date: Date) -> Double {
        colorRotation.phase(at: date)
    }

    private func scheduleFade() {
        guard !isComposing else { return }

        fadeTask?.cancel()
        interactionID &+= 1
        let currentID = interactionID

        fadeTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 1_650_000_000)
            } catch {
                return
            }

            guard !Task.isCancelled,
                  let self,
                  self.interactionID == currentID,
                  !self.isComposing else { return }

            self.beginFade(at: Date())

            do {
                try await Task.sleep(nanoseconds: 520_000_000)
            } catch {
                return
            }

            guard !Task.isCancelled,
                  self.interactionID == currentID,
                  !self.isComposing else { return }
            self.isActive = false
        }
    }

    private func cancelScheduledFade() {
        fadeTask?.cancel()
        fadeTask = nil
        interactionID &+= 1
    }

    private func beginFade(at now: Date) {
        intensityRamp.retarget(to: 0, at: now, duration: 0.48)
        breathPhase.retarget(to: breathingRate(for: 0), at: now, duration: 0.48)
        colorRotation.retarget(to: rotationRate(for: 0), at: now, duration: 0.48)
    }

    private func breathingRate(for intensity: Double) -> Double {
        (1 / (1.55 - intensity * 0.93)) * speedMultiplier
    }

    private func rotationRate(for intensity: Double) -> Double {
        (10 + intensity * 18) * speedMultiplier
    }

    /// A scalar that changes value without a discontinuity. TimelineView reads
    /// the curve directly instead of restarting a SwiftUI animation per key.
    private struct ScalarRamp {
        private var startValue: Double
        private var targetValue: Double
        private var startedAt: Date
        private var duration: TimeInterval

        init(value: Double) {
            startValue = value
            targetValue = value
            startedAt = Date()
            duration = 0
        }

        mutating func retarget(to value: Double, at date: Date, duration: TimeInterval) {
            startValue = self.value(at: date)
            targetValue = value
            startedAt = date
            self.duration = duration
        }

        func value(at date: Date) -> Double {
            guard duration > 0 else { return targetValue }
            let progress = min(1, max(0, date.timeIntervalSince(startedAt) / duration))
            let eased = progress * progress * (3 - 2 * progress)
            return startValue + (targetValue - startValue) * eased
        }
    }

    /// Keeps the animation phase continuous when typing changes its velocity.
    /// That prevents the rainbow and breath from jumping to their first frame.
    private struct PhaseTrack {
        private var phaseAtStart: Double = 0
        private var rateAtStart: Double
        private var targetRate: Double
        private var startedAt = Date()
        private var duration: TimeInterval = 0

        init(rate: Double) {
            rateAtStart = rate
            targetRate = rate
        }

        mutating func retarget(to rate: Double, at date: Date, duration: TimeInterval) {
            phaseAtStart = phase(at: date)
            rateAtStart = self.rate(at: date)
            targetRate = rate
            startedAt = date
            self.duration = duration
        }

        func phase(at date: Date) -> Double {
            let elapsed = max(0, date.timeIntervalSince(startedAt))
            guard duration > 0 else { return phaseAtStart + targetRate * elapsed }

            let difference = targetRate - rateAtStart
            if elapsed <= duration {
                let progress = elapsed / duration
                // Integral of smoothstep(t): t³ − ½t⁴.
                let smoothstepIntegral = progress * progress * progress
                    - 0.5 * progress * progress * progress * progress
                return phaseAtStart
                    + rateAtStart * elapsed
                    + difference * duration * smoothstepIntegral
            }

            let rampDistance = duration * (rateAtStart + targetRate) / 2
            return phaseAtStart + rampDistance + targetRate * (elapsed - duration)
        }

        private func rate(at date: Date) -> Double {
            guard duration > 0 else { return targetRate }
            let progress = min(1, max(0, date.timeIntervalSince(startedAt) / duration))
            let eased = progress * progress * (3 - 2 * progress)
            return rateAtStart + (targetRate - rateAtStart) * eased
        }
    }

    deinit {
        fadeTask?.cancel()
    }
}

@MainActor
struct TypingRainbowBorder: View {
    @ObservedObject var pulse: TypingPulse
    let brightness: Double
    let cornerRadius: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let colors: [Color] = [
        Color(red: 0.18, green: 0.92, blue: 1.00),
        Color(red: 0.24, green: 0.46, blue: 1.00),
        Color(red: 0.48, green: 0.28, blue: 1.00),
        Color(red: 0.93, green: 0.25, blue: 0.94),
        Color(red: 1.00, green: 0.31, blue: 0.66),
        Color(red: 0.31, green: 0.70, blue: 1.00),
        Color(red: 0.18, green: 0.92, blue: 1.00)
    ]

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        TimelineView(
            .animation(
                minimumInterval: 1.0 / 30.0,
                paused: !pulse.isActive || reduceMotion
            )
        ) { timeline in
            let intensity = pulse.intensity(at: timeline.date)
            let values = animationValues(at: timeline.date)
            let opacity = pulse.isActive
                ? min(1, (0.46 + intensity * 0.54) * brightness)
                : 0
            let gradient = AngularGradient(
                colors: colors,
                center: .center,
                startAngle: .degrees(values.rotation),
                endAngle: .degrees(values.rotation + 360)
            )

            ZStack {
                // Broad atmospheric halo, kept outside the content so text
                // contrast is untouched even at the fastest typing cadence.
                shape
                    .stroke(gradient, lineWidth: 3.2 + intensity * 2.2)
                    .blur(radius: 5.5 + values.breath * 2.5)
                    .opacity(opacity * (0.24 + values.breath * 0.30))

                // The crisp rainbow filament seen along the phone bezel.
                shape
                    .stroke(
                        gradient,
                        lineWidth: 0.9 + intensity * 0.9
                    )
                    .opacity(opacity * (0.56 + values.breath * 0.36))

                // A fine cool inner reflection keeps the result glassy rather
                // than looking like a generic neon gaming border.
                shape
                    .inset(by: 1.8)
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.34),
                                Color.cyan.opacity(0.12),
                                Color.purple.opacity(0.24),
                                Color.clear
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.55
                    )
                    .opacity(opacity * (0.40 + values.breath * 0.24))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func animationValues(at date: Date) -> (breath: Double, rotation: Double) {
        guard !reduceMotion else { return (0.52, 214) }

        let breath = 0.5 + sin(pulse.breathingPhase(at: date) * 2 * Double.pi) * 0.5
        let rotation = pulse.colorRotation(at: date)
            .truncatingRemainder(dividingBy: 360)
        return (breath, rotation)
    }
}

// MARK: - InputViewModel

final class InputViewModel: ObservableObject {
    static let characterLimit = 2_000

    @Published var text: String = ""
    @Published var showCopiedToast: Bool = false
    @Published var attachedScreenshotPath: String?
    @Published private(set) var overlayState: NoteOverlayState = .collapsed
    @Published private(set) var capturedVideoContext: MediaCaptureContext?
    @Published private(set) var savedTimestamp: String?
    @Published private(set) var cardWidth: CGFloat = FloatingInputLayout.defaultCardWidth
    /// 截图时锁定的视频上下文；保存时优先使用它，保证文字输入耗时不会改变截图时间点。
    var attachedVideoContext: MediaCaptureContext?

    var onPasteImage: ((NSImage) -> Void)?
    /// Changes only when the editor is explicitly reset for a new note.
    ///
    /// SwiftUI refreshes this view for the video timer, rainbow border and
    /// emotion animation. Those refreshes must never push the (temporarily
    /// stale) binding back into NSTextView while an input method owns marked
    /// text. A separate revision makes an intentional model-to-editor write
    /// distinguishable from an ordinary decorative refresh.
    @Published private(set) var editorResetRevision: UInt64 = 0

    var onCommit: ((String) -> Void)?
    var onDismiss: (() -> Void)?

    var remainingCharacters: Int {
        max(0, Self.characterLimit - text.count)
    }

    func commit() { onCommit?(text) }
    func dismiss() { onDismiss?() }

    func setCardWidth(_ width: CGFloat) {
        guard width.isFinite else { return }
        cardWidth = min(
            FloatingInputLayout.maximumCardWidth,
            max(FloatingInputLayout.minimumCardWidth, width)
        )
    }

    func prepareForPresentation(
        capturedVideoContext: MediaCaptureContext?,
        cardWidth: CGFloat
    ) {
        text = ""
        showCopiedToast = false
        attachedScreenshotPath = nil
        attachedVideoContext = nil
        savedTimestamp = nil
        self.capturedVideoContext = capturedVideoContext
        setCardWidth(cardWidth)
        editorResetRevision &+= 1
        withAnimation(.easeInOut(duration: 0.19)) {
            overlayState = .writing
        }
    }

    func beginWriting(capturedVideoContext: MediaCaptureContext?) {
        text = ""
        showCopiedToast = false
        attachedScreenshotPath = nil
        attachedVideoContext = nil
        savedTimestamp = nil
        self.capturedVideoContext = capturedVideoContext
        editorResetRevision &+= 1
        withAnimation(.easeInOut(duration: 0.19)) {
            overlayState = .writing
        }
    }

    func toggleExpanded() {
        withAnimation(.easeInOut(duration: 0.19)) {
            overlayState = overlayState == .expanded ? .writing : .expanded
        }
    }

    func showToast(timestamp: String) {
        savedTimestamp = timestamp
        withAnimation(.snappy(duration: 0.24)) {
            showCopiedToast = true
            overlayState = .saved
        }
    }

    func removeAttachedScreenshot() {
        attachedScreenshotPath = nil
        attachedVideoContext = nil
    }

    func attachPastedImage(_ image: NSImage) {
        NSLog("[VNPasteDiag] step5: InputViewModel.attachPastedImage called, onPasteImageIsNil=\(onPasteImage == nil)")
        onPasteImage?(image)
    }

    func reset() {
        text = ""
        showCopiedToast = false
        removeAttachedScreenshot()
        savedTimestamp = nil
        capturedVideoContext = nil
        overlayState = .collapsed
        editorResetRevision &+= 1
    }
}

// MARK: - Attached Screenshot Thumbnail

/// 输入框内的小缩略图：表示截图已附加，可移除。不撑满输入框。
private struct AttachedScreenshotThumbnail: View {
    let path: String
    let width: CGFloat
    let height: CGFloat
    let onRemove: () -> Void

    private var image: NSImage? {
        NSImage(contentsOfFile: path)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Rectangle()
                        .fill(Color.primary.opacity(0.06))
                        .overlay {
                            Image(systemName: "photo")
                                .font(.system(size: 14, weight: .light))
                                .foregroundStyle(.secondary)
                        }
                }
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(.primary.opacity(0.10), lineWidth: 0.75)
            }

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white, .black.opacity(0.55))
            }
            .buttonStyle(.plain)
            .padding(3)
            .help("移除截图")
            .accessibilityLabel("移除截图")
        }
        .frame(width: width, height: height)
        .help("已附加截图")
    }
}

// MARK: - FloatingInputView

struct FloatingInputView: View {
    @ObservedObject var viewModel: InputViewModel
    @ObservedObject private var videoSessionManager = VideoSessionManager.shared
    @AppStorage(FloatingInputAppearanceSettings.opacityKey)
    private var inputBoxOpacity = FloatingInputAppearanceSettings.defaultOpacity
    @AppStorage(FloatingInputAppearanceSettings.glowBrightnessKey)
    private var glowBrightness = FloatingInputAppearanceSettings.defaultGlowBrightness
    @AppStorage(FloatingInputAppearanceSettings.glowSpeedKey)
    private var glowSpeed = FloatingInputAppearanceSettings.defaultGlowSpeed

    // The animation state is intentionally separate from the editable text
    // hierarchy. Editing therefore never rebuilds the AppKit text view just to
    // update the decorative border, which keeps IME composition stable.
    @StateObject private var typingPulse = TypingPulse()
    @State private var isHovered = false

    private var detectedEmotion: InputEmotion? {
        InputEmotion.detect(in: viewModel.text)
    }

    private var shouldShowCharacterCount: Bool {
        viewModel.remainingCharacters <= 160
    }

    private var canSave: Bool {
        !viewModel.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || viewModel.attachedScreenshotPath != nil
    }

    var body: some View {
        Group {
            switch viewModel.overlayState {
            case .collapsed:
                collapsedView
            case .writing:
                editorView(isExpanded: false)
            case .expanded:
                editorView(isExpanded: true)
            case .saved:
                savedView
            }
        }
        .frame(width: viewModel.cardWidth, height: viewModel.overlayState.cardHeight)
        .background {
            FloatingHUDBackground(
                opacity: inputBoxOpacity,
                cornerRadius: viewModel.overlayState.cornerRadius,
                isHovered: isHovered
            )
        }
        .clipShape(
            RoundedRectangle(
                cornerRadius: viewModel.overlayState.cornerRadius,
                style: .continuous
            )
        )
        .overlay {
            TypingRainbowBorder(
                pulse: typingPulse,
                brightness: glowBrightness,
                cornerRadius: viewModel.overlayState.cornerRadius
            )
        }
        .shadow(color: .black.opacity(0.20), radius: 28, y: 10)
        .padding(FloatingInputLayout.shadowInset)
        .frame(
            width: FloatingInputLayout.panelSize(
                cardWidth: viewModel.cardWidth,
                state: viewModel.overlayState
            ).width,
            height: FloatingInputLayout.panelSize(
                cardWidth: viewModel.cardWidth,
                state: viewModel.overlayState
            ).height
        )
        .animation(.easeInOut(duration: 0.19), value: viewModel.overlayState)
        .animation(.easeInOut(duration: 0.19), value: detectedEmotion)
        .onHover { isHovered = $0 }
        .onChange(of: viewModel.showCopiedToast) { isShowingToast in
            guard isShowingToast else { return }
            let defaults = UserDefaults.standard
            defaults.set(defaults.integer(forKey: "VideoNotes.savedNoteCount") + 1, forKey: "VideoNotes.savedNoteCount")
        }
        .onChange(of: viewModel.attachedScreenshotPath) { newValue in
            NSLog("[VNPasteDiag] step8: FloatingInputView onChange attachedScreenshotPath=\(newValue ?? "nil")")
        }
        .onAppear {
            typingPulse.setSpeedMultiplier(glowSpeed)
        }
        .onChange(of: glowSpeed) { newSpeed in
            typingPulse.setSpeedMultiplier(newSpeed)
        }
    }

    // MARK: - Collapsed / saved states

    private var collapsedView: some View {
        HStack(spacing: 10) {
            VideoSessionIndicator(
                sessionManager: videoSessionManager,
                capturedContext: nil,
                compact: true,
                onTimestampTap: copyTimestamp
            )
            .fixedSize(horizontal: true, vertical: false)

            Button(action: beginWritingFromCollapsed) {
                HStack(spacing: 8) {
                    Text("写下此刻的重点…")
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(VNStyle.hudPlaceholderText)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer(minLength: 4)

                    VNShortcutKey(text: "⌘⇧Space")
                }
            }
            .buttonStyle(.plain)
            .help("快速记笔记 · ⌘⇧Space")
            .accessibilityLabel("写下此刻的重点")
            .accessibilityHint("按下后自动聚焦输入框")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var savedView: some View {
        HStack(spacing: 9) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.green.opacity(0.92))

            Text("已记录 \(viewModel.savedTimestamp ?? "--:--")")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(VNStyle.hudPrimaryText)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("已记录 \(viewModel.savedTimestamp ?? "未知时间")")
    }

    // MARK: - Writing / expanded states

    private func editorView(isExpanded: Bool) -> some View {
        VStack(alignment: .leading, spacing: isExpanded ? 12 : 11) {
            HStack(alignment: .center, spacing: 8) {
                VideoSessionIndicator(
                    sessionManager: videoSessionManager,
                    capturedContext: viewModel.capturedVideoContext,
                    compact: false,
                    onTimestampTap: copyTimestamp
                )
                .layoutPriority(1)

                Spacer(minLength: 3)

                Button {
                    viewModel.toggleExpanded()
                } label: {
                    Image(systemName: isExpanded
                        ? "arrow.down.right.and.arrow.up.left"
                        : "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(VNStyle.hudSupportingText)
                        .frame(width: 26, height: 25)
                }
                .buttonStyle(.plain)
                .help(isExpanded ? "收起笔记编辑器" : "展开长笔记")
                .accessibilityLabel(isExpanded ? "收起笔记编辑器" : "展开长笔记")

                saveButton
            }
            .frame(height: 26)

            HStack(alignment: .top, spacing: 8) {
                if let path = viewModel.attachedScreenshotPath {
                    AttachedScreenshotThumbnail(
                        path: path,
                        width: isExpanded ? 84 : 60,
                        height: isExpanded ? 52 : 40
                    ) {
                        viewModel.removeAttachedScreenshot()
                    }
                }

                InputTextView(
                    text: $viewModel.text,
                    resetRevision: viewModel.editorResetRevision,
                    characterLimit: InputViewModel.characterLimit,
                    onCommit: { viewModel.commit() },
                    onDismiss: { viewModel.dismiss() },
                    onUserEdit: { typingPulse.recordInput() },
                    onCompositionStateChanged: { isComposing in
                        typingPulse.setCompositionActive(isComposing)
                    },
                    onPasteImage: { image in viewModel.attachPastedImage(image) }
                )
                .frame(maxWidth: .infinity)
                .frame(height: isExpanded ? 194 : 49)
                .accessibilityLabel("笔记内容")
                .accessibilityHint("按回车保存，按 Shift 加回车换行，按 Escape 收起")
            }

            HStack(spacing: 7) {
                Text("↵ 保存     ⇧↵ 换行     Esc 收起")
                    .lineLimit(1)

                Spacer(minLength: 4)

                if let detectedEmotion {
                    EmotionEasterEggView(emotion: detectedEmotion)
                        .id(detectedEmotion)
                        .transition(.scale(scale: 0.72).combined(with: .opacity))
                }

                if shouldShowCharacterCount {
                    Text("还可输入 \(viewModel.remainingCharacters) 字")
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
            .frame(height: 16)
            .font(.system(size: 11.5, weight: .regular, design: .rounded))
            .foregroundStyle(Color.white.opacity(0.48))
            .shadow(color: .black.opacity(0.42), radius: 1.5, y: 1)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, isExpanded ? 18 : 14)
    }

    private var saveButton: some View {
        Button {
            viewModel.commit()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                Text("保存")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(canSave ? Color.white : Color.white.opacity(0.48))
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background {
                ZStack {
                    Capsule()
                        .fill(Color.white.opacity(canSave ? 0.095 : 0.055))

                    if #available(macOS 26.0, *) {
                        Color.clear.vnGlass(
                            in: Capsule(),
                            tint: canSave
                                ? VNStyle.accent.opacity(isHovered ? 0.16 : 0.09)
                                : Color.white.opacity(0.025),
                            interactive: true,
                            edgeHighlightOpacity: 0.54
                        )
                    } else {
                        Capsule()
                            .fill(.thinMaterial)
                            .opacity(0.45)
                    }
                }
            }
            .overlay {
                Capsule()
                    .strokeBorder(
                        canSave
                            ? VNStyle.accent.opacity(isHovered ? 0.30 : 0.16)
                            : Color.white.opacity(0.08),
                        lineWidth: 0.65
                    )
            }
        }
        .buttonStyle(.plain)
        .disabled(!canSave)
        .help("保存笔记 · 回车")
        .accessibilityLabel("保存笔记")
        .accessibilityHint("回车")
    }

    private func beginWritingFromCollapsed() {
        let context = viewModel.capturedVideoContext
            ?? MediaCaptureResolver.context(at: Date())
        viewModel.beginWriting(capturedVideoContext: context)
    }

    private func copyTimestamp(_ timestamp: String) {
        guard timestamp != "--:--" else { return }
        ClipboardManager.shared.copy(text: timestamp)
        ClipToastWindow.show(message: "已复制时间点 \(timestamp)")
    }
}

// MARK: - InputTextView

struct InputTextView: NSViewRepresentable {
    @Binding var text: String
    let resetRevision: UInt64
    let characterLimit: Int
    let onCommit: () -> Void
    let onDismiss: () -> Void
    let onUserEdit: () -> Void
    let onCompositionStateChanged: (Bool) -> Void
    let onPasteImage: (NSImage) -> Void

    func makeNSView(context: Context) -> InputEditorScrollView {
        let textView = InputNSTextView()
        textView.delegate = context.coordinator
        textView.onCommit = onCommit
        textView.onDismiss = onDismiss
        textView.onCompositionStateChanged = onCompositionStateChanged
        textView.onPasteImage = onPasteImage
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainerInset = .zero
        textView.maxHeight = 56
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.setAccessibilityLabel("笔记内容")
        textView.string = text
        textView.setSelectedRange(NSRange(location: text.utf16.count, length: 0))
        // The editor is placed over arbitrary video frames. Liquid Glass and
        // the typography treatment keep the glyphs bright and stable instead
        // of inheriting a low-contrast label color.
        textView.applyReadableTypography()
        context.coordinator.appliedResetRevision = resetRevision

        // FloatingInputPanel owns first-responder assignment. Keeping one
        // authority avoids an asynchronous focus race during panel retries.
        return InputEditorScrollView(editor: textView)
    }

    func updateNSView(_ nsView: InputEditorScrollView, context: Context) {
        let textView = nsView.editor
        textView.onCommit = onCommit
        textView.onDismiss = onDismiss
        textView.onCompositionStateChanged = onCompositionStateChanged
        textView.onPasteImage = onPasteImage
        context.coordinator.onUserEdit = onUserEdit
        context.coordinator.onCompositionStateChanged = onCompositionStateChanged
        context.coordinator.characterLimit = characterLimit

        // Never use an ordinary SwiftUI update as a reason to rewrite the
        // native editor. During IME composition the binding intentionally
        // contains only committed text, so comparing the two strings is not a
        // valid synchronization signal. Only an explicit reset revision may
        // flow from the model back into NSTextView.
        guard context.coordinator.appliedResetRevision != resetRevision else {
            return
        }

        context.coordinator.appliedResetRevision = resetRevision
        textView.inputContext?.discardMarkedText()
        textView.onCompositionStateChanged?(false)
        textView.string = text
        textView.setSelectedRange(NSRange(location: text.utf16.count, length: 0))
        textView.applyReadableTypography()
        textView.undoManager?.removeAllActions()
        textView.needsDisplay = true
        nsView.resizeEditor()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            onUserEdit: onUserEdit,
            onCompositionStateChanged: onCompositionStateChanged,
            characterLimit: characterLimit,
            appliedResetRevision: resetRevision
        )
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        var onUserEdit: () -> Void
        var onCompositionStateChanged: (Bool) -> Void
        var characterLimit: Int
        var appliedResetRevision: UInt64

        init(
            text: Binding<String>,
            onUserEdit: @escaping () -> Void,
            onCompositionStateChanged: @escaping (Bool) -> Void,
            characterLimit: Int,
            appliedResetRevision: UInt64
        ) {
            self._text = text
            self.onUserEdit = onUserEdit
            self.onCompositionStateChanged = onCompositionStateChanged
            self.characterLimit = characterLimit
            self.appliedResetRevision = appliedResetRevision
        }

        func textView(
            _ textView: NSTextView,
            shouldChangeTextIn affectedCharRange: NSRange,
            replacementString: String?
        ) -> Bool {
            guard let replacementString else { return true }

            // Marked text belongs to the input method. It is validated after
            // the candidate is committed so the character limit never breaks
            // an active Chinese/Japanese/Korean composition session.
            guard !textView.hasMarkedText() else { return true }

            let current = textView.string as NSString
            guard affectedCharRange.location <= current.length,
                  NSMaxRange(affectedCharRange) <= current.length else {
                return false
            }

            let candidate = current.replacingCharacters(
                in: affectedCharRange,
                with: replacementString
            )
            return candidate.count <= characterLimit
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let isComposing = textView.hasMarkedText()
            onCompositionStateChanged(isComposing)

            // Some IMEs send provisional change notifications. The binding
            // should contain committed text only; the final commit produces a
            // normal change notification after marked text is cleared.
            guard !isComposing else {
                onUserEdit()
                textView.needsDisplay = true
                return
            }

            // A composition can temporarily exceed the limit because marked
            // text is deliberately left untouched above. Trim only after the
            // input method has committed it, when replacing the native string
            // can no longer cancel a candidate window.
            let committedText: String
            if textView.string.count > characterLimit {
                committedText = String(textView.string.prefix(characterLimit))
                textView.string = committedText
                textView.setSelectedRange(
                    NSRange(location: committedText.utf16.count, length: 0)
                )
                if let inputTextView = textView as? InputNSTextView {
                    inputTextView.applyReadableTypography()
                }
            } else {
                committedText = textView.string
            }

            text = committedText
            onUserEdit()
            textView.needsDisplay = true
        }
    }
}

/// The editor is kept native for reliable IME behavior, while the scroll view
/// gives the expanded state a real viewport instead of clipping long notes.
final class InputEditorScrollView: NSScrollView {
    let editor: InputNSTextView

    init(editor: InputNSTextView) {
        self.editor = editor
        super.init(frame: .zero)

        drawsBackground = false
        backgroundColor = .clear
        borderType = .noBorder
        hasHorizontalScroller = false
        hasVerticalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        verticalScrollElasticity = .automatic
        horizontalScrollElasticity = .none

        editor.frame = NSRect(x: 0, y: 0, width: 300, height: 40)
        editor.autoresizingMask = [.width]
        documentView = editor

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(editorDidChange),
            name: NSText.didChangeNotification,
            object: editor
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func layout() {
        super.layout()
        resizeEditor()
    }

    @objc private func editorDidChange() {
        resizeEditor()
    }

    func resizeEditor() {
        let viewportWidth = contentView.bounds.width
        let viewportHeight = contentView.bounds.height
        guard viewportWidth > 1, viewportHeight > 1 else { return }

        editor.frame.size.width = viewportWidth
        if let textContainer = editor.textContainer,
           let layoutManager = editor.layoutManager {
            textContainer.containerSize = NSSize(
                width: viewportWidth,
                height: CGFloat.greatestFiniteMagnitude
            )
            layoutManager.ensureLayout(for: textContainer)
            let usedHeight = ceil(layoutManager.usedRect(for: textContainer).height) + 8
            editor.frame.size.height = max(viewportHeight, usedHeight)
        } else {
            editor.frame.size.height = viewportHeight
        }
    }
}

final class InputNSTextView: NSTextView {
    var onCommit: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onCompositionStateChanged: ((Bool) -> Void)?
    var onPasteImage: ((NSImage) -> Void)?
    var maxHeight: CGFloat = 56

    static let readableFont = NSFont.systemFont(ofSize: 17, weight: .medium)

    /// Applies the same high-contrast typography to normal text, text entered
    /// next, and text restored after a reset. The subtle negative stroke adds
    /// a crisp edge while the shadow separates white glyphs from bright video.
    func applyReadableTypography() {
        let attributes = readableTextAttributes()
        font = Self.readableFont
        textColor = NSColor.white
        typingAttributes = attributes

        var markedAttributes = attributes
        markedAttributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        markedTextAttributes = markedAttributes

        let textLength = (string as NSString).length
        if textLength > 0 {
            textStorage?.addAttributes(
                attributes,
                range: NSRange(location: 0, length: textLength)
            )
        }
        needsDisplay = true
    }

    private func readableTextAttributes() -> [NSAttributedString.Key: Any] {
        [
            .font: Self.readableFont,
            .foregroundColor: NSColor.white,
            .shadow: readableTextShadow(),
            .strokeColor: NSColor.black.withAlphaComponent(0.34),
            .strokeWidth: -0.45
        ]
    }

    private func readableTextShadow() -> NSShadow {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.72)
        shadow.shadowBlurRadius = 1.8
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        return shadow
    }

    private func publishCompositionState() {
        onCompositionStateChanged?(hasMarkedText())
    }

    override func setMarkedText(
        _ string: Any,
        selectedRange: NSRange,
        replacementRange: NSRange
    ) {
        // Publish before and after AppKit updates the marked range. The first
        // notification protects the glow even if this IME pauses without
        // emitting another textDidChange event; the second captures an IME
        // implementation that immediately commits an empty/finished mark.
        onCompositionStateChanged?(true)
        super.setMarkedText(
            string,
            selectedRange: selectedRange,
            replacementRange: replacementRange
        )
        publishCompositionState()
    }

    override func unmarkText() {
        super.unmarkText()
        publishCompositionState()
    }

    override func keyDown(with event: NSEvent) {
        NSLog("[VNPasteDiag] step1: keyDown keyCode=\(event.keyCode) modifiers=\(event.modifierFlags.rawValue) selfType=\(String(describing: type(of: self))) windowFirstResponderType=\(window?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil") isSelfFirstResponder=\(window?.firstResponder === self)")
        // 修复：NSTextView 默认的 key binding 在这类 NSPanel 中不会把 ⌘V
        // 转换为 paste(_:)，这里显式处理，确保粘贴图片/文本都能到达 paste。
        if event.keyCode == 9 && event.modifierFlags.contains(.command) && !event.modifierFlags.contains(.shift) {
            NSLog("[VNPasteDiag] step1b: keyDown routes Cmd+V to paste explicitly")
            paste(nil)
            return
        }
        if event.keyCode == 53 {
            // Escape first belongs to an active IME candidate session. Closing
            // the whole panel here would discard both the candidate and draft.
            guard !hasMarkedText() else {
                super.keyDown(with: event)
                return
            }
            onDismiss?()
            return
        }
        if event.keyCode == 36 || event.keyCode == 76 {
            // Return is how Chinese/Japanese/Korean input methods confirm a
            // marked candidate. Let AppKit handle that composition before
            // treating an unmodified Return as the note's Save shortcut.
            guard !hasMarkedText() else {
                super.keyDown(with: event)
                return
            }

            // Shift+Return remains the explicit multiline escape hatch.
            // AppKit's native text insertion preserves undo, selection and
            // IME behavior, so do not synthesize a newline ourselves.
            if event.modifierFlags.contains(.shift) {
                super.keyDown(with: event)
                return
            }

            onCommit?()
            return
        }
        super.keyDown(with: event)
    }

    override func paste(_ sender: Any?) {
        // 剪贴板里有图片时，把图片作为截图附件保存，而不是把图片塞进纯文本编辑器。
        let pasteboard = NSPasteboard.general
        NSLog("[VNPasteDiag] step2: paste entered selfType=\(String(describing: type(of: self))) firstResponderIsSelf=\(window?.firstResponder === self)")
        NSLog("[VNPasteDiag] step3: paste types=\(pasteboard.types?.map(\.rawValue) ?? [])")

        // AI may offer rendered HTML together with TeX plain text. Prefer
        // readable text when present, retaining native selection and undo.
        if pasteboard.availableType(from: [.fileURL]) == nil,
           let text = ClipboardInputText.read(from: pasteboard), !text.isEmpty {
            // Keep TeX intact for actual formula rendering when saving/copying.
            insertText(text, replacementRange: selectedRange())
            return
        }

        if let image = pasteboard.readObjects(
            forClasses: [NSImage.self],
            options: nil
        )?.first as? NSImage {
            NSLog("[VNPasteDiag] step4: readObjects got image=\(image.size.width)x\(image.size.height)")
            onPasteImage?(image)
            return
        }

        // 复制的是图片文件（例如在访达里复制了 PNG）时，也作为截图附件保存。
        if let url = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: nil
        )?.first as? URL,
           let image = NSImage(contentsOf: url) {
            NSLog("[VNPasteDiag] step4b: readObjects got file image: \(url.path)")
            onPasteImage?(image)
            return
        }

        NSLog("[VNPasteDiag] step4fail: no image from pasteboard, calling super.paste")
        super.paste(sender)
    }

    override func cancelOperation(_ sender: Any?) {
        if hasMarkedText() {
            inputContext?.discardMarkedText()
            return
        }
        onDismiss?()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty else { return }
        NSAttributedString(
            string: "写下此刻的重点…",
            attributes: [
                .foregroundColor: NSColor.white.withAlphaComponent(0.76),
                .font: Self.readableFont,
                .shadow: readableTextShadow(),
                .strokeColor: NSColor.black.withAlphaComponent(0.32),
                .strokeWidth: -0.40
            ]
        ).draw(in: bounds)
    }

    override var acceptsFirstResponder: Bool { true }
}
