import UIKit
import MapKit
import Photos

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
    
    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        setupUI()
    }
    
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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
    
    func configure(with localIdentifier: String?) {
        guard let localId = localIdentifier else {
            imageView.image = nil
            return
        }
        
        // 简单直接使用 PHImageManager 加载，后续可接入 PhotoThumbnailLoader 缓存
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [localId], options: nil)
        if let asset = assets.firstObject {
            let options = PHImageRequestOptions()
            options.deliveryMode = .opportunistic
            options.isNetworkAccessAllowed = true
            
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 128, height: 128),
                contentMode: .aspectFill,
                options: options
            ) { [weak self] image, _ in
                self?.imageView.image = image
            }
        }
    }
}
