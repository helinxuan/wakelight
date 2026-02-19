import UIKit
import MapKit

final class StoryAnnotationView: MKAnnotationView {
    private let imageView: UIImageView = {
        let iv = UIImageView()
        iv.contentMode = .scaleAspectFill
        iv.clipsToBounds = true
        iv.layer.cornerRadius = 8
        iv.layer.borderWidth = 2
        iv.layer.borderColor = UIColor.white.cgColor
        iv.backgroundColor = .systemGray6
        return iv
    }()

    private var currentTask: Task<Void, Never>?

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        setupUI()
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        currentTask?.cancel()
        currentTask = nil
        imageView.image = nil
    }

    private func setupUI() {
        frame = CGRect(x: 0, y: 0, width: 64, height: 64)
        addSubview(imageView)
        imageView.frame = bounds

        // 添加阴影
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.3
        layer.shadowOffset = CGSize(width: 0, height: 2)
        layer.shadowRadius = 4
    }

    /// 统一使用 MediaLocator.stableKey（例如 library://xxx 或 webdav://profileId/remotePath）
    func configure(with locatorKey: String?) {
        currentTask?.cancel()
        imageView.image = nil

        guard let locatorKey, !locatorKey.isEmpty else {
            return
        }

        currentTask = Task { [weak self] in
            let img = await PhotoThumbnailLoader.shared.loadThumbnail(locatorKey: locatorKey, size: CGSize(width: 128, height: 128))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.imageView.image = img
            }
        }
    }
}
