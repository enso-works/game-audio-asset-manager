import SwiftUI

/// Lays children out left to right and wraps onto new lines when they don't fit.
/// Each child is measured once per layout pass, unlike ViewThatFits which lays out every variant.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 6

    struct Cache {
        var sizes: [CGSize] = []
    }

    func makeCache(subviews: Subviews) -> Cache {
        Cache(sizes: subviews.map { $0.sizeThatFits(.unspecified) })
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache = makeCache(subviews: subviews)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        // Minimum-size probes propose a width of zero; answering with one child per line would
        // make the window's minimum height huge. Report "can shrink, one line tall" instead;
        // real layout passes propose the actual width and wrap properly.
        let probing = (proposal.width ?? .infinity) < 1
        let lines = arrange(cache.sizes, width: probing ? .infinity : proposal.width ?? .infinity)
        let width = lines.map(\.width).max() ?? 0
        let height = lines.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(lines.count - 1, 0))
        return CGSize(width: probing ? 0 : proposal.width.map { min($0, width) } ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        var y = bounds.minY
        for line in arrange(cache.sizes, width: bounds.width) {
            var x = bounds.minX
            for index in line.indices {
                let size = cache.sizes[index]
                subviews[index].place(at: CGPoint(x: x, y: y + (line.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += line.height + lineSpacing
        }
    }

    private struct Line {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ sizes: [CGSize], width: CGFloat) -> [Line] {
        var lines: [Line] = [Line()]
        for (index, size) in sizes.enumerated() {
            let extra = lines[lines.count - 1].indices.isEmpty ? size.width : size.width + spacing
            if lines[lines.count - 1].width + extra > width, !lines[lines.count - 1].indices.isEmpty {
                lines.append(Line())
            }
            let isFirst = lines[lines.count - 1].indices.isEmpty
            lines[lines.count - 1].indices.append(index)
            lines[lines.count - 1].width += isFirst ? size.width : size.width + spacing
            lines[lines.count - 1].height = max(lines[lines.count - 1].height, size.height)
        }
        return lines
    }
}
