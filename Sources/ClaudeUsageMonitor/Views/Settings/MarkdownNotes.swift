import SwiftUI

/// Markdown 的一个块：标题、段落、列表项、代码块或引用
struct MarkdownBlock {
    enum Kind: Equatable {
        case heading(Int)
        case paragraph
        /// depth 从 1 开始；marker 是「•」「◦」或「1.」
        case listItem(depth: Int, marker: String)
        /// depth 是所在列表的层级（不在列表里为 0）
        case code(depth: Int)
        case quote
    }

    var kind: Kind
    /// 只保留行内样式（粗体、斜体、行内代码、链接）
    var text: AttributedString
}

enum MarkdownBlocks {
    /// 用系统的 Markdown 解析器解析，再按块拆开；解析失败时整段当作普通文本
    static func parse(_ markdown: String) -> [MarkdownBlock] {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)
        guard let document = try? AttributedString(markdown: markdown, options: options) else {
            return [MarkdownBlock(kind: .paragraph, text: AttributedString(markdown))]
        }
        var blocks: [MarkdownBlock] = []
        var currentIntent: PresentationIntent?
        for run in document.runs {
            var text = AttributedString(document[run.range])
            text.presentationIntent = nil
            if !blocks.isEmpty, run.presentationIntent == currentIntent {
                blocks[blocks.count - 1].text.append(text)
            } else {
                blocks.append(MarkdownBlock(kind: kind(of: run.presentationIntent), text: text))
                currentIntent = run.presentationIntent
            }
        }
        return blocks.filter { !String($0.text.characters).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// components 从最内层到最外层排列：例如列表里的段落是「段落、列表项、列表」
    private static func kind(of intent: PresentationIntent?) -> MarkdownBlock.Kind {
        guard let intent else { return .paragraph }
        var depth = 0
        var ordinal: Int?
        var innermostOrdered: Bool?
        var isQuote = false
        var isCode = false
        for component in intent.components {
            switch component.kind {
            case .header(let level):
                return .heading(level)
            case .codeBlock:
                isCode = true
            case .listItem(let number):
                if ordinal == nil { ordinal = number }
            case .orderedList:
                depth += 1
                if innermostOrdered == nil { innermostOrdered = true }
            case .unorderedList:
                depth += 1
                if innermostOrdered == nil { innermostOrdered = false }
            case .blockQuote:
                isQuote = true
            default:
                break
            }
        }
        if isCode { return .code(depth: depth) }
        if depth > 0 {
            let marker = innermostOrdered == true ? "\(ordinal ?? 1)." : (depth == 1 ? "•" : "◦")
            return .listItem(depth: depth, marker: marker)
        }
        return isQuote ? .quote : .paragraph
    }
}

/// 渲染后的 Markdown：标题、多级列表、段落层次分明，行内粗体、代码、链接照常显示
struct MarkdownNotes: View {
    let markdown: String

    var body: some View {
        let blocks = MarkdownBlocks.parse(markdown)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                blockView(block, isFirst: index == 0)
            }
        }
        .tint(Palette.accent)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock, isFirst: Bool) -> some View {
        switch block.kind {
        case .heading(let level):
            Text(block.text)
                .font(.system(size: level <= 2 ? 13 : 12, weight: .semibold))
                .foregroundStyle(Palette.text)
                .padding(.top, isFirst ? 0 : 14)
                .padding(.bottom, 7)
        case .paragraph:
            Text(block.text)
                .font(.system(size: 12))
                .foregroundStyle(Palette.secondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 8)
        case .listItem(let depth, let marker):
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(marker)
                    .foregroundStyle(Palette.tertiary)
                    .frame(minWidth: 8, alignment: .trailing)
                Text(block.text)
                    .foregroundStyle(Palette.secondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(size: 12))
            .padding(.leading, CGFloat(depth - 1) * 15)
            .padding(.bottom, 6)
        case .code(let depth):
            Text(block.text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.05)))
                .padding(.leading, depth > 0 ? CGFloat(depth - 1) * 15 + 15 : 0)
                .padding(.bottom, 8)
        case .quote:
            HStack(alignment: .top, spacing: 9) {
                Capsule().fill(Palette.quaternary).frame(width: 2)
                Text(block.text)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.tertiary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 8)
        }
    }
}

/// 可滚动区域：上面还有内容时顶部渐隐，下面还有内容时底部渐隐
struct FadingScrollView<Content: View>: View {
    var maxHeight: CGFloat
    var fade: CGFloat = 22
    @ViewBuilder var content: Content

    @State private var edges = Edges(top: true, bottom: true)

    private struct Edges: Equatable {
        var top: Bool
        var bottom: Bool
    }

    var body: some View {
        ScrollView {
            content
                .padding(.vertical, 2)
        }
        .scrollIndicators(.never)
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: maxHeight)
        .onScrollGeometryChange(for: Edges.self) { geometry in
            Edges(
                top: geometry.contentOffset.y <= 0.5,
                bottom: geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 0.5
            )
        } action: { _, new in
            withAnimation(.easeOut(duration: 0.2)) { edges = new }
        }
        .mask {
            VStack(spacing: 0) {
                LinearGradient(colors: [Color.black.opacity(edges.top ? 1 : 0), .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: fade)
                Rectangle()
                LinearGradient(colors: [.black, Color.black.opacity(edges.bottom ? 1 : 0)], startPoint: .top, endPoint: .bottom)
                    .frame(height: fade)
            }
        }
    }
}
