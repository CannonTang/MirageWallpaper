//
//  Mirage Wallpaper
//
//  Copyright © 2026 王孝慈. All rights reserved.
//

import AVFoundation
import AppKit
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
}

struct MirageLockDisplayConfiguration: Codable {
    let displayID: UInt32
    let wallpaperID: String
    let title: String
    let kind: String
    let renderDirectory: String
    let entryPath: String
    let previewPath: String?
    let assetOverlays: [String]
    let properties: [String: MirageLockAnyValue]
    let rawProperties: [String: MirageLockAnyValue]
    let fps: Int
    let fillMode: String
    let enableHDRVideo: Bool
}

struct MirageLockConfiguration: Codable {
    let version: Int
    let displays: [String: MirageLockDisplayConfiguration]
}

final class MirageLockRenderer {
    private let rootLayer: CALayer
    private var player: AVPlayer?
    private var playerLayer: AVPlayerLayer?
    private var endObserver: NSObjectProtocol?

    init(rootLayer: CALayer, size: CGSize, scale: CGFloat, configuration: MirageLockDisplayConfiguration) {
        self.rootLayer = rootLayer
        rootLayer.frame = CGRect(origin: .zero, size: size)
        rootLayer.contentsScale = scale
        rootLayer.masksToBounds = true
        guard configuration.kind == "video" else { return }
        let item = AVPlayerItem(url: URL(fileURLWithPath: configuration.entryPath))
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        let layer = AVPlayerLayer(player: player)
        layer.frame = rootLayer.bounds
        layer.videoGravity = configuration.fillMode == "contain" ? .resizeAspect : configuration.fillMode == "stretch" ? .resize : .resizeAspectFill
        rootLayer.addSublayer(layer)
        self.player = player
        self.playerLayer = layer
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak player] _ in
            player?.seek(to: .zero)
            player?.play()
        }
        player.play()
    }

    func pause() {
        player?.pause()
    }

    func resume() {
        player?.play()
    }

    func stop() {
        player?.pause()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        playerLayer?.removeFromSuperlayer()
        playerLayer = nil
        player = nil
    }
}
