#!/usr/bin/env swift

import AppKit
import Foundation
import WebKit

struct RuntimeCase {
    let name: String
    let config: [String: Any]?
    let packageIndexURL: URL?
    let expectsError: Bool

    init(name: String, config: [String: Any], expectsError: Bool) {
        self.name = name
        self.config = config
        self.packageIndexURL = nil
        self.expectsError = expectsError
    }

    init(name: String, packageIndexURL: URL) {
        self.name = name
        self.config = nil
        self.packageIndexURL = packageIndexURL
        self.expectsError = false
    }
}

func channel(_ kind: String = "none",
             source: String? = nil,
             url: String? = nil,
             textureFormat: String? = nil,
             textureWidth: Int? = nil,
             textureHeight: Int? = nil,
             flipY: Bool = true) -> [String: Any] {
    var value: [String: Any] = [
        "kind": kind,
        "filter": "linear",
        "wrap": "repeat",
        "flipY": flipY
    ]
    if let source { value["source"] = source }
    if let url { value["url"] = url }
    if let textureFormat { value["textureFormat"] = textureFormat }
    if let textureWidth { value["textureWidth"] = textureWidth }
    if let textureHeight { value["textureHeight"] = textureHeight }
    return value
}

func pass(_ id: String,
                  code: String,
                  channels: [[String: Any]] = Array(repeating: channel(), count: 4)) -> [String: Any] {
    ["id": id, "name": id, "code": code, "channels": channels]
}

func config(common: String = "", passes: [[String: Any]]) -> [String: Any] {
    [
        "version": 1,
        "commonCode": common,
        "renderScale": 1.0,
        "fpsLimit": 60,
        "maxDimension": 2048,
        "passes": passes
    ]
}

final class RuntimeVerifier: NSObject, WKNavigationDelegate {
    private let runtime: String
    private let outputDirectory: URL
    private let cases: [RuntimeCase]
    private var caseIndex = 0
    private var deadline = Date()
    private var timer: Timer?
    private var webView: WKWebView!
    private var window: NSWindow!

    init(runtime: String, outputDirectory: URL, cases: [RuntimeCase]) {
        self.runtime = runtime
        self.outputDirectory = outputDirectory
        self.cases = cases
    }

    func start() {
        try? FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
        let webConfiguration = WKWebViewConfiguration()
        webConfiguration.websiteDataStore = .nonPersistent()
        webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 960, height: 540),
            configuration: webConfiguration
        )
        webView.navigationDelegate = self
        window = NSWindow(
            contentRect: webView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = webView
        window.setFrameOrigin(NSPoint(x: 40, y: 40))
        window.orderFrontRegardless()
        runCurrentCase()
    }

    private func runCurrentCase() {
        guard caseIndex < cases.count else {
            print("PASS: all \(cases.count) Shadertoy runtime cases")
            NSApplication.shared.terminate(nil)
            return
        }
        let current = cases[caseIndex]
        do {
            if let packageIndexURL = current.packageIndexURL {
                deadline = Date().addingTimeInterval(15)
                print("RUN: \(current.name)")
                webView.loadFileURL(
                    packageIndexURL,
                    allowingReadAccessTo: packageIndexURL.deletingLastPathComponent()
                )
                return
            }
            guard let caseConfig = current.config else {
                fail("missing configuration for \(current.name)")
                return
            }
            let json = try JSONSerialization.data(withJSONObject: caseConfig, options: [.sortedKeys])
            let encoded = json.base64EncodedString()
            let html = """
            <!doctype html><html><head><meta charset="utf-8"><style>
            html,body{margin:0;width:100%;height:100%;overflow:hidden;background:#000}
            canvas{display:block;width:100%;height:100%}
            pre{position:fixed;inset:10px;color:#fff;background:#400;white-space:pre-wrap}
            </style></head><body>
            <canvas id="mirage-shader-canvas"></canvas><pre id="mirage-shader-error" hidden></pre>
            <script>window.__MIRAGE_SHADER_CONFIG_B64="\(encoded)";</script>
            <script>\(runtime)</script></body></html>
            """
            deadline = Date().addingTimeInterval(15)
            print("RUN: \(current.name)")
            webView.loadHTMLString(html, baseURL: nil)
        } catch {
            fail("unable to prepare \(current.name): \(error)")
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            self?.pollStatus()
        }
    }

    private func pollStatus() {
        if Date() > deadline {
            fail("timeout waiting for \(cases[caseIndex].name)")
            return
        }
        webView.evaluateJavaScript(
            "JSON.stringify({status:document.documentElement.dataset.mirageShaderStatus||'',message:document.documentElement.dataset.mirageShaderMessage||''})"
        ) { [weak self] value, error in
            guard let self, error == nil,
                  let text = value as? String,
                  let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                  let status = object["status"], !status.isEmpty else { return }
            self.finishCurrent(status: status, message: object["message"] ?? "")
        }
    }

    private func finishCurrent(status: String, message: String) {
        timer?.invalidate()
        timer = nil
        let current = cases[caseIndex]
        if current.expectsError {
            guard status == "error" else {
                fail("\(current.name) expected an error, got \(status): \(message)")
                return
            }
            print("PASS: \(current.name) returned compile error")
            advance()
            return
        }
        guard status == "ready" else {
            fail("\(current.name) failed: \(message)")
            return
        }

        let snapshot = WKSnapshotConfiguration()
        snapshot.afterScreenUpdates = true
        webView.takeSnapshot(with: snapshot) { [weak self] image, error in
            guard let self, let image,
                  let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else {
                self?.fail("snapshot failed for \(current.name): \(error?.localizedDescription ?? "unknown error")")
                return
            }
            let output = self.outputDirectory.appendingPathComponent("\(current.name).png")
            do {
                try png.write(to: output, options: .atomic)
                print("PASS: \(current.name) rendered -> \(output.path)")
                self.advance()
            } catch {
                self.fail("unable to write snapshot: \(error)")
            }
        }
    }

    private func advance() {
        caseIndex += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.runCurrentCase()
        }
    }

    private func fail(_ message: String) {
        timer?.invalidate()
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    fputs("usage: verify_shadertoy_runtime.swift <runtime.js> <output-directory>\n", stderr)
    exit(2)
}

