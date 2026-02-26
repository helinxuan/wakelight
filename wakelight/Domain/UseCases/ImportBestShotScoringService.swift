import Foundation
import Photos
import Vision
import UIKit

struct BestShotScoreBreakdown: Sendable {
    let total: Double
    let faceCaptureQuality: Double
    let eyeOpenness: Double
    let smileExpression: Double
    let faceFrontness: Double
    let sharpness: Double
    let recognizedTextConfidence: Double?
}

actor ImportBestShotScoringService {
    static let shared = ImportBestShotScoringService()

    private init() {}

    func score(asset: PHAsset, image: UIImage) async -> BestShotScoreBreakdown {
        guard let cgImage = image.cgImage else {
            return BestShotScoreBreakdown(
                total: 0,
                faceCaptureQuality: 0,
                eyeOpenness: 0,
                smileExpression: 0,
                faceFrontness: 0,
                sharpness: 0,
                recognizedTextConfidence: nil
            )
        }

        let metrics = await analyze(cgImage: cgImage)
        let sharpness = estimateSharpness(image: image)

        let faceCapture = clamp01(metrics.faceConfidence) * 40
        let eyeOpenness = clamp01(metrics.eyeOpenness ?? 0.5) * 20
        let smile = clamp01(metrics.smile ?? 0.5) * 15
        let frontness = clamp01(metrics.frontness ?? 0.5) * 15
        let sharp = clamp01(sharpness) * 10

        let total = max(0, min(100, faceCapture + eyeOpenness + smile + frontness + sharp))

        return BestShotScoreBreakdown(
            total: total,
            faceCaptureQuality: faceCapture,
            eyeOpenness: eyeOpenness,
            smileExpression: smile,
            faceFrontness: frontness,
            sharpness: sharp,
            recognizedTextConfidence: metrics.textConfidence
        )
    }

    private func analyze(cgImage: CGImage) async -> (faceConfidence: Double, eyeOpenness: Double?, smile: Double?, frontness: Double?, textConfidence: Double?) {
        await withCheckedContinuation { continuation in
            var faceConfidence: Double = 0
            var eyeOpenness: Double?
            var smile: Double?
            var frontness: Double?
            var textConfidence: Double?

            let faceRequest = VNDetectFaceLandmarksRequest { request, _ in
                guard let faces = request.results as? [VNFaceObservation], let face = faces.first else { return }
                faceConfidence = Double(face.confidence)

                if let landmarks = face.landmarks {
                    if let leftEye = landmarks.leftEye, let rightEye = landmarks.rightEye {
                        let leftOpen = self.eyeOpenness(points: leftEye.normalizedPoints)
                        let rightOpen = self.eyeOpenness(points: rightEye.normalizedPoints)
                        eyeOpenness = (leftOpen + rightOpen) / 2
                    }
                    if let outerLips = landmarks.outerLips {
                        smile = self.smileEstimate(points: outerLips.normalizedPoints)
                    }
                }

                let yaw = abs(face.yaw?.doubleValue ?? 0)
                let roll = abs(face.roll?.doubleValue ?? 0)
                let pitch = abs(face.pitch?.doubleValue ?? 0)
                let penalty = min(1, (yaw + roll + pitch) / 1.2)
                frontness = max(0, 1 - penalty)
            }

            let textRequest = VNRecognizeTextRequest { request, _ in
                guard let observations = request.results as? [VNRecognizedTextObservation], !observations.isEmpty else { return }
                let confs = observations.compactMap { $0.topCandidates(1).first.map { Double($0.confidence) } }
                if !confs.isEmpty { textConfidence = confs.reduce(0, +) / Double(confs.count) }
            }
            textRequest.recognitionLevel = .fast
            textRequest.usesLanguageCorrection = false

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try handler.perform([faceRequest, textRequest])
                } catch {
                    // ignore and return defaults
                }
                continuation.resume(returning: (faceConfidence, eyeOpenness, smile, frontness, textConfidence))
            }
        }
    }

    private func eyeOpenness(points: [CGPoint]) -> Double {
        guard points.count >= 6 else { return 0.5 }
        let vertical = abs(points[1].y - points[5].y) + abs(points[2].y - points[4].y)
        let horizontal = max(0.0001, abs(points[0].x - points[3].x))
        return clamp01(Double(vertical / horizontal))
    }

    private func smileEstimate(points: [CGPoint]) -> Double {
        guard points.count >= 8 else { return 0.5 }
        let width = max(0.0001, abs(points[0].x - points[6].x))
        let height = abs(points[3].y - points[9 % points.count].y)
        return clamp01(Double(height / width) * 2)
    }

    private func estimateSharpness(image: UIImage) -> Double {
        guard let cg = image.cgImage, let provider = cg.dataProvider, let data = provider.data else { return 0.5 }
        let ptr = CFDataGetBytePtr(data)
        let width = cg.width
        let height = cg.height
        let bpp = cg.bitsPerPixel / 8
        let rowBytes = cg.bytesPerRow
        guard let ptr, width > 2, height > 2, bpp >= 3 else { return 0.5 }

        let stepX = max(1, width / 64)
        let stepY = max(1, height / 64)
        var totalGrad: Double = 0
        var count = 0

        for y in stride(from: stepY, to: height - stepY, by: stepY) {
            for x in stride(from: stepX, to: width - stepX, by: stepX) {
                let idx = y * rowBytes + x * bpp
                let idxR = y * rowBytes + (x + stepX) * bpp
                let idxD = (y + stepY) * rowBytes + x * bpp

                let lum = 0.299 * Double(ptr[idx]) + 0.587 * Double(ptr[idx + 1]) + 0.114 * Double(ptr[idx + 2])
                let lumR = 0.299 * Double(ptr[idxR]) + 0.587 * Double(ptr[idxR + 1]) + 0.114 * Double(ptr[idxR + 2])
                let lumD = 0.299 * Double(ptr[idxD]) + 0.587 * Double(ptr[idxD + 1]) + 0.114 * Double(ptr[idxD + 2])

                totalGrad += abs(lum - lumR) + abs(lum - lumD)
                count += 1
            }
        }

        guard count > 0 else { return 0.5 }
        let avg = totalGrad / Double(count)
        return clamp01(avg / 50.0)
    }

    private func clamp01(_ v: Double) -> Double { max(0, min(1, v)) }
}
