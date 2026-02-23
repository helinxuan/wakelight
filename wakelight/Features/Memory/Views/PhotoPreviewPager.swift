import SwiftUI
import GRDB
import Photos

/// Full screen photo preview pager used by both MemoryDetailSheet and MemoryPanelView.
struct PhotoPreviewPager: View {
    let locatorKeys: [String]
    let startIndex: Int

    @Environment(\.dismiss) private var dismiss
    @State private var selection: Int

    init(locatorKeys: [String], startIndex: Int) {
        self.locatorKeys = locatorKeys
        self.startIndex = startIndex
        _selection = State(initialValue: startIndex)
    }

    @State private var phAssetNames: [String: String] = [:]

    private var fileName: String {
        guard selection >= 0, selection < locatorKeys.count else { return "" }
        let key = locatorKeys[selection]

        if key.hasPrefix("webdav://") {
            let trimmed = String(key.dropFirst("webdav://".count))
            return trimmed.split(separator: "/").last.map(String.init) ?? key
        }

        if key.hasPrefix("library://") {
            if let name = phAssetNames[key] {
                return name
            }
            // Fallback while loading
            let localId = String(key.dropFirst("library://".count))
            return localId.split(separator: "/").first.map(String.init) ?? localId
        }

        return key.split(separator: "/").last.map(String.init) ?? key
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            TabView(selection: $selection) {
                ForEach(locatorKeys.indices, id: \.self) { idx in
                    let key = locatorKeys[idx]
                    ZoomableScrollView {
                        FullImageView(locatorKey: key)
                    }
                    .tag(idx)
                    .task {
                        if key.hasPrefix("library://") && phAssetNames[key] == nil {
                            let localId = String(key.dropFirst("library://".count))
                            let assets = PHAsset.fetchAssets(withLocalIdentifiers: [localId], options: nil)
                            if let asset = assets.firstObject {
                                let resources = PHAssetResource.assetResources(for: asset)
                                if let filename = resources.first?.originalFilename {
                                    phAssetNames[key] = filename
                                }
                            }
                        }
                    }
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()

            // Top bar: centered filename, close on the right.
            HStack(spacing: 12) {
                Color.clear
                    .frame(width: 44, height: 44)

                Spacer(minLength: 0)

                Text(fileName)
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.black.opacity(0.35)))

                Spacer(minLength: 0)

                Button(action: { dismiss() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(Color.black.opacity(0.35)))
                }
                .contentShape(Rectangle())
            }
            .padding(.horizontal, 12)
            .padding(.top, 14)
            .zIndex(1)
        }
    }
}

// MARK: - Zoom

private struct ZoomableScrollView<Content: View>: UIViewRepresentable {
    private var content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.maximumZoomScale = 4
        scrollView.minimumZoomScale = 1
        scrollView.bouncesZoom = true
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.backgroundColor = .clear

        let hostedView = context.coordinator.hostingController.view!
        hostedView.translatesAutoresizingMaskIntoConstraints = false
        hostedView.backgroundColor = .clear
        scrollView.addSubview(hostedView)

        NSLayoutConstraint.activate([
            hostedView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            hostedView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            hostedView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            hostedView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),

            // Match content size to the scroll view bounds at minimum so that:
            // - when zoomScale == 1, the image is fit-to-screen and centered by SwiftUI layout
            // - when zoomed in, the contentLayoutGuide drives contentSize allowing panning
            hostedView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            hostedView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor)
        ])

        return scrollView
    }

    func updateUIView(_ uiView: UIScrollView, context: Context) {
        context.coordinator.hostingController.rootView = content
        if !context.coordinator.didSetInitialZoom {
            context.coordinator.didSetInitialZoom = true
            uiView.setZoomScale(1.0, animated: false)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(hostingController: UIHostingController(rootView: content))
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        let hostingController: UIHostingController<Content>
        var didSetInitialZoom: Bool = false

        init(hostingController: UIHostingController<Content>) {
            self.hostingController = hostingController
            super.init()
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            hostingController.view
        }
    }
}
