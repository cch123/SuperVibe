import Cocoa
import SwiftUI

// MARK: - Floating Panel

final class OverlayPanel: NSPanel {
    convenience init(size: NSSize = NSSize(width: 400, height: 80)) {
        self.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        ignoresMouseEvents = false
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    func positionCenter() {
        guard let screen = NSScreen.main else { return }
        let x = (screen.frame.width - frame.width) / 2
        let y = screen.frame.height * 0.15
        setFrameOrigin(NSPoint(x: x, y: y))
    }
}

// MARK: - Overlay Content

struct OverlayContentView: View {
    let stage: PipelineStage
    let asrText: String
    let gptText: String
    let isTranslation: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)

            Text(displayText)
                .font(.system(size: 13))
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)

            if isTranslation {
                Text("TR")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.blue)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: 400, alignment: .leading)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var displayText: String {
        if !gptText.isEmpty { return gptText }
        if !asrText.isEmpty { return asrText }
        switch stage {
        case .recording:    return "Listening..."
        case .recognizing:  return "Recognizing..."
        case .polishing:    return "Polishing..."
        case .error:        return "Error"
        default:            return ""
        }
    }

    private var dotColor: Color {
        switch stage {
        case .recording:   return .red
        case .recognizing: return .orange
        case .polishing:   return .blue
        case .done:        return .green
        case .error:       return .red
        default:           return .gray
        }
    }
}
