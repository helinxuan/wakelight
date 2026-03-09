import SwiftUI

struct TimelineCarouselView: View {
    let nodes: [TimeRouteNode]
    @Binding var selectedIndex: Int
    @Binding var isExpanded: Bool
    let cardHeight: CGFloat
    let onShowDetail: (TimeRouteNode) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(Array(nodes.enumerated()), id: \.offset) { index, node in
                        TimelineCardView(
                            node: node,
                            isSelected: index == selectedIndex,
                            isExpanded: $isExpanded,
                            cardHeight: cardHeight
                        )
                        .id(index)
                        .contentShape(Rectangle())
                        .onTapGesture {
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
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
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
    @Binding var isExpanded: Bool
    let cardHeight: CGFloat

    private var cardWidth: CGFloat { min(UIScreen.main.bounds.width - 24, 430) }
    private var photoRatioInCard: CGFloat { isExpanded ? 0.62 : 0.54 }
    private var photoHeight: CGFloat { cardHeight * photoRatioInCard }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            photoArea
                .padding(.top, 12)

            VStack(alignment: .leading, spacing: 10) {
                header

                if let summary = node.displaySummary, !summary.isEmpty {
                    Text(summary)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.white.opacity(0.92))
                        .lineLimit(isExpanded ? 6 : 2)
                        .multilineTextAlignment(.leading)
                } else {
                    Text("记录一段回忆...")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.white.opacity(0.62))
                        .italic()
                        .lineLimit(2)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)

            Spacer(minLength: 8)

            expandHandle
                .padding(.top, 8)
                .padding(.bottom, 10)
        }
        .frame(width: cardWidth, height: cardHeight, alignment: .top)
        .background(.ultraThinMaterial.opacity(0.68))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.16), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.12), radius: 30, y: 8)
        .scaleEffect(isSelected ? 1.0 : 0.985)
        .opacity(isSelected ? 1.0 : 0.9)
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: isSelected)
        .simultaneousGesture(
            DragGesture(minimumDistance: 14)
                .onEnded { value in
                    let horizontal = abs(value.translation.width)
                    let vertical = abs(value.translation.height)
                    guard vertical > horizontal else { return }

                    if value.translation.height < -38 {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            isExpanded = true
                        }
                    } else if value.translation.height > 38 {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            isExpanded = false
                        }
                    }
                }
        )
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(primaryLocationDisplayText)
                .font(.system(size: 19, weight: .bold))
                .foregroundColor(.white)
                .lineLimit(1)

            Spacer(minLength: 0)

            if let dateText = node.displayTitle {
                Text(dateText)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.96))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.16))
                    .clipShape(Capsule())
            }
        }
    }

    private var photoArea: some View {
        ZStack {
            if let cover = node.coverPhotoIdentifier {
                ThumbnailView(locatorKey: cover, size: CGSize(width: cardWidth - 24, height: photoHeight), preferHighQuality: true)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: cardWidth - 24, height: photoHeight)
                    .background(Color.black.opacity(0.24))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                Rectangle()
                    .fill(LinearGradient(colors: [Color.gray.opacity(0.24), Color.gray.opacity(0.12)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay {
                        Image(systemName: "photo")
                            .font(.system(size: 32))
                            .foregroundColor(.secondary.opacity(0.55))
                    }
            }
        }
        .frame(width: cardWidth - 24, height: photoHeight)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 12)
    }

    private var primaryLocationDisplayText: String {
        let poi = node.placeCluster?.poiName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !poi.isEmpty, poi != "未知地点" {
            return poi
        }

        let detail = node.placeCluster?.detailedAddress?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !detail.isEmpty, detail != "未知地点" {
            return detail
        }

        let city = node.placeCluster?.cityName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !city.isEmpty, city != "未知城市" {
            return city
        }

        let fallback = node.displayLocation?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !fallback.isEmpty, fallback != "未知地点" {
            return fallback
        }

        return "未知地点"
    }

    private var secondaryCityDisplayText: String? {
        let city = node.placeCluster?.cityName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !city.isEmpty, city != "未知城市" else { return nil }

        let detail = node.placeCluster?.detailedAddress?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if detail == city {
            return nil
        }

        return city
    }

    private var expandHandle: some View {
        HStack(spacing: 6) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
                .font(.system(size: 11, weight: .semibold))
            Text(isExpanded ? "下滑收起" : "上滑展开")
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundColor(.white.opacity(0.86))
        .frame(maxWidth: .infinity)
    }
}
