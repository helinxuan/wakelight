import SwiftUI

struct TimelineCarouselView: View {
    let nodes: [TimeRouteNode]
    @Binding var selectedIndex: Int
    let onShowDetail: (TimeRouteNode) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(Array(nodes.enumerated()), id: \.offset) { index, node in
                        TimelineCardView(node: node, isSelected: index == selectedIndex)
                            .id(index)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                print("DEBUG: TimelineCarouselView - tapped index=\(index) selected=\(index == selectedIndex) nodeId=\(node.id)")
                                if index == selectedIndex {
                                    onShowDetail(node)
                                } else {
                                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                                        selectedIndex = index
                                    }
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

    private let cardWidth: CGFloat = 372
    private let photoHeight: CGFloat = 258

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Photo Area
            ZStack(alignment: .bottomLeading) {
                if let cover = node.coverPhotoIdentifier {
                    ThumbnailView(locatorKey: cover, size: CGSize(width: cardWidth, height: photoHeight))
                        .aspectRatio(contentMode: .fill)
                        .frame(width: cardWidth, height: photoHeight)
                        .clipped()
                } else {
                    Rectangle()
                        .fill(LinearGradient(colors: [Color.gray.opacity(0.2), Color.gray.opacity(0.1)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: cardWidth, height: photoHeight)
                        .overlay {
                            Image(systemName: "photo.on.rectangle.angled")
                                .font(.system(size: 38))
                                .foregroundColor(.secondary.opacity(0.5))
                        }
                }

                HStack(spacing: 8) {
                    if let dateText = node.displayTitle {
                        Text(dateText)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.ultraThinMaterial)
                            .clipShape(Capsule())
                    }

                    Spacer(minLength: 0)

                    if let location = node.displayLocation, !location.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "mappin.and.ellipse")
                                .font(.system(size: 10, weight: .semibold))
                            Text(location)
                                .font(.system(size: 11, weight: .semibold))
                                .lineLimit(1)
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity)
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: isSelected ? .black.opacity(0.2) : .clear, radius: 10, y: 5)

            // Content Area
            VStack(alignment: .leading, spacing: 4) {
                if let summary = node.displaySummary, !summary.isEmpty {
                    Text(summary)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(isSelected ? .primary : .secondary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                } else {
                    Text("记录一段回忆...")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.secondary.opacity(0.6))
                        .italic()
                }
            }
            .padding(.top, 12)
            .padding(.horizontal, 4)
            .frame(minHeight: 72, alignment: .topLeading)
        }
        .frame(width: cardWidth)
        .scaleEffect(isSelected ? 1.04 : 1.0)
        .opacity(isSelected ? 1.0 : 0.8)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: isSelected)
    }
}
