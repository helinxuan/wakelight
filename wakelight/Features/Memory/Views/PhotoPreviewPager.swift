import SwiftUI
import GRDB

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

    private var fileName: String {
        guard selection >= 0, selection < locatorKeys.count else { return "" }
        let key = locatorKeys[selection]
        // locatorKey in this app is typically a path-like string; keep extension.
        return key.split(separator: "/").last.map(String.init) ?? key
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            TabView(selection: $selection) {
                ForEach(Array(locatorKeys.enumerated()), id: \.offset) { idx, key in
                    ZoomableScrollView {
                        FullImageView(locatorKey: key)
                    }
                    .tag(idx)
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
            hostedView.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor),
            hostedView.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor),
            hostedView.topAnchor.constraint(equalTo: scrollView.frameLayoutGuide.topAnchor),
            hostedView.bottomAnchor.constraint(equalTo: scrollView.frameLayoutGuide.bottomAnchor)
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
