//
//  Mirage Wallpaper
//
//  Copyright © 2026 王孝慈. All rights reserved.
//

import AVFoundation
import AppKit
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import ImageIO

enum MirageLockAnyValue: Codable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: MirageLockAnyValue])
    case array([MirageLockAnyValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        if let value = try? container.decode(Double.self) { self = .number(value); return }
        if let value = try? container.decode(String.self) { self = .string(value); return }
        if let value = try? container.decode([String: MirageLockAnyValue].self) { self = .object(value); return }
        self = .array(try container.decode([MirageLockAnyValue].self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var foundationValue: Any {
        switch self {
        case .string(let value): return value
        case .number(let value): return value
        case .bool(let value): return value
        case .object(let value): return value.mapValues { $0.foundationValue }
        case .array(let value): return value.map(\.foundationValue)
        case .null: return NSNull()
        }
    }
}

struct MirageLockDisplayConfiguration: Codable {
    let displayID: UInt32
    let wallpaperID: String
    let title: String
    let kind: String
    let renderDirectory: String
    let entryPath: String
    let previewPath: String?
    let desktopFallbackPath: String?
    let rawProperties: [String: MirageLockAnyValue]
    let fps: Int
    let fillMode: String
}

struct MirageLockConfiguration: Codable {
    let version: Int
    let enabled: Bool?
    let displays: [String: MirageLockDisplayConfiguration]
}

private final class MirageSceneLibrary {
    typealias Create = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UInt32, UInt32, UInt32) -> UnsafeMutableRawPointer?
    typealias SetPaused = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Void
    typealias Destroy = @convention(c) (UnsafeMutableRawPointer?) -> Void

    let handle: UnsafeMutableRawPointer
    let create: Create
    let setPaused: SetPaused
    let destroy: Destroy

    init?() {
        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks/libMirageSceneSaver.dylib"),
            Bundle.main.privateFrameworksURL?.appendingPathComponent("libMirageSceneSaver.dylib"),
        ].compactMap { $0 }
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            guard let handle = dlopen(url.path, RTLD_NOW | RTLD_LOCAL),
                  let create = dlsym(handle, "MirageSceneDesktopCreate"),
                  let pause = dlsym(handle, "MirageSceneDesktopSetPaused"),
                  let destroy = dlsym(handle, "MirageSceneDesktopDestroy") else { continue }
            self.handle = handle
            self.create = unsafeBitCast(create, to: Create.self)
            self.setPaused = unsafeBitCast(pause, to: SetPaused.self)
            self.destroy = unsafeBitCast(destroy, to: Destroy.self)
            return
        }
        return nil
    }

    deinit { dlclose(handle) }
}

final class MirageLockRenderer {
    private let rootLayer: CALayer
    private var player: AVPlayer?
    private var playerLayer: AVPlayerLayer?
    private var desktopLayer: AVSampleBufferDisplayLayer?
    private var desktopFallbackPath: String?
    private var endObserver: NSObjectProtocol?
    private var isPaused = false
    private var isLocked: Bool
    private let dynamicEnabled: Bool
    private var sceneLibrary: MirageSceneLibrary?
    private var sceneEngine: UnsafeMutableRawPointer?

    init(rootLayer: CALayer, size: CGSize, scale: CGFloat,
         configuration: MirageLockDisplayConfiguration, locked: Bool,
         dynamicEnabled: Bool) {
        self.rootLayer = rootLayer
        self.isLocked = locked && dynamicEnabled
        self.dynamicEnabled = dynamicEnabled
        rootLayer.frame = CGRect(origin: .zero, size: size)
        rootLayer.contentsScale = scale
        rootLayer.masksToBounds = true
        if dynamicEnabled {
            switch configuration.kind {
            case "video": loadVideo(configuration)
            case "scene": loadScene(configuration, size: size)
            default: break
            }
        }
        updateDesktopFallback(path: configuration.desktopFallbackPath)
        setLocked(locked && dynamicEnabled)
    }

