import Cocoa
import SwiftUI

// MARK: - Neon Colors

private let neonCyan    = Color(red: 0, green: 0.94, blue: 1)
private let neonMagenta = Color(red: 1, green: 0, blue: 0.9)
private let neonPurple  = Color(red: 0.48, green: 0.18, blue: 1)
private let neonGreen   = Color(red: 0, green: 1, blue: 0.53)
private let bgDark      = Color(red: 0.04, green: 0.04, blue: 0.08)

// MARK: - Panel

final class OverlayPanel: NSPanel {
    convenience init() {
        self.init(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 400),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    func positionCenter() {
        guard let screen = NSScreen.main else { return }
        let area = screen.visibleFrame
        // Panel covers a big region, always centered; SwiftUI content centers itself inside
        let w: CGFloat = 700
        let h: CGFloat = 400
        let x = area.midX - w / 2
        let y = area.midY - h / 2
        setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
    }
}

// MARK: - ViewModel

final class OverlayViewModel: ObservableObject {
    @Published var stage: PipelineStage = .idle
    @Published var asrText = ""
    @Published var gptText = ""
    @Published var isTranslation = false

    @Published var smoothedLevel: CGFloat = 0

    var onCancel: (() -> Void)?
    var onConfirm: (() -> Void)?

    private var targetLevel: CGFloat = 0
    private var timer: Timer?

    func pushLevel(_ level: Float) {
        // Just store target; smoothing happens on timer
        targetLevel = CGFloat(level)
    }

    func startSmoothing() {
        timer?.invalidate()
        // 60 fps smoothing loop
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.targetLevel > self.smoothedLevel {
                self.smoothedLevel += (self.targetLevel - self.smoothedLevel) * 0.40
            } else {
                self.smoothedLevel += (self.targetLevel - self.smoothedLevel) * 0.15
            }
        }
    }

    func stopSmoothing() {
        timer?.invalidate()
        timer = nil
        smoothedLevel = 0
        targetLevel = 0
    }
}

// MARK: - Root

struct OverlayRootView: View {
    @ObservedObject var vm: OverlayViewModel

    var body: some View {
        Group {
            switch vm.stage {
            case .recording:
                RecordingHUD(
                    level: vm.smoothedLevel,
                    onCancel: vm.onCancel,
                    onConfirm: vm.onConfirm
                )
            case .recognizing:
                CyberTextCard(accent: neonCyan, label: "TRANSCRIBING", text: vm.asrText)
            case .translating:
                CyberTextCard(accent: neonMagenta, label: "TRANSLATING", text: vm.gptText)
            case .done:
                CyberDoneCard(text: vm.gptText.isEmpty ? vm.asrText : vm.gptText)
            case .error:
                CyberInfoCard(label: "ERROR", accent: Color(red: 1, green: 0.2, blue: 0.2))
            default:
                EmptyView()
            }
        }
        .animation(.easeInOut(duration: 0.2), value: vm.stage)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Cyber Card Chrome

struct CyberCard<Content: View>: View {
    var accent: Color = neonCyan
    @ViewBuilder let content: Content
    @State private var borderPhase: CGFloat = 0

    var body: some View {
        content
            .padding(24)
            .frame(maxWidth: 560)
            .background {
                ZStack {
                    // Deep dark bg
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(bgDark)

                    // Subtle grid / scan lines
                    ScanLines()
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                    // Animated neon border
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(
                            AngularGradient(
                                colors: [accent, accent.opacity(0.1), neonPurple.opacity(0.4), accent],
                                center: .center,
                                angle: .degrees(borderPhase)
                            ),
                            lineWidth: 1.5
                        )

                    // Corner brackets
                    CornerBrackets(color: accent)
                        .padding(4)
                }
                .shadow(color: accent.opacity(0.3), radius: 20, y: 0)
            }
            .onAppear {
                withAnimation(.linear(duration: 4).repeatForever(autoreverses: false)) {
                    borderPhase = 360
                }
            }
    }
}

struct ScanLines: View {
    var body: some View {
        Canvas { ctx, size in
            for y in stride(from: 0, to: size.height, by: 3) {
                let rect = CGRect(x: 0, y: y, width: size.width, height: 1)
                ctx.fill(Path(rect), with: .color(.white.opacity(0.015)))
            }
        }
    }
}

struct CornerBrackets: View {
    let color: Color
    private let len: CGFloat = 14
    private let thick: CGFloat = 1.5

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            // Top-left
            bracket(at: CGPoint(x: 0, y: 0), dx: 1, dy: 1)
            // Top-right
            bracket(at: CGPoint(x: w, y: 0), dx: -1, dy: 1)
            // Bottom-left
            bracket(at: CGPoint(x: 0, y: h), dx: 1, dy: -1)
            // Bottom-right
            bracket(at: CGPoint(x: w, y: h), dx: -1, dy: -1)
        }
    }

    @ViewBuilder
    func bracket(at origin: CGPoint, dx: CGFloat, dy: CGFloat) -> some View {
        Path { p in
            p.move(to: CGPoint(x: origin.x + dx * len, y: origin.y))
            p.addLine(to: origin)
            p.addLine(to: CGPoint(x: origin.x, y: origin.y + dy * len))
        }
        .stroke(color.opacity(0.6), lineWidth: thick)
    }
}

// MARK: - 1. Recording HUD

struct RecordingHUD: View {
    let level: CGFloat
    var onCancel: (() -> Void)?
    var onConfirm: (() -> Void)?

