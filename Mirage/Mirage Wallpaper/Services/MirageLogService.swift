//
//  Mirage Wallpaper
//
//  Copyright © 2026 王孝慈. All rights reserved.
//

import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

final class MirageLogService: ObservableObject {
    static let shared = MirageLogService()

    @Published private(set) var visibleText = ""

    private let queue = DispatchQueue(label: "cn.laobamac.Mirage.logging", qos: .utility)
    private let maximumVisibleCharacters = 1_500_000
    private var sessionURL: URL?
    private var sessionHandle: FileHandle?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var originalStdout: FileHandle?
    private var originalStderr: FileHandle?
    private var automaticSaveURL: URL?
    private var started = false

    private init() {}

    func start() {
        guard !started else { return }
        started = true

        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Mirage/Logs", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        removeExpiredSessions(in: directory)
        let url = directory.appending(path: "Session-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        sessionURL = url
        sessionHandle = try? FileHandle(forWritingTo: url)

        captureStandardStreams()
        append("Mirage logging session started", source: "app")
    }

    func append(_ message: String, source: String = "app") {
        guard started else { return }
        let sanitized = Self.redact(message)
        guard !sanitized.isEmpty else { return }
        queue.async { [weak self] in
            guard let self else { return }
            let stamp = Self.timestamp()
            let normalized = sanitized.hasSuffix("\n") ? sanitized : sanitized + "\n"
            let line = "[\(stamp)] [\(source)] \(normalized)"
            if let data = line.data(using: .utf8) {
                try? self.sessionHandle?.write(contentsOf: data)
            }
            DispatchQueue.main.async {
                self.visibleText.append(line)
                if self.visibleText.count > self.maximumVisibleCharacters {
                    self.visibleText.removeFirst(self.visibleText.count - self.maximumVisibleCharacters)
                }
            }
        }
    }

    func export(to url: URL) throws {
        try queue.sync {
            try sessionHandle?.synchronize()
            guard let sessionURL else { return }
            let data = try Data(contentsOf: sessionURL)
            try data.write(to: url, options: .atomic)
        }
    }

    @discardableResult
    func saveAutomatically() -> URL? {
        queue.sync {
            do {
                try sessionHandle?.synchronize()
                guard let sessionURL else { return nil }
                let destination: URL
                if let automaticSaveURL {
                    destination = automaticSaveURL
                } else {
                    let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
                    let directory = desktop.appending(path: "MirageLogs", directoryHint: .isDirectory)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let base = "Mirage-\(Self.fileTimestamp())"
                    var candidate = directory.appending(path: "\(base).log")
                    var suffix = 2
                    while FileManager.default.fileExists(atPath: candidate.path) {
                        candidate = directory.appending(path: "\(base)-\(suffix).log")
                        suffix += 1
                    }
                    automaticSaveURL = candidate
                    destination = candidate
                }
                let data = try Data(contentsOf: sessionURL)
                try data.write(to: destination, options: .atomic)
                return destination
            } catch {
                return nil
            }
        }
    }

    private func captureStandardStreams() {
        fflush(nil)
        let stdoutCopy = dup(STDOUT_FILENO)
        let stderrCopy = dup(STDERR_FILENO)
        if stdoutCopy >= 0 {
            originalStdout = FileHandle(fileDescriptor: stdoutCopy, closeOnDealloc: true)
        }
        if stderrCopy >= 0 {
            originalStderr = FileHandle(fileDescriptor: stderrCopy, closeOnDealloc: true)
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe
        dup2(stdoutPipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        dup2(stderrPipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self?.consume(data, source: "stdout", original: self?.originalStdout)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self?.consume(data, source: "stderr", original: self?.originalStderr)
        }
    }

    private func removeExpiredSessions(in directory: URL) {
        guard let expiration = Calendar.current.date(byAdding: .day, value: -7, to: Date()),
              let urls = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
              ) else { return }
        for url in urls where url.lastPathComponent.hasPrefix("Session-") {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                  let modificationDate = values.contentModificationDate,
                  modificationDate < expiration else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func consume(_ data: Data, source: String, original: FileHandle?) {
        try? original?.write(contentsOf: data)
        guard let text = String(data: data, encoding: .utf8) else { return }
        append(text, source: source)
    }

    private static func redact(_ value: String) -> String {
        var result = value
        let replacements = [
            ("(?i)(key|api[_-]?key|token|access[_-]?token|refresh[_-]?token|password|passwd|steamguard|guard[_-]?code)(\\s*[=:]\\s*)[^\\s&\\\"']+", "$1$2<redacted>"),
            ("(?i)([?&](?:key|api[_-]?key|token|access_token|password)=)[^&\\s]+", "$1<redacted>"),
            ("(?<![A-Fa-f0-9])[A-Fa-f0-9]{32}(?![A-Fa-f0-9])", "<redacted>")
        ]
        for (pattern, template) in replacements {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            result = expression.stringByReplacingMatches(in: result, range: range, withTemplate: template)
        }
        return result
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter.string(from: Date())
    }

    private static func fileTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter.string(from: Date())
    }
}

final class DeveloperLogWindowController: NSWindowController, NSWindowDelegate {
    init() {
        let view = DeveloperLogView(service: MirageLogService.shared)
        let controller = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: controller)
        window.setContentSize(NSSize(width: 820, height: 520))
        window.contentMinSize = NSSize(width: 560, height: 320)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = L("Mirage 开发日志")
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("DeveloperLogWindow")
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func windowWillClose(_ notification: Notification) {
        MirageLogService.shared.saveAutomatically()
    }

    func refreshLocalization() {
        window?.title = L("Mirage 开发日志")
    }
}

private struct DeveloperLogView: View {
    @ObservedObject var service: MirageLogService

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView([.horizontal, .vertical]) {
                    Text(service.visibleText)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(10)
                    Color.clear.frame(height: 1).id("bottom")
                }
                .onChange(of: service.visibleText) { _, _ in
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            Divider()
            HStack {
                Text(L("实时日志"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L("存储日志…")) {
                    let panel = NSSavePanel()
                    panel.allowedContentTypes = [.plainText]
                    panel.nameFieldStringValue = "Mirage-\(Self.fileTimestamp()).log"
                    panel.begin { response in
                        guard response == .OK, let url = panel.url else { return }
                        try? service.export(to: url)
                    }
                }
            }
            .padding(10)
        }
    }

    private static func fileTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter.string(from: Date())
    }
}
