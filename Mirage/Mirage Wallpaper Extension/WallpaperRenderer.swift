//
//  Mirage Wallpaper
//
//  Copyright © 2026 王孝慈. All rights reserved.
//

import AVFoundation
import AppKit
import Darwin
import Foundation

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
    let rawProperties: [String: MirageLockAnyValue]
    let fps: Int
    let fillMode: String
}

struct MirageLockConfiguration: Codable {
    let version: Int
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
    private var endObserver: NSObjectProtocol?
    private var isPaused = false
    private var sceneLibrary: MirageSceneLibrary?
    private var sceneEngine: UnsafeMutableRawPointer?

    init(rootLayer: CALayer, size: CGSize, scale: CGFloat, configuration: MirageLockDisplayConfiguration) {
        self.rootLayer = rootLayer
        rootLayer.frame = CGRect(origin: .zero, size: size)
        rootLayer.contentsScale = scale
        rootLayer.masksToBounds = true
        switch configuration.kind {
        case "video": loadVideo(configuration)
        case "scene": loadScene(configuration, size: size)
        default: break
        }
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

    func stop() {
        player?.pause()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let sceneEngine { sceneLibrary?.destroy(sceneEngine) }
        sceneEngine = nil
        sceneLibrary = nil
        playerLayer?.removeFromSuperlayer()
        playerLayer = nil
        player = nil
    }
}