    private let count = 12
    /// Bell-curve weights: center high, sides low
    private let weights: [CGFloat] = {
        (0..<12).map { i in
            let x = (CGFloat(i) - 5.5) / 3.0
            return 0.35 + 0.65 * exp(-x * x)
        }
    }()
    private let barWidth: CGFloat = 4
    private let barSpacing: CGFloat = 3.5
    private let minH: CGFloat = 5
    private let maxH: CGFloat = 28

    var body: some View {
        HStack(spacing: 18) {
            // Cancel
            Button(action: { onCancel?() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(neonCyan.opacity(0.6))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(neonCyan.opacity(0.08)))
                    .overlay(Circle().stroke(neonCyan.opacity(0.2), lineWidth: 0.5))
            }
            .buttonStyle(.plain)

            // 5-bar waveform
            TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                HStack(alignment: .center, spacing: barSpacing) {
                    ForEach(0..<count, id: \.self) { i in
                        let h = barH(i, t)
                        RoundedRectangle(cornerRadius: barWidth / 2)
                            .fill(neonCyan)
                            .shadow(color: neonCyan.opacity(0.5), radius: 3)
                            .frame(width: barWidth, height: h)
                            .animation(
                                .interpolatingSpring(stiffness: 280, damping: 12),
                                value: h
                            )
                    }
                }
                .frame(height: 32)
            }

            // Confirm
            Button(action: { onConfirm?() }) {
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(neonGreen)
                    .shadow(color: neonGreen.opacity(0.5), radius: 3)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(neonGreen.opacity(0.1)))
                    .overlay(Circle().stroke(neonGreen.opacity(0.25), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(bgDark)
                ScanLines().clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(neonCyan.opacity(0.3), lineWidth: 1)
                CornerBrackets(color: neonCyan).padding(5)
            }
            .shadow(color: neonCyan.opacity(0.15), radius: 16)
        }
    }

    private func barH(_ i: Int, _ t: Double) -> CGFloat {
        let w = weights[i]
        // ±4% jitter per bar (different phase per bar)
        let jitter = 1.0 + sin(t * 11.0 + Double(i) * 2.7) * 0.04
        let h = minH + level * w * CGFloat(jitter) * (maxH - minH)
        return max(minH, h)
    }
}

// MARK: - 2. Text Card

struct CyberTextCard: View {
    let accent: Color
    let label: String
    let text: String
    @State private var dotPhase = 0
    @State private var timer: Timer?

    var body: some View {
        CyberCard(accent: accent) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    SpinArc(color: accent)
                        .frame(width: 14, height: 14)

                    Text(label)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(accent)
                        .shadow(color: accent.opacity(0.6), radius: 3)

                    HStack(spacing: 3) {
                        ForEach(0..<3, id: \.self) { i in
                            Circle()
                                .fill(accent.opacity(i < dotPhase ? 0.9 : 0.15))
                                .frame(width: 4, height: 4)
                                .shadow(color: accent.opacity(i < dotPhase ? 0.5 : 0), radius: 2)
                                .animation(.easeInOut(duration: 0.15), value: dotPhase)
                        }
                    }
                }

                if text.isEmpty {
                    CyberShimmer(color: accent)
                } else {
                    Text(text)
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.9))
                        .shadow(color: accent.opacity(0.15), radius: 2)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .onAppear { startDots() }
        .onDisappear { timer?.invalidate(); timer = nil }
    }

    private func startDots() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { _ in
            DispatchQueue.main.async { dotPhase = (dotPhase + 1) % 4 }
        }
    }
}

struct SpinArc: View {
    let color: Color
    @State private var rot: Double = 0
    var body: some View {
        Circle()
            .trim(from: 0, to: 0.25)
            .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .shadow(color: color, radius: 3)
            .rotationEffect(.degrees(rot))
            .onAppear {
                withAnimation(.linear(duration: 0.7).repeatForever(autoreverses: false)) {
                    rot = 360
                }
            }
    }
}

struct CyberShimmer: View {
    let color: Color
    @State private var phase: CGFloat = -0.5

    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(color.opacity(0.05))
            .frame(height: 14)
            .frame(maxWidth: 200)
            .overlay(
                GeometryReader { geo in
                    Capsule()
                        .fill(color.opacity(0.2))
                        .frame(width: geo.size.width * 0.3)
                        .blur(radius: 6)
                        .offset(x: phase * geo.size.width)
                }
            )
            .clipped()
            .onAppear {
                withAnimation(.linear(duration: 1.0).repeatForever(autoreverses: false)) {
                    phase = 1.5
                }
            }
    }
}

// MARK: - 3. Done

struct CyberDoneCard: View {
    let text: String
    @State private var scale: CGFloat = 0.3
    @State private var glow = false

    var body: some View {
        CyberCard(accent: neonGreen) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundStyle(neonGreen)
                    .shadow(color: neonGreen.opacity(glow ? 0.8 : 0.3), radius: glow ? 8 : 3)
                    .scaleEffect(scale)

                Text(text.isEmpty ? "DONE" : text)
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.5)) { scale = 1.0 }
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { glow = true }
        }
    }
}

// MARK: - 4. Info

struct CyberInfoCard: View {
    let label: String
    let accent: Color

    var body: some View {
        CyberCard(accent: accent) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(accent)
                    .shadow(color: accent, radius: 4)
                Text(label)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(accent)
            }
            .frame(maxWidth: .infinity)
        }
    }
}
