import SwiftUI

struct TimelineCarouselView: View {
    let nodes: [TimeRouteNode]
    @Binding var selectedIndex: Int

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(Array(nodes.enumerated()), id: \.offset) { index, node in
                        Button {
                            selectedIndex = index
                        } label: {
                            TimelineCardView(node: node, isSelected: index == selectedIndex)
                        }
                        .id(index)
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .onChange(of: selectedIndex) { _, newIndex in
                withAnimation(.easeInOut) {
                    proxy.scrollTo(newIndex, anchor: .center)
                }
            }
        }
        .background(.ultraThinMaterial)
    }
}

private struct TimelineCardView: View {
    let node: TimeRouteNode
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let cover = node.coverPhotoIdentifier {
                ThumbnailView(localIdentifier: cover, size: CGSize(width: 240, height: 130))
                    .cornerRadius(12)
            } else {
                Color.gray.opacity(0.2)
                    .frame(width: 240, height: 130)
                    .cornerRadius(12)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(node.displayTitle ?? "Story")
                    .font(.headline)
                    .lineLimit(1)

                if let summary = node.displaySummary, !summary.isEmpty {
                    Text(summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else {
                    Text("(No text)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(12)
        .frame(width: 240, alignment: .leading)
        .background(isSelected ? Color.orange.opacity(0.15) : Color.black.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isSelected ? Color.orange.opacity(0.55) : Color.clear, lineWidth: 1)
        }
    }
}
