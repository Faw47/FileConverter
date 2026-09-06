import AppKit
import SwiftUI

// MARK: - Squircle Icon Badge (Apple System Settings & Tahoe Style)

public struct SettingsIconBadge: View {
    public enum Size {
        case sidebar
        case header
        case tool
        case custom(CGFloat, CGFloat)

        var frameSize: CGFloat {
            switch self {
            case .sidebar: return 24
            case .header: return 40
            case .tool: return 32
            case .custom(let s, _): return s
            }
        }

        var iconSize: CGFloat {
            switch self {
            case .sidebar: return 12
            case .header: return 19
            case .tool: return 15
            case .custom(_, let i): return i
            }
        }

        var cornerRadius: CGFloat {
            switch self {
            case .sidebar: return 6.5
            case .header: return 10
            case .tool: return 8
            case .custom(let s, _): return s * 0.25
            }
        }
    }

    let systemImage: String
    let color: Color
    var size: Size = .sidebar

    public init(systemImage: String, color: Color, size: Size = .sidebar) {
        self.systemImage = systemImage
        self.color = color
        self.size = size
    }

    public var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size.cornerRadius, style: .continuous)
                .fill(color.opacity(0.14))
                .overlay {
                    RoundedRectangle(cornerRadius: size.cornerRadius, style: .continuous)
                        .stroke(color.opacity(0.24), lineWidth: 0.75)
                }

            Image(systemName: systemImage)
                .font(.system(size: size.iconSize, weight: .semibold))
                .foregroundStyle(color)
        }
        .frame(width: size.frameSize, height: size.frameSize)
    }
}

// MARK: - Section Header

public struct SettingsSectionHeader: View {
    let title: String
    var accessory: String? = nil

    public init(_ title: String, accessory: String? = nil) {
        self.title = title
        self.accessory = accessory
    }

    public var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            Spacer()

            if let accessory {
                Text(accessory)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 4)
    }
}

// MARK: - Liquid Glass Container & Card (macOS 26 Tahoe Compliant)

public struct LiquidGlassContainer<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: Content

    public init(spacing: CGFloat = 16, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    public var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

public struct SettingsCard<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 0.75)
        )
    }
}

// MARK: - Standard Settings Row

public struct SettingsRow<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    var icon: String? = nil
    var iconColor: Color? = nil
    @ViewBuilder let trailing: Trailing

    public init(
        title: String,
        subtitle: String? = nil,
        icon: String? = nil,
        iconColor: Color? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.iconColor = iconColor
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(iconColor ?? .secondary)
                    .frame(width: 20, alignment: .center)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(.primary)

                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 16)

            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

extension SettingsRow where Trailing == EmptyView {
    public init(
        title: String,
        subtitle: String? = nil,
        icon: String? = nil,
        iconColor: Color? = nil
    ) {
        self.init(title: title, subtitle: subtitle, icon: icon, iconColor: iconColor) {
            EmptyView()
        }
    }
}

// MARK: - Status Badge

public struct StatusBadge: View {
    public enum Style {
        case success
        case warning
        case error
        case neutral

        var color: Color {
            switch self {
            case .success: return .green
            case .warning: return .orange
            case .error: return .red
            case .neutral: return .secondary
            }
        }

        var defaultIcon: String {
            switch self {
            case .success: return "checkmark.circle.fill"
            case .warning: return "exclamationmark.circle.fill"
            case .error: return "xmark.circle.fill"
            case .neutral: return "minus.circle.fill"
            }
        }
    }

    let text: String
    var icon: String? = nil
    var style: Style = .neutral

    public init(_ text: String, icon: String? = nil, style: Style = .neutral) {
        self.text = text
        self.icon = icon
        self.style = style
    }

    public var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon ?? style.defaultIcon)
                .font(.system(size: 10, weight: .semibold))
            Text(text)
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(style.color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(style.color.opacity(0.14))
        )
        .overlay(
            Capsule()
                .stroke(style.color.opacity(0.25), lineWidth: 0.75)
        )
    }
}

// MARK: - Token Pill (Click to Insert)

public struct TokenPill: View {
    let token: String
    let description: String
    let onInsert: () -> Void

    @State private var isHovered = false

    public init(token: String, description: String, onInsert: @escaping () -> Void) {
        self.token = token
        self.description = description
        self.onInsert = onInsert
    }

    public var body: some View {
        Button(action: onInsert) {
            HStack(spacing: 4) {
                Text(token)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.accentColor)

                Image(systemName: "plus")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.accentColor.opacity(0.7))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(isHovered ? Color.accentColor.opacity(0.2) : Color.accentColor.opacity(0.09))
            )
            .overlay(
                Capsule()
                    .stroke(Color.accentColor.opacity(isHovered ? 0.45 : 0.2), lineWidth: 0.75)
            )
        }
        .buttonStyle(.plain)
        .help("Insert \(token) (\(description))")
        .onHover { isHovered = $0 }
    }
}

// MARK: - Copyable Command Field

public struct CopyableCommandField: View {
    let command: String
    @State private var isCopied = false
    @State private var resetTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(command: String) {
        self.command = command
    }

    public var body: some View {
        HStack(spacing: 8) {
            Text(command)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)

            Spacer(minLength: 4)

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                resetTask?.cancel()
                if reduceMotion {
                    isCopied = true
                } else {
                    withAnimation(.easeOut(duration: 0.15)) { isCopied = true }
                }
                resetTask = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled else { return }
                    if reduceMotion { isCopied = false }
                    else { withAnimation(.easeOut(duration: 0.15)) { isCopied = false } }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10, weight: .semibold))
                    Text(isCopied ? "Copied!" : "Copy")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(isCopied ? Color.green : Color.primary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isCopied ? Color.green.opacity(0.14) : Color.secondary.opacity(0.1))
                )
            }
            .buttonStyle(.plain)
            .help("Copy command to clipboard")
            .accessibilityLabel(isCopied ? "Copied command" : "Copy command")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.4))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.3), lineWidth: 0.5)
        )
    }
}

// MARK: - macOS 26 Liquid Glass Button Helpers

extension View {
    @ViewBuilder
    public func glassActionProminent(tint: Color = .accentColor) -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glassProminent)
                .tint(tint)
        } else {
            self.buttonStyle(.borderedProminent)
                .tint(tint)
        }
    }

    @ViewBuilder
    public func glassAction() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glass)
                .tint(.accentColor)
                .foregroundStyle(.primary)
        } else {
            self.buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    public func glassActionDestructive() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glass)
                .tint(.red)
                .foregroundStyle(.red)
        } else {
            self.buttonStyle(.bordered)
                .tint(.red)
        }
    }

    @ViewBuilder
    public func applySliderThumbVisibility() -> some View {
        if #available(macOS 26.0, *) {
            self.sliderThumbVisibility(.visible)
        } else {
            self
        }
    }
}
