import AppKit
import OllamaKit
import SwiftUI

// MARK: - Model kind

/// Visual category of a model, used for its icon and tint.
enum ModelKind {
    case text
    case vision
    case embedding
    case image
    case cloud

    init(_ model: OllamaModel) {
        if model.isCloud {
            self = .cloud
        } else if model.supports(.image) {
            self = .image
        } else if model.supports(.embedding) {
            self = .embedding
        } else if model.supports(.vision) {
            self = .vision
        } else {
            self = .text
        }
    }

    var systemImage: String {
        switch self {
        case .text: "text.bubble.fill"
        case .vision: "eye.fill"
        case .embedding: "point.3.connected.trianglepath.dotted"
        case .image: "photo.fill"
        case .cloud: "cloud.fill"
        }
    }

    var tint: Color {
        switch self {
        case .text: .blue
        case .vision: .purple
        case .embedding: .orange
        case .image: .pink
        case .cloud: .teal
        }
    }
}

struct ModelIcon: View {
    let kind: ModelKind
    var size: CGFloat = 22

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(kind.tint.gradient)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: kind.systemImage)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}

// MARK: - Badges

struct Badge: View {
    let text: Text
    var tint: Color = .secondary

    init(_ text: Text, tint: Color = .secondary) {
        self.text = text
        self.tint = tint
    }

    init(verbatim string: String, tint: Color = .secondary) {
        self.text = Text(verbatim: string)
        self.tint = tint
    }

    var body: some View {
        text
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(tint)
            .background(tint.opacity(0.14), in: Capsule())
    }
}

/// Localized label and tint for a capability reported by Ollama or ollama.com.
enum CapabilityStyle {
    static func title(_ capability: String) -> Text {
        switch capability.lowercased() {
        case "completion": Text("Text")
        case "vision": Text("Vision")
        case "tools": Text("Tools")
        case "thinking": Text("Thinking")
        case "embedding": Text("Embedding")
        case "image": Text("Image")
        case "audio": Text("Audio")
        case "insert": Text("Insert")
        case "cloud": Text("Cloud")
        default: Text(verbatim: capability.capitalized)
        }
    }

    static func symbol(_ capability: String) -> String {
        switch capability.lowercased() {
        case "completion": "text.bubble"
        case "vision": "eye"
        case "tools": "wrench.and.screwdriver"
        case "thinking": "brain"
        case "embedding": "point.3.connected.trianglepath.dotted"
        case "image": "photo"
        case "audio": "waveform"
        case "insert": "text.insert"
        case "cloud": "cloud"
        default: "sparkle"
        }
    }

    static func tint(_ capability: String) -> Color {
        switch capability.lowercased() {
        case "completion": .blue
        case "vision": .purple
        case "tools": .orange
        case "thinking": .pink
        case "embedding": .brown
        case "image": .indigo
        case "audio": .green
        case "cloud": .teal
        default: .secondary
        }
    }
}

struct CapabilityBadges: View {
    let capabilities: [String]
    var includeCompletion = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(shown, id: \.self) { capability in
                Badge(CapabilityStyle.title(capability), tint: CapabilityStyle.tint(capability))
            }
        }
    }

    private var shown: [String] {
        capabilities.filter { includeCompletion || $0 != Capability.completion.rawValue }
    }
}

/// Compact capability symbols for table cells, with the name as tooltip.
struct CapabilityIcons: View {
    let capabilities: [String]

    var body: some View {
        HStack(spacing: 5) {
            ForEach(capabilities.filter { $0 != Capability.completion.rawValue }, id: \.self) { capability in
                Image(systemName: CapabilityStyle.symbol(capability))
                    .foregroundStyle(CapabilityStyle.tint(capability))
                    .help(CapabilityStyle.title(capability))
                    .accessibilityLabel(CapabilityStyle.title(capability))
            }
        }
    }
}

// MARK: - Layout

/// Lays out children left to right, wrapping onto new lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

// MARK: - Status

struct StatusDot: View {
    let connection: ConnectionState

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .overlay(Circle().stroke(color.opacity(0.35), lineWidth: 3))
            .accessibilityHidden(true)
    }

    private var color: Color {
        switch connection {
        case .connecting: .orange
        case .connected: .green
        case .unreachable: .red
        }
    }
}

extension ConnectionState {
    var summary: Text {
        switch self {
        case .connecting: Text("Connecting…")
        case .connected(let version): Text("Connected · Ollama \(version)")
        case .unreachable: Text("Not reachable")
        }
    }
}

// MARK: - Text blocks

struct CopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.borderless)
        .help(Text("Copy"))
    }
}

/// Monospaced, selectable, scrollable text with a copy button.
struct CodeBlock: View {
    let text: String
    var maxHeight: CGFloat = 240

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            Text(verbatim: text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .frame(maxHeight: maxHeight)
        .fixedSize(horizontal: false, vertical: true)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(alignment: .topTrailing) {
            CopyButton(text: text)
                .padding(6)
        }
    }
}

/// Small title/value pair used in cards.
struct Metric: View {
    let title: Text
    let value: Text

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            title
                .font(.caption)
                .foregroundStyle(.secondary)
            value
                .font(.callout.weight(.medium))
                .monospacedDigit()
        }
    }
}

// MARK: - Shared states

struct ServerUnavailableView: View {
    private var app: AppModel { .shared }

    var body: some View {
        switch app.connection {
        case .connecting, .connected:
            ProgressView {
                Text("Connecting to \(app.settings.currentServer.name)…")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unreachable(let message):
            ContentUnavailableView {
                Label("Ollama Is Not Reachable", systemImage: "bolt.horizontal.circle")
            } description: {
                VStack(spacing: 6) {
                    Text("Couldn't connect to \(app.settings.currentServer.url.absoluteString).")
                    Text(verbatim: message)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            } actions: {
                HStack {
                    if app.canStartLocalOllama {
                        Button("Start Ollama") { app.startLocalOllama() }
                            .buttonStyle(.borderedProminent)
                    }
                    Button("Try Again") {
                        Task { await app.refresh(forceModels: true) }
                    }
                    SettingsLink {
                        Text("Server Settings…")
                    }
                }
            }
        }
    }
}
