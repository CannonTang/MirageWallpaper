//
//  Mirage Wallpaper
//
//  Local Shadertoy-compatible wallpaper package support.
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ShadertoyPassID: String, CaseIterable, Codable, Identifiable {
    case common
    case bufferA
    case bufferB
    case bufferC
    case bufferD
    case image

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .common: return "Common"
        case .bufferA: return "Buffer A"
        case .bufferB: return "Buffer B"
        case .bufferC: return "Buffer C"
        case .bufferD: return "Buffer D"
        case .image: return "Image"
        }
    }

    var isRenderable: Bool { self != .common }

    static let renderOrder: [ShadertoyPassID] = [.bufferA, .bufferB, .bufferC, .bufferD, .image]
}

enum ShadertoyChannelSource: String, CaseIterable, Codable, Identifiable {
    case none
    case noise
    case texture
    case bufferA
    case bufferB
    case bufferC
    case bufferD

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return "未使用"
        case .noise: return "内置噪声纹理"
        case .texture: return "本地图片"
        case .bufferA: return "Buffer A"
        case .bufferB: return "Buffer B"
        case .bufferC: return "Buffer C"
        case .bufferD: return "Buffer D"
        }
    }

    var bufferPass: ShadertoyPassID? {
        switch self {
        case .bufferA: return .bufferA
        case .bufferB: return .bufferB
        case .bufferC: return .bufferC
        case .bufferD: return .bufferD
        default: return nil
        }
    }
}

enum ShadertoyTextureFilter: String, CaseIterable, Codable, Identifiable {
    case linear
    case nearest

    var id: String { rawValue }
    var displayName: String { self == .linear ? "线性" : "最近点" }
}

enum ShadertoyTextureWrap: String, CaseIterable, Codable, Identifiable {
    case repeatTexture = "repeat"
    case clamp

    var id: String { rawValue }
    var displayName: String { self == .repeatTexture ? "重复" : "钳制" }
}

struct ShadertoyChannelDraft: Equatable {
    var source: ShadertoyChannelSource = .none
    var textureURL: URL?
    var filter: ShadertoyTextureFilter = .linear
    var wrap: ShadertoyTextureWrap = .repeatTexture
    var flipY = true
}

struct ShadertoyPassDraft: Identifiable, Equatable {
    let id: ShadertoyPassID
    var code: String
    var channels: [ShadertoyChannelDraft]

    init(id: ShadertoyPassID, code: String = "") {
        self.id = id
        self.code = code
        self.channels = Array(repeating: ShadertoyChannelDraft(), count: 4)
    }

    var isEnabled: Bool {
        id == .image || !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct ShadertoyProjectDraft: Equatable {
    var title = "我的 Shader 壁纸"
    var author = "本地创建"
    var renderScale = 1.0
    var fpsLimit = 60
    var passes: [ShadertoyPassDraft]

    init() {
        passes = ShadertoyPassID.allCases.map { passID in
            if passID == .image {
                return ShadertoyPassDraft(id: passID, code: Self.starterImageCode)
            }
            return ShadertoyPassDraft(id: passID)
        }
    }

    static let starterImageCode = """
    void mainImage(out vec4 fragColor, in vec2 fragCoord)
    {
        vec2 uv = fragCoord / iResolution.xy;
        vec2 p = (2.0 * fragCoord - iResolution.xy) / iResolution.y;
        float glow = 0.5 + 0.5 * cos(iTime + length(p) * 6.0);
        vec3 color = 0.5 + 0.5 * cos(iTime + uv.xyx * 4.0 + vec3(0.0, 2.0, 4.0));
        fragColor = vec4(color * (0.65 + 0.35 * glow), 1.0);
    }
    """

    func pass(_ id: ShadertoyPassID) -> ShadertoyPassDraft {
        passes.first(where: { $0.id == id }) ?? ShadertoyPassDraft(id: id)
    }

    mutating func updatePass(_ id: ShadertoyPassID, _ update: (inout ShadertoyPassDraft) -> Void) {
        guard let index = passes.firstIndex(where: { $0.id == id }) else { return }
        update(&passes[index])
    }
}

enum ShadertoyProjectError: LocalizedError {
    case emptyTitle
    case missingMainImage(ShadertoyPassID)
    case missingBuffer(ShadertoyPassID, referencedBy: ShadertoyPassID)
    case missingTexture(ShadertoyPassID, Int)
    case textureTooLarge(String)
    case sourceTooLarge
    case runtimeMissing
    case packageWriteFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyTitle:
            return "请输入壁纸名称"
        case .missingMainImage(let pass):
            return "\(pass.displayName) 中没有找到 mainImage()"
        case .missingBuffer(let buffer, let owner):
            return "\(owner.displayName) 引用了尚未编写的 \(buffer.displayName)"
        case .missingTexture(let pass, let index):
            return "\(pass.displayName) 的 iChannel\(index) 尚未选择图片"
        case .textureTooLarge(let name):
            return "纹理 \(name) 超过 64 MB，请先压缩"
        case .sourceTooLarge:
            return "Shader 源码总大小超过 2 MB"
        case .runtimeMissing:
            return "应用内缺少 ShadertoyRuntime.js"
        case .packageWriteFailed(let message):
            return "Shader 壁纸保存失败：\(message)"
        }
    }
}

