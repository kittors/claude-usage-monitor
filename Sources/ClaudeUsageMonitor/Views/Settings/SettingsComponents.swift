import AppKit
import SwiftUI

// MARK: - 布局

/// 分组标题
struct SettingsHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Palette.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 22)
            .padding(.bottom, 2)
    }
}

/// 一行设置：左侧标题与说明，右侧控件
struct SettingsRow<Control: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.text)
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.vertical, 11)
    }
}

// MARK: - 控件

/// 胶囊分段选择
struct PillSegmented<Value: Hashable>: View {
    let options: [(value: Value, title: String)]
    @Binding var selection: Value
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { i in
                let option = options[i]
                let selected = option.value == selection
                Text(option.title)
                    .font(.system(size: 12, weight: selected ? .medium : .regular))
                    .foregroundStyle(selected ? Palette.text : Palette.secondary)
                    .padding(.horizontal, 12)
                    .frame(height: 24)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.white.opacity(0.13))
                                .matchedGeometryEffect(id: "pill", in: namespace)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(.quiet) { selection = option.value } }
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.05)))
        // 选项文字不被挤压截断，空间不够时让左边的说明换行
        .fixedSize()
    }
}

/// 下拉选择：自定义外观，弹出原生菜单
struct DropdownButton<Value: Hashable>: View {
    let options: [(value: Value, title: String)]
    @Binding var selection: Value
    @State private var hovering = false

    var body: some View {
        Button(action: showMenu) {
            HStack(spacing: 6) {
                Text(options.first { $0.value == selection }?.title ?? "")
                    .monospacedDigit()
                SVGIcon(.chevronDown, size: 9, lineWidth: 2.2)
                    .foregroundStyle(Palette.tertiary)
            }
            .font(.system(size: 12.5))
            .foregroundStyle(Palette.text)
            .padding(.leading, 10)
            .padding(.trailing, 8)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(hovering ? 0.1 : 0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .onHover { h in withAnimation(.quiet) { hovering = h } }
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.appearance = NSAppearance(named: .darkAqua)
        var current: NSMenuItem?
        for option in options {
            let item = ClosureMenuItem(title: option.title) { selection = option.value }
            if option.value == selection {
                item.state = .on
                current = item
            }
            menu.addItem(item)
        }
        guard let window = NSApp.keyWindow, let view = window.contentView else { return }
        let point = view.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        menu.popUp(positioning: current, at: point, in: view)
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }
}

/// 开关
struct SwitchToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule().fill(isOn ? Palette.accent : Color.white.opacity(0.14))
            Circle()
                .fill(Color.white)
                .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                .padding(2)
        }
        .frame(width: 32, height: 18)
        .contentShape(Capsule())
        .onTapGesture { withAnimation(.quiet) { isOn.toggle() } }
    }
}

/// 代理地址
struct ProxyField: View {
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        FieldChrome(focused: focused) {
            TextField("", text: $text, prompt: Text("127.0.0.1:7890").foregroundStyle(Palette.quaternary))
                .textFieldStyle(.plain)
                .monospaced()
                .focused($focused)
                .frame(width: 168)
        }
    }
}

/// 数值输入：回车或移开焦点时提交。设置可能把数值修正到允许的范围，提交后显示修正后的值。
struct NumberField: View {
    @Binding var value: Double
    var prefix: String?
    var suffix: String?
    var fractionDigits = 0
    var width: CGFloat = 64
    @FocusState private var focused: Bool
    @State private var text = ""

    var body: some View {
        FieldChrome(focused: focused) {
            if let prefix { Text(prefix).foregroundStyle(Palette.tertiary) }
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .focused($focused)
                .frame(width: width)
                .onSubmit(commit)
            if let suffix { Text(suffix).foregroundStyle(Palette.tertiary) }
        }
        .onAppear { text = formatted(value) }
        .onChange(of: value) { _, new in if !focused { text = formatted(new) } }
        .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
    }

    private func commit() {
        if let number = try? Double(text.trimmingCharacters(in: .whitespaces), format: .number) { value = number }
        text = formatted(value)
    }

    private func formatted(_ number: Double) -> String {
        number.formatted(.number.grouping(.never).precision(.fractionLength(fractionDigits)))
    }
}

private struct FieldChrome<Content: View>: View {
    var focused: Bool
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 4) { content }
            .font(.system(size: 12.5))
            .foregroundStyle(Palette.text)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(focused ? 0.1 : 0.06)))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(focused ? Palette.accent.opacity(0.7) : .clear, lineWidth: 1)
            )
            .animation(.quiet, value: focused)
    }
}

/// 细滑块。拇指中心跟着指针走，轨道两端留出拇指半径，避免拖到头时拇指被裁切、手感发飘。
struct ThinSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double
    var width: CGFloat = 150

    private let thumb: CGFloat = 14

    var body: some View {
        GeometryReader { geo in
            let span = range.upperBound - range.lowerBound
            let travel = max(geo.size.width - thumb, 1)
            let f = span > 0 ? min(max((value - range.lowerBound) / span, 0), 1) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12)).frame(height: 3)
                Capsule().fill(Palette.accent).frame(width: thumb / 2 + travel * f, height: 3)
                Circle()
                    .fill(Color.white)
                    .frame(width: thumb, height: thumb)
                    .shadow(color: .black.opacity(0.3), radius: 1.5, y: 0.5)
                    .offset(x: travel * f)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { g in
                        let x = min(max(g.location.x - thumb / 2, 0), travel)
                        let raw = range.lowerBound + Double(x / travel) * span
                        let stepped = (raw / step).rounded() * step
                        let next = min(max(stepped, range.lowerBound), range.upperBound)
                        if next != value { value = next }
                    }
            )
            .onContinuousHover { phase in
                switch phase {
                case .active: NSCursor.resizeLeftRight.set()
                case .ended: NSCursor.arrow.set()
                }
            }
        }
        .frame(width: width, height: 22)
    }
}

/// 文字按钮
struct QuietButton: View {
    let title: String
    var prominent = false
    var destructive = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(prominent ? Color.white : (destructive ? Palette.critical : Palette.text))
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(prominent ? Palette.accent.opacity(hovering ? 0.9 : 1) : Color.white.opacity(hovering ? 0.12 : 0.07))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .onHover { h in withAnimation(.quiet) { hovering = h } }
    }
}
