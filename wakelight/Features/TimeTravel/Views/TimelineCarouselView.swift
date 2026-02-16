import SwiftUI

struct TimelineCarouselView: View {
    let nodes: [TimeRouteNode]
    @Binding var selectedIndex: Int

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(Array(nodes.enumerated()), id: \.offset) { index, node in
                        TimelineCardView(node: node, isSelected: index == selectedIndex)
                            .id(index)
                            .onTapGesture {
                                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                                    selectedIndex = index
                                }
                            }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .onChange(of: selectedIndex) { _, newIndex in
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    proxy.scrollTo(newIndex, anchor: .center)
                }
            }
        }
    }
}

private struct TimelineCardView: View {
    let node: TimeRouteNode
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Photo Area
            ZStack(alignment: .bottomLeading) {
                if let cover = node.coverPhotoIdentifier {
                    ThumbnailView(localIdentifier: cover, size: CGSize(width: 260, height: 160))
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 260, height: 160)
                        .clipped()
                } else {
                    Rectangle()
                        .fill(LinearGradient(colors: [Color.gray.opacity(0.2), Color.gray.opacity(0.1)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 260, height: 160)
                        .overlay {
                            Image(systemName: "photo.on.rectangle.angled")
                                .font(.system(size: 30))
                                .foregroundColor(.secondary.opacity(0.5))
                        }
                }
                
                // Date Badge
                if let dateText = node.displayTitle {
                    Text(dateText)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                        .padding(10)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: isSelected ? .black.opacity(0.2) : .clear, radius: 10, y: 5)

            // Content Area
            VStack(alignment: .leading, spacing: 4) {
                if let summary = node.displaySummary, !summary.isEmpty {
                    Text(summary)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(isSelected ? .primary : .secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                } else {
                    Text("记录一段回忆...")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.secondary.opacity(0.6))
                        .italic()
                }
                
                if let location = node.displayLocation {
                    HStack(spacing: 4) {
                        Image(systemName: "mappin.and.ellipse")
                            .font(.system(size: 10))
                        Text(location)
                            .font(.system(size: 11))
                            .lineLimit(1)
                    }
                    .foregroundColor(.blue.opacity(0.8))
                    .padding(.top, 2)
                }
            }
            .padding(.top, 12)
            .padding(.horizontal, 4)
        }
        .frame(width: 260)
        .scaleEffect(isSelected ? 1.05 : 1.0)
        .opacity(isSelected ? 1.0 : 0.8)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: isSelected)
    }
}
