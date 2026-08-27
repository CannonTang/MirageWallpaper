//
//  Mirage Wallpaper
//
//  Offline Shadertoy capture for screen saver and dynamic lock playback.
//

import AppKit
import AVFoundation
import CryptoKit
import Foundation
import WebKit

enum ShadertoyLoopVideoExportError: LocalizedError {
    case unsupportedWallpaper
    case pageLoadFailed(String)
    case shaderFailed(String)
    case captureUnavailable
    case snapshotFailed
    case encoderFailed(String)
    case outputInvalid

    var errorDescription: String? {
        switch self {
        case .unsupportedWallpaper:
            return L("当前壁纸不是可编辑的 Mirage Shader 壁纸")
        case .pageLoadFailed(let message):
            return L("Shader 录制页面载入失败：%@", message)
        case .shaderFailed(let message):
            return L("Shader 编译或渲染失败：%@", message)
        case .captureUnavailable:
            return L("当前系统无法启动 Shader 离线录制")
        case .snapshotFailed:
            return L("无法读取 Shader 渲染帧")
        case .encoderFailed(let message):
            return L("循环视频编码失败：%@", message)
        case .outputInvalid:
            return L("循环视频生成后无法读取")
        }
    }
}

/// Progress is intentionally non-modal. A 120–240 frame WebGL capture can take
/// several seconds, but the rest of Mirage remains usable throughout.
final class ShaderLoopExportProgressModel: ObservableObject {
    static let shared = ShaderLoopExportProgressModel()

    struct Job: Equatable {
        let title: String
        var detail: String
        var progress: Double
    }

    @Published private(set) var job: Job?

    private init() {}

    func begin(title: String) {
        job = Job(title: title, detail: L("正在准备 Shader"), progress: 0)
    }

    func update(detail: String, progress: Double) {
        guard var current = job else { return }
        current.detail = detail
        current.progress = min(max(progress, 0), 1)
        job = current
    }

    func finish() {
        job = nil
    }
}

@MainActor
final class ShadertoyLoopVideoExporter: NSObject, WKNavigationDelegate {
    static let shared = ShadertoyLoopVideoExporter()

    private struct ExportSettings {
        let width: Int
        let height: Int
        let fps: Int
        let duration: Double

        var frameCount: Int { max(2, Int((duration * Double(fps)).rounded())) }
        var signature: String { "v3|\(width)x\(height)|\(fps)|\(duration)" }
    }

    private let fm = FileManager.default
    private var navigationContinuation: CheckedContinuation<Void, Error>?