struct ShadertoyRuntimeChannel: Codable, Equatable {
    let kind: String
    let source: String?
    let url: String?
    let filter: String
    let wrap: String
    let flipY: Bool
}

struct ShadertoyRuntimePass: Codable, Equatable {
    let id: String
    let name: String
    let code: String
    let channels: [ShadertoyRuntimeChannel]
}

struct ShadertoyRuntimeConfig: Codable, Equatable {
    let version: Int
    let commonCode: String
    let renderScale: Double
    let fpsLimit: Int
    let maxDimension: Int
    let passes: [ShadertoyRuntimePass]
}

enum ShadertoyPackageBuilder {
    private static let maximumSourceBytes = 2 * 1024 * 1024
    private static let maximumTextureBytes = 64 * 1024 * 1024

    static func validate(_ draft: ShadertoyProjectDraft) throws {
        guard !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ShadertoyProjectError.emptyTitle
        }
        let totalSourceBytes = draft.passes.reduce(0) { $0 + $1.code.utf8.count }
        guard totalSourceBytes <= maximumSourceBytes else {
            throw ShadertoyProjectError.sourceTooLarge
        }

        for passID in ShadertoyPassID.renderOrder {
            let pass = draft.pass(passID)
            guard pass.isEnabled else { continue }
            guard pass.code.range(of: #"\bmainImage\s*\("#, options: .regularExpression) != nil else {
                throw ShadertoyProjectError.missingMainImage(passID)
            }
            for (index, channel) in pass.channels.enumerated() {
                if let buffer = channel.source.bufferPass, !draft.pass(buffer).isEnabled {
                    throw ShadertoyProjectError.missingBuffer(buffer, referencedBy: passID)
                }
                if channel.source == .texture {
                    guard let url = channel.textureURL,
                          FileManager.default.fileExists(atPath: url.path) else {
                        throw ShadertoyProjectError.missingTexture(passID, index)
                    }
                    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    guard size <= maximumTextureBytes else {
                        throw ShadertoyProjectError.textureTooLarge(url.lastPathComponent)
                    }
                }
            }
        }
    }

    static func makePreviewHTML(for draft: ShadertoyProjectDraft) throws -> String {
        try validate(draft)
        let config = try runtimeConfig(for: draft) { textureURL in
            let data = try Data(contentsOf: textureURL)
            let mime = mimeType(for: textureURL)
            return "data:\(mime);base64,\(data.base64EncodedString())"
        }
        return try html(config: config, runtime: runtimeSource(), inlineRuntime: true)
    }

    static func writePackage(_ draft: ShadertoyProjectDraft,
                             to destination: URL,
                             previewPNG: Data?) throws {
        try validate(draft)
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: destination, withIntermediateDirectories: false)
            let textureDirectory = destination.appending(path: "textures", directoryHint: .isDirectory)
            var copiedTextures: [String: String] = [:]
            var usedNames = Set<String>()

            let config = try runtimeConfig(for: draft) { sourceURL in
                let key = sourceURL.standardizedFileURL.path
                if let existing = copiedTextures[key] { return existing }
                if !fm.fileExists(atPath: textureDirectory.path) {
                    try fm.createDirectory(at: textureDirectory, withIntermediateDirectories: true)
                }
                let fileName = uniqueTextureName(for: sourceURL, used: &usedNames)
                let relative = "textures/\(fileName)"
                try fm.copyItem(at: sourceURL, to: destination.appending(path: relative))
                copiedTextures[key] = relative
                return relative
            }

            let runtime = try runtimeSource()
            guard let runtimeData = runtime.data(using: .utf8) else {
                throw ShadertoyProjectError.packageWriteFailed("无法编码运行时")
            }
            try runtimeData.write(to: destination.appending(path: "runtime.js"), options: .atomic)

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let shaderJSON = try encoder.encode(config)
            try shaderJSON.write(to: destination.appending(path: "shader.json"), options: .atomic)

            let indexHTML = try html(config: config, runtime: runtime, inlineRuntime: false)
            guard let indexData = indexHTML.data(using: .utf8) else {
                throw ShadertoyProjectError.packageWriteFailed("无法编码 index.html")
            }
            try indexData.write(to: destination.appending(path: "index.html"), options: .atomic)

            let preview = (previewPNG?.isEmpty == false ? previewPNG : nil) ?? fallbackPreviewPNG()
            guard !preview.isEmpty else {
                throw ShadertoyProjectError.packageWriteFailed("无法生成预览图")
            }
            try preview.write(to: destination.appending(path: "preview.png"), options: .atomic)

            let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let author = draft.author.trimmingCharacters(in: .whitespacesAndNewlines)
            let project = WEProject(
                approved: true,
                author: author.isEmpty ? nil : author,
                contentrating: "Everyone",
                description: "由 Mirage Shader 编辑器创建的 Shadertoy 兼容本地壁纸。",
                file: "index.html",
                preview: "preview.png",
                tags: ["Shader", "Shadertoy", "Local"],
                title: title,
                type: "web",
                version: 1
            )
            let projectJSON = try encoder.encode(project)
            try projectJSON.write(to: destination.appending(path: "project.json"), options: .atomic)
        } catch {
            try? fm.removeItem(at: destination)
            if let shaderError = error as? ShadertoyProjectError { throw shaderError }
            throw ShadertoyProjectError.packageWriteFailed(error.localizedDescription)
        }
    }

    private static func runtimeConfig(
        for draft: ShadertoyProjectDraft,
        textureURL: (URL) throws -> String
    ) throws -> ShadertoyRuntimeConfig {
        var runtimePasses: [ShadertoyRuntimePass] = []
        for passID in ShadertoyPassID.renderOrder {
            let pass = draft.pass(passID)
            guard pass.isEnabled else { continue }
            let channels = try (0..<4).map { index -> ShadertoyRuntimeChannel in
                let channel = index < pass.channels.count ? pass.channels[index] : ShadertoyChannelDraft()
                let kind: String
                let source: String?
                let url: String?
                switch channel.source {
                case .none:
                    kind = "none"; source = nil; url = nil
                case .noise:
                    kind = "noise"; source = nil; url = nil
                case .texture:
                    guard let selectedURL = channel.textureURL else {
                        throw ShadertoyProjectError.missingTexture(passID, index)
                    }
                    kind = "texture"; source = nil; url = try textureURL(selectedURL)
                case .bufferA, .bufferB, .bufferC, .bufferD:
                    kind = "buffer"; source = channel.source.rawValue; url = nil
                }
                return ShadertoyRuntimeChannel(
                    kind: kind,
                    source: source,
                    url: url,
                    filter: channel.filter.rawValue,
                    wrap: channel.wrap.rawValue,
                    flipY: channel.flipY
                )
            }
            runtimePasses.append(ShadertoyRuntimePass(
                id: passID.rawValue,
                name: passID.displayName,
                code: pass.code,
                channels: channels
            ))
        }
        return ShadertoyRuntimeConfig(
            version: 1,
            commonCode: draft.pass(.common).code,
            renderScale: min(1, max(0.25, draft.renderScale)),
            fpsLimit: min(120, max(1, draft.fpsLimit)),
            maxDimension: 4096,
            passes: runtimePasses
        )
    }

    private static func runtimeSource() throws -> String {
        guard let url = Bundle.main.url(forResource: "ShadertoyRuntime", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8) else {
            throw ShadertoyProjectError.runtimeMissing
        }
        return source
    }

    private static func html(config: ShadertoyRuntimeConfig,
                             runtime: String,
                             inlineRuntime: Bool) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let encodedConfig = try encoder.encode(config).base64EncodedString()
        let runtimeTag = inlineRuntime
            ? "<script>\(runtime)</script>"
            : #"<script src="runtime.js"></script>"#
        return """
        <!doctype html>
        <html lang="zh-CN">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width,initial-scale=1">
          <style>
            html, body { width:100%; height:100%; margin:0; overflow:hidden; background:#05070d; }
            #mirage-shader-canvas { display:block; width:100%; height:100%; }
            #mirage-shader-error {
              position:fixed; inset:18px; margin:0; padding:16px; overflow:auto;
              color:#ffd9d9; background:rgba(54,4,10,.92); border:1px solid rgba(255,90,90,.65);
              border-radius:10px; white-space:pre-wrap; font:12px/1.5 ui-monospace,monospace;
            }
          </style>
        </head>
        <body>
          <canvas id="mirage-shader-canvas"></canvas>
          <pre id="mirage-shader-error" hidden></pre>
          <script>window.__MIRAGE_SHADER_CONFIG_B64="\(encodedConfig)";</script>
          \(runtimeTag)
        </body>
        </html>
        """
    }

    private static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "bmp": return "image/bmp"
        default: return "image/png"
        }
    }

    private static func uniqueTextureName(for url: URL, used: inout Set<String>) -> String {
        let ext = url.pathExtension.lowercased()
        let originalStem = url.deletingPathExtension().lastPathComponent
        let stem = originalStem.replacingOccurrences(
            of: #"[^A-Za-z0-9_-]+"#,
            with: "_",
            options: .regularExpression
        ).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        let base = stem.isEmpty ? "texture" : stem
        var candidate = ext.isEmpty ? base : "\(base).\(ext)"
        var counter = 2
        while used.contains(candidate.lowercased()) {
            candidate = ext.isEmpty ? "\(base)_\(counter)" : "\(base)_\(counter).\(ext)"
            counter += 1
        }
        used.insert(candidate.lowercased())
        return candidate
    }

    private static func fallbackPreviewPNG() -> Data {
        let width = 640
        let height = 360
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return Data() }

        let colors = [
            CGColor(red: 0.04, green: 0.08, blue: 0.18, alpha: 1),
            CGColor(red: 0.19, green: 0.08, blue: 0.43, alpha: 1),
            CGColor(red: 0.02, green: 0.55, blue: 0.72, alpha: 1)
        ] as CFArray
        if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 0.58, 1]) {
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0, y: 0),
                end: CGPoint(x: width, y: height),
                options: []
            )
        }
        context.setStrokeColor(CGColor(red: 0.55, green: 0.9, blue: 1, alpha: 0.72))
        context.setLineWidth(5)
        context.move(to: CGPoint(x: 80, y: 105))
        context.addCurve(
            to: CGPoint(x: 560, y: 255),
            control1: CGPoint(x: 200, y: 330),
            control2: CGPoint(x: 430, y: 20)
        )
        context.strokePath()
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.82))
        for point in [CGPoint(x: 80, y: 105), CGPoint(x: 320, y: 180), CGPoint(x: 560, y: 255)] {
            context.fillEllipse(in: CGRect(x: point.x - 10, y: point.y - 10, width: 20, height: 20))
        }

        guard let image = context.makeImage() else { return Data() }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { return Data() }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return Data() }
        return data as Data
    }
}
