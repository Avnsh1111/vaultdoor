#if VAULT_TEST
import AppKit
import AVFoundation
import WebKit

/// Records the dashboard page itself to a video. Compiled only into the test build.
/// It sees nothing but this page, so nothing else on the screen can end up in a recording.
final class PageRecorder {
    private let web: WKWebView
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var timer: Timer?
    private var busy = false
    private var started: CFTimeInterval = 0
    private(set) var frames = 0
    private let size = CGSize(width: 1920, height: 1080)

    init(web: WKWebView, path: String) throws {
        self.web = web
        try? FileManager.default.removeItem(atPath: path)
        writer = try AVAssetWriter(outputURL: URL(fileURLWithPath: path), fileType: .mp4)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 1920, AVVideoHeightKey: 1080,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 30_000_000],
        ])
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 1920, kCVPixelBufferHeightKey as String: 1080,
        ])
        writer.add(input)
    }

    func start() {
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        started = CACurrentMediaTime()
        timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.capture() }
        RunLoop.main.add(timer!, forMode: .common)
    }

    private func capture() {
        guard !busy else { return }
        busy = true
        let config = WKSnapshotConfiguration()
        config.afterScreenUpdates = false
        config.snapshotWidth = 960  // 1920 pixels on a Retina display
        web.takeSnapshot(with: config) { [weak self] image, _ in
            guard let self else { return }
            defer { self.busy = false }
            guard let image, let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            self.append(cgImage)
        }
    }

    private func append(_ image: CGImage) {
        guard input.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else { return }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { return }
        CVPixelBufferLockBaseAddress(buffer, [])
        let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: 1920, height: 1080, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        context?.interpolationQuality = .high
        context?.draw(image, in: CGRect(origin: .zero, size: size))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        if adaptor.append(buffer, withPresentationTime: CMTime(seconds: CACurrentMediaTime() - started, preferredTimescale: 600)) { frames += 1 }
    }

    func finish(_ done: @escaping () -> Void) {
        timer?.invalidate()
        input.markAsFinished()
        let seconds = CACurrentMediaTime() - started
        print("recorded \(frames) frames in \(Int(seconds))s, \(Int(Double(frames) / seconds)) per second")
        fflush(stdout)
        writer.finishWriting(completionHandler: done)
    }
}
#endif