let runtimeURL = URL(fileURLWithPath: arguments[1])
let outputURL = URL(fileURLWithPath: arguments[2], isDirectory: true)
let runtime = try String(contentsOf: runtimeURL, encoding: .utf8)

let starter = RuntimeCase(
    name: "single-pass",
    config: config(
        common: "#version 300 es\n#define TINT vec3(0.2, 0.55, 1.0)",
        passes: [pass("image", code: """
        void mainImage(out vec4 fragColor, in vec2 fragCoord) {
            vec2 uv = fragCoord / iResolution.xy;
            fragColor = vec4(mix(TINT, vec3(1.0, 0.15, 0.4), uv.x) * (0.7 + 0.3 * sin(iTime + uv.y * 5.0)), 1.0);
        }
        """)]
    ),
    expectsError: false
)

var feedbackChannels = Array(repeating: channel(), count: 4)
feedbackChannels[0] = channel("buffer", source: "bufferA")
var imageChannels = Array(repeating: channel(), count: 4)
imageChannels[0] = channel("buffer", source: "bufferA")
let feedback = RuntimeCase(
    name: "buffer-feedback",
    config: config(passes: [
        pass("bufferA", code: """
        void mainImage(out vec4 fragColor, in vec2 fragCoord) {
            vec2 uv = fragCoord / iResolution.xy;
            vec3 previous = texture(iChannel0, uv).rgb;
            vec3 target = vec3(uv, 0.5 + 0.5 * sin(iTime));
            fragColor = vec4(mix(previous, target, 0.12), 1.0);
        }
        """, channels: feedbackChannels),
        pass("image", code: """
        void mainImage(out vec4 fragColor, in vec2 fragCoord) {
            fragColor = texture(iChannel0, fragCoord / iResolution.xy);
        }
        """, channels: imageChannels)
    ]),
    expectsError: false
)

let invalid = RuntimeCase(
    name: "compile-error",
    config: config(passes: [pass("image", code: """
    void mainImage(out vec4 fragColor, in vec2 fragCoord) {
        fragColor = vec4(thisSymbolDoesNotExist, 1.0);
    }
    """)]),
    expectsError: true
)

let halfFloatValues: [Float16] = [
    4, 0, 0, 1,   0, 2, 0, 1,
    0, 0, 3, 1,   1, 1, 1, 1
]
let halfFloatData = halfFloatValues.withUnsafeBytes { Data($0) }
let halfFloatURL = "data:application/x-mirage-rgba16f;base64,\(halfFloatData.base64EncodedString())"
var halfFloatChannels = Array(repeating: channel(), count: 4)
halfFloatChannels[0] = channel(
    "texture",
    url: halfFloatURL,
    textureFormat: "rgba16f",
    textureWidth: 2,
    textureHeight: 2,
    flipY: false
)
let halfFloatTexture = RuntimeCase(
    name: "rgba16f-texture",
    config: config(passes: [pass("image", code: """
    void mainImage(out vec4 fragColor, in vec2 fragCoord) {
        vec3 hdr = texture(iChannel0, fragCoord / iResolution.xy).rgb;
        fragColor = vec4(hdr / (1.0 + hdr), 1.0);
    }
    """, channels: halfFloatChannels)]),
    expectsError: false
)

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
var verificationCases = [starter, feedback, halfFloatTexture, invalid]
if arguments.count >= 4 {
    let packageDirectory = URL(fileURLWithPath: arguments[3], isDirectory: true)
    verificationCases.append(RuntimeCase(
        name: "saved-package",
        packageIndexURL: packageDirectory.appendingPathComponent("index.html")
    ))
}

let verifier = RuntimeVerifier(
    runtime: runtime,
    outputDirectory: outputURL,
    cases: verificationCases
)
verifier.start()
application.run()
