import SwiftUI
import AppKit

// MARK: - Shared visual language

enum VNStyle {
    static let accent = Color(red: 0.30, green: 0.43, blue: 0.98)
    static let cyan = Color(red: 0.18, green: 0.76, blue: 0.98)
    static let violet = Color(red: 0.56, green: 0.37, blue: 0.96)
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

enum FloatingInputLayout {
    static let cardWidth: CGFloat = 620
    static let shadowInset: CGFloat = 32
    static let panelSize = NSSize(
        width: cardWidth + shadowInset * 2,
        height: 172
    )
}

extension View {
    /// Native Liquid Glass on current systems with a restrained material fallback.
    @ViewBuilder
    func vnGlass<S: InsettableShape>(
        in shape: S,
        tint: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            self
                .background(.ultraThinMaterial, in: shape)
                .overlay {
                    shape.strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.30), .white.opacity(0.06)],
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
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.primary.opacity(0.075), in: RoundedRectangle(cornerRadius: 6))
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
/// the reference image. Typing cadence controls both brightness and breathing
/// speed; once typing stops, the edge quietly dissolves back into the glass.
@MainActor
final class TypingPulse: ObservableObject {
    @Published private(set) var isActive = false

    private var lastInputAt: Date?
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
            to: 1 / (1.55 - smoothedTarget * 0.93),
            at: now,
            duration: 0.34
        )
        colorRotation.retarget(
            to: 10 + smoothedTarget * 18,
            at: now,
            duration: 0.34
        )

        if !isActive {
            isActive = true
        }
        scheduleFade()
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
        fadeTask?.cancel()
        interactionID += 1
        let currentID = interactionID

        fadeTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 1_650_000_000)
            } catch {
                return
            }

            guard !Task.isCancelled,
                  let self,
                  self.interactionID == currentID else { return }

            self.beginFade(at: Date())

            do {
                try await Task.sleep(nanoseconds: 520_000_000)
            } catch {
                return
            }

            guard !Task.isCancelled,
                  self.interactionID == currentID else { return }
            self.isActive = false
        }
    }

    private func beginFade(at now: Date) {
        intensityRamp.retarget(to: 0, at: now, duration: 0.48)
        breathPhase.retarget(to: 1 / 1.55, at: now, duration: 0.48)
        colorRotation.retarget(to: 10, at: now, duration: 0.48)
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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
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
        TimelineView(
            .animation(
                minimumInterval: 1.0 / 30.0,
                paused: !pulse.isActive || reduceMotion
            )
        ) { timeline in
            let intensity = pulse.intensity(at: timeline.date)
            let values = animationValues(at: timeline.date)
            let opacity = pulse.isActive ? 0.46 + intensity * 0.54 : 0
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

    var onCommit: ((String) -> Void)?
    var onDismiss: (() -> Void)?

    var remainingCharacters: Int {
        max(0, Self.characterLimit - text.count)
    }

    func commit() { onCommit?(text) }
    func dismiss() { onDismiss?() }

    func showToast() {
        withAnimation(.snappy(duration: 0.24)) {
            showCopiedToast = true
        }
    }

    func reset() {
        text = ""
        showCopiedToast = false
    }
}

// MARK: - FloatingInputView

struct FloatingInputView: View {
    @ObservedObject var viewModel: InputViewModel

    // The animation state is intentionally separate from the editable text
    // hierarchy. Editing therefore never rebuilds the AppKit text view just to
    // update the decorative border, which keeps IME composition stable.
    @StateObject private var typingPulse = TypingPulse()

    private var detectedEmotion: InputEmotion? {
        InputEmotion.detect(in: viewModel.text)
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .center, spacing: 13) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [VNStyle.accent, VNStyle.cyan],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Image(systemName: "note.text")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 42, height: 42)
                .shadow(color: VNStyle.accent.opacity(0.28), radius: 9, y: 4)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text("快速记一笔")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)

                    InputTextView(
                        text: $viewModel.text,
                        onCommit: { viewModel.commit() },
                        onDismiss: { viewModel.dismiss() },
                        onUserEdit: { typingPulse.recordInput() }
                    )
                    .frame(minHeight: 28, maxHeight: 56)
                    .accessibilityLabel("笔记内容")
                    .accessibilityHint("按回车保存，按 Shift 加回车换行")
                }

                Button {
                    viewModel.commit()
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(viewModel.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.secondary : Color.white)
                        .frame(width: 34, height: 34)
                        .background(
                            viewModel.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? Color.primary.opacity(0.07)
                                : VNStyle.accent,
                            in: Circle()
                        )
                }
                .buttonStyle(.plain)
                .disabled(viewModel.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("保存笔记")
                .accessibilityLabel("保存笔记")
            }

            HStack(spacing: 6) {
                VNShortcutKey(text: "↩")
                Text("保存")
                VNShortcutKey(text: "⇧↩")
                Text("换行")
                VNShortcutKey(text: "esc")
                Text("关闭")

                Spacer(minLength: 12)

                // A fixed slot prevents the counter from jumping when the
                // decorative response appears or changes emotion.
                ZStack {
                    if let detectedEmotion = detectedEmotion {
                        EmotionEasterEggView(emotion: detectedEmotion)
                            .id(detectedEmotion)
                            .transition(.scale(scale: 0.72).combined(with: .opacity))
                    }
                }
                .frame(width: 34, height: 22)

                Text("还可输入 \(viewModel.remainingCharacters) 字")
                    .monospacedDigit()
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.tertiary)
        }
        .animation(.easeInOut(duration: 0.20), value: detectedEmotion)
        .padding(.horizontal, 18)
        .padding(.vertical, 15)
        .frame(width: FloatingInputLayout.cardWidth)
        .vnGlass(in: RoundedRectangle(cornerRadius: 26, style: .continuous), tint: VNStyle.accent.opacity(0.08))
        .overlay {
            TypingRainbowBorder(
                pulse: typingPulse
            )
        }
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
        .overlay(alignment: .topTrailing) {
            if viewModel.showCopiedToast {
                Label("已保存并复制", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .vnGlass(in: Capsule(), tint: .green.opacity(0.12))
                    .padding(10)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        // The transparent NSPanel must include the complete blur footprint.
        // Otherwise macOS clips the shadow at the window bounds and turns the
        // clipped edge into a dark polygon on bright video backgrounds.
        .padding(FloatingInputLayout.shadowInset)
        .frame(
            width: FloatingInputLayout.panelSize.width,
            height: FloatingInputLayout.panelSize.height
        )
        .onChange(of: viewModel.text) { newValue in
            if newValue.count > InputViewModel.characterLimit {
                viewModel.text = String(newValue.prefix(InputViewModel.characterLimit))
                return
            }
        }
    }
}

// MARK: - InputTextView

struct InputTextView: NSViewRepresentable {
    @Binding var text: String
    let onCommit: () -> Void
    let onDismiss: () -> Void
    let onUserEdit: () -> Void

    func makeNSView(context: Context) -> InputNSTextView {
        let textView = InputNSTextView()
        textView.delegate = context.coordinator
        textView.onCommit = onCommit
        textView.onDismiss = onDismiss
        textView.font = .systemFont(ofSize: 17, weight: .regular)
        textView.textColor = .labelColor
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
        textView.setAccessibilityLabel("笔记内容")

        DispatchQueue.main.async {
            textView.window?.makeFirstResponder(textView)
        }
        return textView
    }

    func updateNSView(_ nsView: InputNSTextView, context: Context) {
        nsView.onCommit = onCommit
        nsView.onDismiss = onDismiss
        context.coordinator.onUserEdit = onUserEdit
        if nsView.string != text {
            let selection = nsView.selectedRange()
            nsView.string = text
            nsView.setSelectedRange(NSRange(location: min(selection.location, text.utf16.count), length: 0))
            nsView.needsDisplay = true
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onUserEdit: onUserEdit)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        var onUserEdit: () -> Void

        init(text: Binding<String>, onUserEdit: @escaping () -> Void) {
            self._text = text
            self.onUserEdit = onUserEdit
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text = textView.string
            onUserEdit()
            textView.needsDisplay = true
        }
    }
}

final class InputNSTextView: NSTextView {
    var onCommit: (() -> Void)?
    var onDismiss: (() -> Void)?
    var maxHeight: CGFloat = 56

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onDismiss?()
            return
        }
        if event.keyCode == 36 && !event.modifierFlags.contains(.shift) {
            // Return is how Chinese/Japanese/Korean input methods confirm a
            // marked candidate. Let AppKit handle that composition before
            // treating Return as the note's Save shortcut.
            guard !hasMarkedText() else {
                super.keyDown(with: event)
                return
            }
            onCommit?()
            return
        }
        super.keyDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty else { return }
        NSAttributedString(
            string: "写下此刻的重点…",
            attributes: [
                .foregroundColor: NSColor.placeholderTextColor,
                .font: NSFont.systemFont(ofSize: 17)
            ]
        ).draw(in: bounds)
    }

    override var acceptsFirstResponder: Bool { true }
}
