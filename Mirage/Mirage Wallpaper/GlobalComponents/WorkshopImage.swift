//
//  Mirage Wallpaper
//
//  Copyright © 2026 王孝慈. All rights reserved.
//

import AppKit
import CryptoKit
import ImageIO
import SwiftUI

final class WorkshopImageLoader {
    static let shared = WorkshopImageLoader()

    private let memory: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 400
        cache.totalCostLimit = 160 * 1024 * 1024
        return cache
    }()

    private let dataMemory: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.countLimit = 120
        cache.totalCostLimit = 80 * 1024 * 1024
        return cache
    }()

    private let ioQueue = DispatchQueue(
        label: "cn.laobamac.Mirage.workshopImage", qos: .userInitiated, attributes: .concurrent)

    private let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 40
        configuration.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: configuration)
    }()

    private let diskDirectory: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "Mirage/WorkshopImageCache")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private func maxPixel(for size: CGSize, scale: CGFloat) -> Int {
        let raw = Double(max(size.width, size.height)) * Double(max(scale, 1))
        let bucket = (raw / 64).rounded(.up) * 64
        return max(64, min(Int(bucket), 2048))
    }

    private func memoryKey(_ url: URL, _ px: Int) -> NSString {
        "\(url.absoluteString)#\(px)" as NSString
    }

    private func diskURL(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return diskDirectory.appending(path: digest)
    }

    private func cost(_ image: NSImage) -> Int {
        guard let rep = image.representations.first else { return 1 }
        return max(1, rep.pixelsWide * rep.pixelsHigh * 4)
    }

    func cachedImage(url: URL, targetSize: CGSize, scale: CGFloat) -> NSImage? {
        memory.object(forKey: memoryKey(url, maxPixel(for: targetSize, scale: scale)))
    }

    func load(url: URL, targetSize: CGSize, scale: CGFloat,
              completion: @escaping (NSImage?, Data?) -> Void) {
        let px = maxPixel(for: targetSize, scale: scale)
        let key = memoryKey(url, px)
        let dataKey = url.absoluteString as NSString
        if let image = memory.object(forKey: key),
           let cachedData = dataMemory.object(forKey: dataKey) {
            let data = cachedData as Data
            completion(image, Self.isAnimated(data) ? data : nil)
            return
        }
        ioQueue.async { [weak self] in
            guard let self else { return }
            let disk = self.diskURL(for: url)
            if let data = try? Data(contentsOf: disk), !data.isEmpty,
               let image = Self.downsample(data, maxPixel: px) {
                self.store(data: data, image: image, dataKey: dataKey, imageKey: key)
                DispatchQueue.main.async {
                    completion(image, Self.isAnimated(data) ? data : nil)
                }
                return
            }
            self.session.dataTask(with: URLRequest(url: url)) { [weak self] data, response, _ in
                guard let self else { return }
                let ok = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? true
                guard ok, let data, !data.isEmpty else {
                    DispatchQueue.main.async { completion(nil, nil) }
                    return
                }
                try? data.write(to: disk, options: .atomic)
                let image = Self.downsample(data, maxPixel: px)
                if let image {
                    self.store(data: data, image: image, dataKey: dataKey, imageKey: key)
                }
                DispatchQueue.main.async {
                    completion(image, Self.isAnimated(data) ? data : nil)
                }
            }.resume()
        }
    }

    private func store(data: Data, image: NSImage, dataKey: NSString, imageKey: NSString) {
        dataMemory.setObject(data as NSData, forKey: dataKey, cost: data.count)
        memory.setObject(image, forKey: imageKey, cost: cost(image))
    }

    private static func isAnimated(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return CGImageSourceGetCount(source) > 1
    }

    private static func downsample(_ data: Data, maxPixel: Int) -> NSImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return NSImage(data: data)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return NSImage(data: data)
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}

struct WorkshopImage: View {
    let url: URL?
    var contentMode: ContentMode = .fill
    var isAnimating = false

    @Environment(\.displayScale) private var displayScale
    @State private var image: NSImage?
    @State private var animationData: Data?
    @State private var failed = false
    @State private var boxSize: CGSize = .zero
    @State private var loadToken: UInt64 = 0

    var body: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.10))
            .overlay {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: contentMode)
                    if isAnimating, let animationData, let url {
                        WorkshopAnimatedImage(data: animationData, identity: url.absoluteString)
                    }
                } else if failed {
                    Image(systemName: "photo")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .clipped()
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear {
                            boxSize = proxy.size
                            load()
                        }
                        .onChange(of: proxy.size) { _, newValue in
                            guard abs(newValue.width - boxSize.width) > 1 ||
                                  abs(newValue.height - boxSize.height) > 1 else { return }
                            boxSize = newValue
                            load()
                        }
                }
            )
            .onChange(of: url) { _, _ in
                image = nil
                animationData = nil
                failed = false
                load()
            }
            .onDisappear {
                loadToken &+= 1
                animationData = nil
            }
    }

    private func load() {
        guard let url, boxSize.width > 1, boxSize.height > 1 else { return }
        let scale = displayScale
        if let cached = WorkshopImageLoader.shared.cachedImage(url: url, targetSize: boxSize, scale: scale) {
            image = cached
            failed = false
        }
        loadToken &+= 1
        let token = loadToken
        let requestedURL = url
        WorkshopImageLoader.shared.load(url: requestedURL, targetSize: boxSize, scale: scale) { loaded, animatedData in
            guard token == loadToken, requestedURL == url else { return }
            if let loaded {
                image = loaded
                animationData = animatedData
                failed = false
            } else {
                failed = true
            }
        }
    }
}

private struct WorkshopAnimatedImage: NSViewRepresentable {
    let data: Data
    let identity: String

    final class Coordinator {
        var identity: String?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.imageAlignment = .alignCenter
        view.animates = true
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {
        guard context.coordinator.identity != identity else { return }
        context.coordinator.identity = identity
        view.image = NSImage(data: data)
        view.animates = true
    }

    static func dismantleNSView(_ view: NSImageView, coordinator: Coordinator) {
        view.animates = false
        view.image = nil
        coordinator.identity = nil
    }
}
