import SwiftUI

/// 按下时轻微缩小
struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.97

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.quiet, value: configuration.isPressed)
    }
}

/// 底栏文字按钮
struct FooterButton: View {
    let icon: Icon
    let title: String
    var rotation: Double = 0
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                SVGIcon(icon, size: 12.5)
                    .rotationEffect(.degrees(rotation))
                Text(title)
                    .font(.system(size: 11.5, weight: .regular))
            }
            .foregroundStyle(hovering ? Palette.text : Palette.secondary)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hovering ? Palette.hover : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .onHover { h in withAnimation(.quiet) { hovering = h } }
    }
}