    private func loadVideo(_ configuration: MirageLockDisplayConfiguration) {
        let item = AVPlayerItem(url: URL(fileURLWithPath: configuration.entryPath))
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        let layer = AVPlayerLayer(player: player)
        layer.frame = rootLayer.bounds
        layer.videoGravity = configuration.fillMode == "contain" ? .resizeAspect : configuration.fillMode == "stretch" ? .resize : .resizeAspectFill
        rootLayer.addSublayer(layer)
        self.player = player
        self.playerLayer = layer
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            guard let self, !self.isPaused else { return }
            self.player?.seek(to: .zero)
            self.player?.play()
        }
        player.play()
    }

    private func loadScene(_ configuration: MirageLockDisplayConfiguration, size: CGSize) {
        guard let assetsURL = Bundle.main.resourceURL?.appendingPathComponent("assets", isDirectory: true),
              FileManager.default.fileExists(atPath: assetsURL.path),
              let library = MirageSceneLibrary() else {
            NSLog("[MirageLock] scene runtime unavailable")
            return
        }
        guard let icdURL = Bundle.main.resourceURL?.appendingPathComponent("vulkan/icd.d/MoltenVK_icd.json"),
              FileManager.default.fileExists(atPath: icdURL.path) else {
            NSLog("[MirageLock] scene Vulkan ICD unavailable")
            return
        }
        setenv("VK_ICD_FILENAMES", icdURL.path, 1)
        setenv("VK_DRIVER_FILES", icdURL.path, 1)
        let properties = configuration.rawProperties.mapValues { $0.foundationValue }
        guard let data = try? JSONSerialization.data(withJSONObject: properties),
              let json = String(data: data, encoding: .utf8) else { return }
        let width = UInt32(max(1, min(size.width * rootLayer.contentsScale, 8192)))
        let height = UInt32(max(1, min(size.height * rootLayer.contentsScale, 8192)))
        let pointer = Unmanaged.passUnretained(rootLayer).toOpaque()
        let engine = assetsURL.path.withCString { assets in
            configuration.entryPath.withCString { pkg in
                json.withCString { props in
                    library.create(pointer, assets, pkg, props, width, height, UInt32(max(10, min(configuration.fps, 60))))
                }
            }
        }
        guard let engine else {
            NSLog("[MirageLock] scene engine creation failed: pkg=%@", configuration.entryPath)
            return
        }
        sceneLibrary = library
        sceneEngine = engine
    }

    func pause() {
        isPaused = true
        player?.pause()
        if let sceneEngine { sceneLibrary?.setPaused(sceneEngine, 1) }
    }

    func resume() {
        isPaused = false
        player?.play()
        if let sceneEngine { sceneLibrary?.setPaused(sceneEngine, 0) }
    }

    func setLocked(_ locked: Bool) {
        let effectiveLocked = locked && dynamicEnabled
        isLocked = effectiveLocked
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if effectiveLocked {
            resume()
            desktopLayer?.opacity = 0
        } else {
            desktopLayer?.opacity = 1
        }
        CATransaction.commit()
        CATransaction.flush()
        if !effectiveLocked { pause() }
    }

    func updateDesktopFallback(path: String?) {
        guard desktopFallbackPath != path || desktopLayer == nil else { return }
        let image = path.flatMap(Self.loadImage) ?? Self.systemFallbackImage() ?? Self.solidImage()
        guard let image, let sample = Self.makeStillSampleBuffer(from: image) else { return }
        let layer: AVSampleBufferDisplayLayer
        if let existing = desktopLayer {
            layer = existing
        } else {
            layer = AVSampleBufferDisplayLayer()
            layer.frame = rootLayer.bounds
            layer.contentsScale = rootLayer.contentsScale
            layer.videoGravity = .resizeAspectFill
            layer.isOpaque = true
            layer.zPosition = 1_000_000
            layer.opacity = isLocked ? 0 : 1
            rootLayer.addSublayer(layer)
            desktopLayer = layer
        }
        Self.setDisplayImmediately(sample)
        layer.sampleBufferRenderer.enqueue(sample)
        desktopFallbackPath = path
    }

    func stop() {
        player?.pause()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let sceneEngine { sceneLibrary?.destroy(sceneEngine) }
        sceneEngine = nil
        sceneLibrary = nil
        playerLayer?.removeFromSuperlayer()
        playerLayer = nil
        player = nil
        desktopLayer?.sampleBufferRenderer.flush()
        desktopLayer?.removeFromSuperlayer()
        desktopLayer = nil
    }

    private static func loadImage(_ path: String) -> CGImage? {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func systemFallbackImage() -> CGImage? {
        let directories = [
            URL(fileURLWithPath: "/System/Library/Desktop Pictures", isDirectory: true),
            URL(fileURLWithPath: "/System/Library/CoreServices", isDirectory: true)
        ]
        for directory in directories {
            let candidates = (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
            )) ?? []
            for candidate in candidates.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                if let image = loadImage(candidate.path) { return image }
            }
        }
        return nil
    }

    private static func solidImage() -> CGImage? {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: 2,
                height: 2,
                bitsPerComponent: 8,
                bytesPerRow: 8,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        context.setFillColor(NSColor.black.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        return context.makeImage()
    }

    private static func makeStillSampleBuffer(from image: CGImage) -> CMSampleBuffer? {
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:],
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            image.width,
            image.height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        ) == kCVReturnSuccess, let pixelBuffer else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              ) else {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            return nil
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        var formatDescription: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        ) == noErr, let formatDescription else { return nil }
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        ) == noErr else { return nil }
        return sampleBuffer
    }

    private static func setDisplayImmediately(_ sampleBuffer: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer, createIfNecessary: true
        ) else { return }
        for index in 0 ..< CFArrayGetCount(attachments) {
            let dictionary = unsafeBitCast(
                CFArrayGetValueAtIndex(attachments, index), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dictionary,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }
    }
}