    func videoWallpaper(for wallpaper: WEWallpaper) async throws -> WEWallpaper {
        guard ShadertoyPackageBuilder.canEdit(wallpaper) else {
            throw ShadertoyLoopVideoExportError.unsupportedWallpaper
        }

        let progress = ShaderLoopExportProgressModel.shared
        progress.begin(title: wallpaper.project.title)
        defer { progress.finish() }

        let draft = try ShadertoyPackageBuilder.loadDraft(from: wallpaper)
        let settings = exportSettings(for: draft)
        let fingerprint = try sourceFingerprint(for: wallpaper, settings: settings)
        let destination = cacheDirectory(for: wallpaper)

        if let cached = cachedWallpaper(at: destination, fingerprint: fingerprint) {
            progress.update(detail: L("已使用缓存的循环视频"), progress: 1)
            return cached
        }

        let workingRoot = fm.temporaryDirectory.appending(
            path: "MirageShaderLoop-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let capturePackage = workingRoot.appending(path: "source", directoryHint: .isDirectory)
        let outputPackage = workingRoot.appending(path: "output", directoryHint: .isDirectory)
        defer { try? fm.removeItem(at: workingRoot) }

        try fm.createDirectory(at: workingRoot, withIntermediateDirectories: true)
        try ShadertoyPackageBuilder.writePackage(draft, to: capturePackage, previewPNG: nil)
        try fm.createDirectory(at: outputPackage, withIntermediateDirectories: false)

        let movieURL = outputPackage.appending(path: "loop.mp4")
        let firstFrame = try await renderMovie(
            sourceURL: capturePackage.appending(path: "index.html"),
            readAccessURL: capturePackage,
            outputURL: movieURL,
            settings: settings,
            progress: progress
        )

        let previewName = try writePreview(
            for: wallpaper,
            fallback: firstFrame,
            to: outputPackage
        )
        let project = WEProject(
            approved: true,
            author: wallpaper.project.author,
            contentrating: wallpaper.project.contentrating ?? "Everyone",
            description: L("由 Mirage 从 Shader 离线录制的无缝循环视频。"),
            file: "loop.mp4",
            preview: previewName,
            tags: ["Shader", "Video", "Generated"],
            title: wallpaper.project.title,
            type: "video",
            version: 1
        )
        let projectData = try JSONEncoder().encode(project)
        try projectData.write(to: outputPackage.appending(path: "project.json"), options: .atomic)
        try Data(fingerprint.utf8).write(
            to: outputPackage.appending(path: "source-fingerprint.txt"),
            options: .atomic
        )

        progress.update(detail: L("正在安装循环视频"), progress: 0.98)
        try fm.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.moveItem(at: outputPackage, to: destination)

        let result = WEWallpaper.load(from: destination)
        guard result.isValid, fm.fileExists(atPath: result.resolvedEntryURL.path) else {
            throw ShadertoyLoopVideoExportError.outputInvalid
        }
        progress.update(detail: L("循环视频已生成"), progress: 1)
        return result
    }

    private func exportSettings(for draft: ShadertoyProjectDraft) -> ExportSettings {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let pointSize = screen?.frame.size ?? CGSize(width: 16, height: 9)
        let scale = screen?.backingScaleFactor ?? 1
        let nativeLongEdge = max(pointSize.width, pointSize.height) * scale
        let scaledLongEdge = nativeLongEdge * min(max(draft.renderScale, 0.25), 1)
        let longEdge = Int(min(Double(min(draft.maxDimension, 1920)), max(640, scaledLongEdge)))
        let aspect = max(0.5, min(3, pointSize.width / max(1, pointSize.height)))

        var width: Int
        var height: Int
        if aspect >= 1 {
            width = longEdge
            height = Int((Double(longEdge) / aspect).rounded())
        } else {
            height = longEdge
            width = Int((Double(longEdge) * aspect).rounded())
        }
        width = max(2, width - width % 2)
        height = max(2, height - height % 2)
        return ExportSettings(
            width: width,
            height: height,
            fps: min(30, max(15, draft.fpsLimit)),
            duration: 8
        )
    }

    private func cacheDirectory(for wallpaper: WEWallpaper) -> URL {
        let sourcePath = wallpaper.wallpaperDirectory.standardizedFileURL.path
        let digest = SHA256.hash(data: Data(sourcePath.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Mirage/Generated/ShaderLoops", directoryHint: .isDirectory)
            .appending(path: digest, directoryHint: .isDirectory)
    }

    private func sourceFingerprint(for wallpaper: WEWallpaper,
                                   settings: ExportSettings) throws -> String {
        var hasher = SHA256()
        hasher.update(data: Data(settings.signature.utf8))
        let root = wallpaper.wallpaperDirectory.standardizedFileURL
        let keys: Set<URLResourceKey> = [.isRegularFileKey]
        let files = (fm.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )?.allObjects as? [URL] ?? [])
            .filter { (try? $0.resourceValues(forKeys: keys).isRegularFile) == true }
            .filter { $0.lastPathComponent != "preview.png" && $0.lastPathComponent != "preview.jpg" }
            .sorted { $0.path < $1.path }

        for file in files {
            let relative = String(file.path.dropFirst(root.path.count))
            hasher.update(data: Data(relative.utf8))
            hasher.update(data: try Data(contentsOf: file, options: [.mappedIfSafe]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func cachedWallpaper(at directory: URL, fingerprint: String) -> WEWallpaper? {
        guard let stored = try? String(
            contentsOf: directory.appending(path: "source-fingerprint.txt"),
            encoding: .utf8
        ), stored == fingerprint else { return nil }
        let wallpaper = WEWallpaper.load(from: directory)
        return wallpaper.isValid && fm.fileExists(atPath: wallpaper.resolvedEntryURL.path)
            ? wallpaper
            : nil
    }

    private func renderMovie(sourceURL: URL,
                             readAccessURL: URL,
                             outputURL: URL,
                             settings: ExportSettings,
                             progress: ShaderLoopExportProgressModel) async throws -> NSImage {
        let configuration = WKWebViewConfiguration()
        let webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: settings.width, height: settings.height),
            configuration: configuration
        )
        webView.navigationDelegate = self

        // WKWebView only guarantees a live backing store while attached to a
        // window. Keep a nearly transparent panel far offscreen during capture.
        let panel = NSPanel(
            contentRect: webView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        panel.alphaValue = 0.01
        panel.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        panel.contentView = webView
        panel.orderFrontRegardless()
        defer {
            webView.navigationDelegate = nil
            panel.close()
        }

        progress.update(detail: L("正在编译 Shader"), progress: 0.02)
        try await load(webView, fileURL: sourceURL, readAccessURL: readAccessURL)
        try await waitForShaderReady(in: webView)

        let beginScript = "window.__mirageShaderCapture && window.__mirageShaderCapture.begin(\(settings.width), \(settings.height))"
        guard let begin = try await webView.evaluateJavaScript(beginScript) as? [String: Any],
              (begin["failed"] as? Bool) != true else {
            throw ShadertoyLoopVideoExportError.captureUnavailable
        }

        let writer = try makeWriter(outputURL: outputURL, settings: settings)
        let input = writer.input
        let adaptor = writer.adaptor
        guard writer.writer.startWriting() else {
            throw ShadertoyLoopVideoExportError.encoderFailed(
                writer.writer.error?.localizedDescription ?? L("无法启动编码器")
            )
        }
        writer.writer.startSession(atSourceTime: .zero)
        var completed = false
        defer {
            if !completed { writer.writer.cancelWriting() }
        }

        var firstFrame: NSImage?
        var firstCGImage: CGImage?
        let fadeFrames = min(settings.fps, max(2, settings.frameCount / 4))
        let snapshotConfiguration = WKSnapshotConfiguration()
        snapshotConfiguration.rect = webView.bounds
        snapshotConfiguration.snapshotWidth = NSNumber(value: settings.width)

        for frameIndex in 0..<settings.frameCount {
            try Task.checkCancellation()
            let phase = Double(frameIndex) / Double(settings.frameCount)
            // A periodic forward/backward time path makes time-based shaders
            // naturally return to their opening state. The final crossfade
            // below also closes the seam for feedback buffers.
            let shaderTime = (settings.duration / 2) * (0.5 - 0.5 * cos(2 * .pi * phase))
            let script = "window.__mirageShaderCapture.renderFrame(\(shaderTime), \(1.0 / Double(settings.fps)), \(frameIndex), \(settings.fps))"
            guard let status = try await webView.evaluateJavaScript(script) as? [String: Any],
                  (status["failed"] as? Bool) != true else {
                throw ShadertoyLoopVideoExportError.shaderFailed(L("纹理载入失败"))
            }
            let image = try await webView.takeSnapshot(configuration: snapshotConfiguration)
            guard let currentCG = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                throw ShadertoyLoopVideoExportError.snapshotFailed
            }
            if firstFrame == nil {
                firstFrame = image
                firstCGImage = currentCG
            }

            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            let fadeStart = settings.frameCount - fadeFrames
            let fade: CGFloat
            if frameIndex >= fadeStart {
                fade = CGFloat(frameIndex - fadeStart + 1) / CGFloat(fadeFrames)
            } else {
                fade = 0
            }
            let pixelBuffer = try makePixelBuffer(
                image: currentCG,
                overlay: firstCGImage,
                overlayAlpha: fade,
                adaptor: adaptor,
                settings: settings
            )
            let time = CMTime(value: CMTimeValue(frameIndex), timescale: CMTimeScale(settings.fps))
            guard adaptor.append(pixelBuffer, withPresentationTime: time) else {
                throw ShadertoyLoopVideoExportError.encoderFailed(
                    writer.writer.error?.localizedDescription ?? L("写入视频帧失败")
                )
            }
            progress.update(
                detail: L("正在录制循环视频 · %d / %d 帧", frameIndex + 1, settings.frameCount),
                progress: 0.05 + 0.88 * Double(frameIndex + 1) / Double(settings.frameCount)
            )
        }

        input.markAsFinished()
        await withCheckedContinuation { continuation in
            writer.writer.finishWriting { continuation.resume() }
        }
        guard writer.writer.status == .completed else {
            throw ShadertoyLoopVideoExportError.encoderFailed(
                writer.writer.error?.localizedDescription ?? L("编码器未完成")
            )
        }
        completed = true
        guard let firstFrame else { throw ShadertoyLoopVideoExportError.snapshotFailed }
        return firstFrame
    }

    private struct WriterBundle {
        let writer: AVAssetWriter
        let input: AVAssetWriterInput
        let adaptor: AVAssetWriterInputPixelBufferAdaptor
    }

    private func makeWriter(outputURL: URL, settings: ExportSettings) throws -> WriterBundle {
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        } catch {
            throw ShadertoyLoopVideoExportError.encoderFailed(error.localizedDescription)
        }
        let pixelsPerSecond = settings.width * settings.height * settings.fps
        let bitrate = min(12_000_000, max(2_000_000, pixelsPerSecond / 4))
        let outputSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: settings.width,
            AVVideoHeightKey: settings.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: settings.fps,
                AVVideoMaxKeyFrameIntervalKey: settings.fps * 2,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
        input.expectsMediaDataInRealTime = false
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: settings.width,
            kCVPixelBufferHeightKey as String: settings.height,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: attributes
        )
        guard writer.canAdd(input) else {
            throw ShadertoyLoopVideoExportError.encoderFailed(L("编码器不接受视频轨道"))
        }
        writer.add(input)
        return WriterBundle(writer: writer, input: input, adaptor: adaptor)
    }

    private func makePixelBuffer(image: CGImage,
                                 overlay: CGImage?,
                                 overlayAlpha: CGFloat,
                                 adaptor: AVAssetWriterInputPixelBufferAdaptor,
                                 settings: ExportSettings) throws -> CVPixelBuffer {
        guard let pool = adaptor.pixelBufferPool else {
            throw ShadertoyLoopVideoExportError.encoderFailed(L("像素缓冲池不可用"))
        }
        var optionalBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &optionalBuffer) == kCVReturnSuccess,
              let buffer = optionalBuffer else {
            throw ShadertoyLoopVideoExportError.encoderFailed(L("无法分配视频帧"))
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: base,
                width: settings.width,
                height: settings.height,
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: colorSpace,
                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
                    | CGImageAlphaInfo.premultipliedFirst.rawValue
              ) else {
            throw ShadertoyLoopVideoExportError.encoderFailed(L("无法创建视频绘图缓冲区"))
        }
        let rect = CGRect(x: 0, y: 0, width: settings.width, height: settings.height)
        context.clear(rect)
        context.interpolationQuality = .high
        context.draw(image, in: rect)
        if let overlay, overlayAlpha > 0 {
            context.setAlpha(min(1, max(0, overlayAlpha)))
            context.draw(overlay, in: rect)
        }
        return buffer
    }

    private func writePreview(for wallpaper: WEWallpaper,
                              fallback: NSImage,
                              to directory: URL) throws -> String {
        if fm.fileExists(atPath: wallpaper.previewURL.path),
           wallpaper.previewURL.hasDirectoryPath == false {
            let ext = wallpaper.previewURL.pathExtension.isEmpty
                ? "png"
                : wallpaper.previewURL.pathExtension.lowercased()
            let name = "preview.\(ext)"
            try fm.copyItem(at: wallpaper.previewURL, to: directory.appending(path: name))
            return name
        }
        guard let cgImage = fallback.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let jpeg = NSBitmapImageRep(cgImage: cgImage).representation(
                using: .jpeg,
                properties: [.compressionFactor: 0.88]
              ) else { throw ShadertoyLoopVideoExportError.snapshotFailed }
        let name = "preview.jpg"
        try jpeg.write(to: directory.appending(path: name), options: .atomic)
        return name
    }

    private func load(_ webView: WKWebView,
                      fileURL: URL,
                      readAccessURL: URL) async throws {
        try await withCheckedThrowingContinuation { continuation in
            navigationContinuation = continuation
            webView.loadFileURL(fileURL, allowingReadAccessTo: readAccessURL)
        }
    }

    private func waitForShaderReady(in webView: WKWebView) async throws {
        for _ in 0..<240 {
            let script = "JSON.stringify({status:document.documentElement.dataset.mirageShaderStatus||'',message:document.documentElement.dataset.mirageShaderMessage||'',capture:!!window.__mirageShaderCapture})"
            if let json = try await webView.evaluateJavaScript(script) as? String,
               let data = json.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let status = object["status"] as? String ?? ""
                let message = object["message"] as? String ?? ""
                if status == "error" {
                    throw ShadertoyLoopVideoExportError.shaderFailed(message)
                }
                if status == "ready", object["capture"] as? Bool == true { return }
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw ShadertoyLoopVideoExportError.shaderFailed(L("等待编译完成超时"))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        navigationContinuation?.resume()
        navigationContinuation = nil
    }

    func webView(_ webView: WKWebView,
                 didFail navigation: WKNavigation!,
                 withError error: Error) {
        navigationContinuation?.resume(
            throwing: ShadertoyLoopVideoExportError.pageLoadFailed(error.localizedDescription)
        )
        navigationContinuation = nil
    }

    func webView(_ webView: WKWebView,
                 didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        navigationContinuation?.resume(
            throwing: ShadertoyLoopVideoExportError.pageLoadFailed(error.localizedDescription)
        )
        navigationContinuation = nil
    }
}
