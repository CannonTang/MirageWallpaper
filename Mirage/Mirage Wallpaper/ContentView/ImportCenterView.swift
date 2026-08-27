//
//  Mirage Wallpaper
//
//  Copyright © 2026 王孝慈. All rights reserved.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum ImportCenterRoute {
    case home
    case video(URL)
    case workshopMigration(URL)
}

struct ImportCenterView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var contentViewModel: ContentViewModel
    @ObservedObject var wallpaperViewModel: WallpaperViewModel

    @State private var route: ImportCenterRoute = .home
    @State private var isDropTargeted = false
    @AppStorage("LastWallpaperImportDirectory") private var lastImportDirectory = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                switch route {
                case .home:
                    home
                case .video(let url):
                    VideoImportView(
                        videoURL: url,
                        contentViewModel: contentViewModel,
                        wallpaperViewModel: wallpaperViewModel,
                        onBack: { route = .home },
                        onComplete: { dismiss() }
                    )
                case .workshopMigration(let url):
                    WorkshopMigrationView(
                        selectedURL: url,
                        contentViewModel: contentViewModel,
                        onBack: { route = .home },
                        onComplete: { dismiss() }
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if case .home = route {
                Image(systemName: "plus.rectangle.on.folder")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
            } else {
                Button {
                    route = .home
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
                .help("返回导入中心")
            }
            Text("添加壁纸")
                .font(.title2.bold())
            Spacer()
            Button("关闭") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.bar)
    }

    private var home: some View {
        VStack(spacing: 20) {
            VStack(spacing: 6) {
                Text("选择一种添加方式")
                    .font(.title.bold())
                Text("本地功能无需 Steam 账号、API Key 或网络连接。")
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 14) {
                ImportChoiceCard(
                    title: "添加本地视频",
                    detail: "导入 MP4、MOV 或 M4V，并自动循环播放。",
                    systemImage: "play.rectangle.fill",
                    tint: .blue,
                    action: chooseVideo
                )
                ImportChoiceCard(
                    title: "导入壁纸文件夹",
                    detail: "复制包含 project.json 的场景、网页或视频壁纸。",
                    systemImage: "folder.badge.plus",
                    tint: .purple,
                    action: chooseWallpaperFolders
                )
                ImportChoiceCard(
                    title: "从 Windows 迁移",
                    detail: "扫描 Wallpaper Engine 的 431960 目录并保留工坊 ID。",
                    systemImage: "arrow.right.doc.on.clipboard",
                    tint: .orange,
                    action: chooseWorkshopDirectory
                )
            }

            VStack(spacing: 8) {
                Image(systemName: isDropTargeted ? "arrow.down.circle.fill" : "arrow.down.circle")
                    .font(.system(size: 28))
                    .foregroundStyle(isDropTargeted ? Color.accentColor : Color.secondary)
                Text("也可以把视频或壁纸文件夹拖到这里")
                    .font(.callout)
                if !lastImportDirectory.isEmpty {
                    Text(L("上次位置：%@", lastImportDirectory))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 105)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.accentColor.opacity(isDropTargeted ? 0.10 : 0.035))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.25),
                        style: StrokeStyle(lineWidth: 1, dash: [6])
                    )
            }
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTargeted) { providers in
                handleDrop(providers)
            }

            Spacer(minLength: 0)
        }
        .padding(24)
    }

    private func configuredPanel() -> NSOpenPanel {
        let panel = NSOpenPanel()
        if !lastImportDirectory.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: lastImportDirectory, isDirectory: true)
        }
        return panel
    }

    private func chooseVideo() {
        let panel = configuredPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        panel.prompt = L("选择视频")
        panel.message = L("选择要循环播放的 MP4、MOV 或 M4V 视频")
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            remember(url)
            route = .video(url)
        }
    }

    private func chooseWallpaperFolders() {
        let panel = configuredPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = L("导入")
        panel.message = L("选择一个或多个包含 project.json 的壁纸文件夹")
        panel.begin { response in
            guard response == .OK, !panel.urls.isEmpty else { return }
            remember(panel.urls[0])
            contentViewModel.importWallpapers(urls: panel.urls)
            dismiss()
        }
    }

    private func chooseWorkshopDirectory() {
        let panel = configuredPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L("扫描")
        panel.message = L("选择 431960 文件夹，或包含它的 Wallpaper Engine / SteamLibrary 文件夹")
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            remember(url)
            route = .workshopMigration(url)
        }
    }

    private func remember(_ url: URL) {
        lastImportDirectory = url.hasDirectoryPath ? url.path : url.deletingLastPathComponent().path
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            let url: URL?
            if let data = item as? Data {
                url = URL(dataRepresentation: data, relativeTo: nil)
            } else if let value = item as? URL {
                url = value
            } else {
                url = nil
            }
            guard let url else { return }
            DispatchQueue.main.async {
                remember(url)
                let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                if isDirectory {
                    if WorkshopMigrationService.resolveWorkshopRoot(from: url) != nil {
                        route = .workshopMigration(url)
                    } else {
                        contentViewModel.importWallpapers(urls: [url])
                        dismiss()
                    }
                } else {
                    route = .video(url)
                }
            }
        }
        return true
    }
}

private struct ImportChoiceCard: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let systemImage: String
    let tint: Color
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 28))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                HStack {
                    Spacer()
                    Image(systemName: "arrow.right.circle.fill")
                        .foregroundStyle(tint)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 185, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(hovering ? tint.opacity(0.09) : Color.primary.opacity(0.035))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(hovering ? tint.opacity(0.5) : Color.secondary.opacity(0.18))
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct VideoImportView: View {
    let videoURL: URL
    @ObservedObject var contentViewModel: ContentViewModel
    @ObservedObject var wallpaperViewModel: WallpaperViewModel
    let onBack: () -> Void
    let onComplete: () -> Void

    @State private var title: String
    @State private var fillMode: FillMode = .cover
    @State private var volume = 1.0
    @State private var speed = 1.0
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var previewImage: NSImage?

    init(
        videoURL: URL,
        contentViewModel: ContentViewModel,
        wallpaperViewModel: WallpaperViewModel,
        onBack: @escaping () -> Void,
        onComplete: @escaping () -> Void
    ) {
        self.videoURL = videoURL
        self.contentViewModel = contentViewModel
        self.wallpaperViewModel = wallpaperViewModel
        self.onBack = onBack
        self.onComplete = onComplete
        _title = State(initialValue: videoURL.deletingPathExtension().lastPathComponent)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 20) {
                preview
                Form {
                    TextField("名称", text: $title)
                    LabeledContent("文件", value: videoURL.lastPathComponent)
                    LabeledContent("大小", value: formattedFileSize)
                    LabeledContent("循环播放") {
                        Label("始终循环", systemImage: "repeat")
                            .foregroundStyle(.secondary)
                    }
                    Picker("填充方式", selection: $fillMode) {
                        ForEach(FillMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    HStack {
                        Text("音量")
                        Slider(value: $volume, in: 0...1)
                        Text("\(Int(volume * 100))%")
                            .monospacedDigit()
                            .frame(width: 42)
                    }
                    Picker("播放速度", selection: $speed) {
                        Text("0.5×").tag(0.5)
                        Text("0.75×").tag(0.75)
                        Text("1×").tag(1.0)
                        Text("1.25×").tag(1.25)
                        Text("1.5×").tag(1.5)
                        Text("2×").tag(2.0)
                    }
                    LabeledContent("保存到") {
                        Text(WallpaperLibrary.shared.importedDirectory.path)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                }
                .formStyle(.grouped)
            }
            .padding(20)

            if let errorMessage {
                Label(errorMessage, systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
                    .padding(.horizontal, 20)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer(minLength: 0)
            Divider()
            HStack {
                Text("如果原视频无法由 macOS 解码，首次播放时会自动转换为 H.264。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("返回", action: onBack)
                    .disabled(isWorking)
                Button("仅导入") { importVideo(apply: false) }
                    .disabled(isWorking || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("导入并应用") { importVideo(apply: true) }
                    .buttonStyle(.borderedProminent)
                    .disabled(isWorking || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(20)
        }
        .onAppear(perform: loadPreview)
    }

    private var preview: some View {
        Group {
            if let previewImage {
                Image(nsImage: previewImage)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Color.secondary.opacity(0.08)
                    Image(systemName: "film")
                        .font(.system(size: 42))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 260, height: 160)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.2)) }
    }

    private var formattedFileSize: String {
        let size = (try? videoURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    private func loadPreview() {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let data = try? WallpaperLibrary.generateThumbnail(for: videoURL),
                  let image = NSImage(data: data) else { return }
            DispatchQueue.main.async { previewImage = image }
        }
    }

    private func importVideo(apply: Bool) {
        isWorking = true
        errorMessage = nil
        let selectedTitle = title
        let runtime = WallpaperRuntimeState(
            volume: Float(volume),
            speed: Float(speed),
            muted: false,
            fillMode: fillMode
        )
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let destination = try WallpaperLibrary.shared.importVideoFile(
                    at: videoURL,
                    title: selectedTitle
                )
                let wallpaper = WEWallpaper.load(from: destination)
                DispatchQueue.main.async {
                    WEWallpaper.invalidateSizeCache()
                    contentViewModel.refresh()
                    if apply, wallpaper.isValid {
                        wallpaperViewModel.applyImportedWallpaper(wallpaper, runtime: runtime)
                    }
                    isWorking = false
                    onComplete()
                }
            } catch {
                DispatchQueue.main.async {
                    isWorking = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

private enum WorkshopMigrationMode: String, CaseIterable, Identifiable {
    case copy
    case reference

    var id: Self { self }
    var title: String {
        switch self {
        case .copy: return L("复制到 Mirage")
        case .reference: return L("直接使用此目录")
        }
    }
}

private final class WorkshopMigrationViewModel: ObservableObject {
    @Published var isScanning = true
    @Published var scan: WorkshopMigrationScan?
    @Published var selectedIDs: Set<String> = []
    @Published var mode: WorkshopMigrationMode = .copy
    @Published var conflictPolicy: WorkshopMigrationConflictPolicy = .skip
    @Published var errorMessage: String?
    @Published var result: WorkshopMigrationResult?
    @Published var directlyConnected = false
    @Published var progress = 0.0
    @Published var progressLabel = ""
    @Published var isMigrating = false

    let selectedURL: URL
    private var cancellationToken: WorkshopMigrationCancellationToken?

    init(selectedURL: URL) {
        self.selectedURL = selectedURL
        startScan()
    }

    func startScan() {
        isScanning = true
        errorMessage = nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let scan = try WorkshopMigrationService.scan(selectedURL: selectedURL)
                DispatchQueue.main.async {
                    self.scan = scan
                    self.selectedIDs = scan.selectableIDs
                    self.isScanning = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = error.localizedDescription
                    self.isScanning = false
                }
            }
        }
    }

    func setSelected(_ selected: Bool, item: WorkshopMigrationItem) {
        guard !item.status.isBlocking else { return }
        guard let scan else { return }
        if selected {
            selectedIDs.insert(item.id)
            if let dependency = item.dependencyID,
               scan.items.contains(where: { $0.id == dependency && !$0.status.isBlocking }) {
                selectedIDs.insert(dependency)
            }
        } else {
            selectedIDs.remove(item.id)
            for preset in scan.items where preset.dependencyID == item.id {
                selectedIDs.remove(preset.id)
            }
        }
    }

    func selectAll() {
        selectedIDs = scan?.selectableIDs ?? []
    }

    func selectNone() {
        selectedIDs.removeAll()
    }

    func migrate(contentViewModel: ContentViewModel) {
        guard let scan else { return }
        if mode == .reference {
            WallpaperLibrary.shared.setWorkshopDirectory(scan.sourceRoot)
            contentViewModel.refresh()
            directlyConnected = true
            return
        }

        isMigrating = true
        progress = 0
        errorMessage = nil
        let ids = selectedIDs
        let policy = conflictPolicy
        let token = WorkshopMigrationCancellationToken()
        cancellationToken = token
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = WorkshopMigrationService.migrate(
                scan: scan,
                selectedIDs: ids,
                conflictPolicy: policy,
                cancellationToken: token
            ) { completed, total, id in
                DispatchQueue.main.async {
                    self?.progress = total == 0 ? 0 : Double(completed) / Double(total)
                    self?.progressLabel = id.isEmpty ? L("正在完成…") : L("正在迁移 %@…", id)
                }
            }
            DispatchQueue.main.async {
                self?.result = result
                self?.isMigrating = false
                self?.cancellationToken = nil
                WEWallpaper.invalidateSizeCache()
                contentViewModel.refresh()
            }
        }
    }

    func cancelMigration() {
        cancellationToken?.cancel()
        progressLabel = L("正在安全停止…")
    }
}

private struct WorkshopMigrationView: View {
    @StateObject private var model: WorkshopMigrationViewModel
    @ObservedObject var contentViewModel: ContentViewModel
    let onBack: () -> Void
    let onComplete: () -> Void

    init(
        selectedURL: URL,
        contentViewModel: ContentViewModel,
        onBack: @escaping () -> Void,
        onComplete: @escaping () -> Void
    ) {
        _model = StateObject(wrappedValue: WorkshopMigrationViewModel(selectedURL: selectedURL))
        self.contentViewModel = contentViewModel
        self.onBack = onBack
        self.onComplete = onComplete
    }

    var body: some View {
        Group {
            if model.isScanning {
                VStack(spacing: 14) {
                    ProgressView()
                    Text("正在扫描创意工坊目录…")
                    Text(model.selectedURL.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            } else if model.directlyConnected {
                completionView(
                    title: "目录已连接",
                    detail: "Mirage 将直接读取此 431960 目录。移动硬盘或共享目录需要保持可用。",
                    icon: "externaldrive.fill.badge.checkmark"
                )
            } else if let result = model.result {
                resultView(result)
            } else if let scan = model.scan {
                scanView(scan)
            } else {
                errorView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func scanView(_ scan: WorkshopMigrationScan) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text(scan.sourceRoot.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Picker("迁移方式", selection: $model.mode) {
                    ForEach(WorkshopMigrationMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                if model.mode == .copy {
                    Picker("遇到同 ID 项目", selection: $model.conflictPolicy) {
                        ForEach(WorkshopMigrationConflictPolicy.allCases) { policy in
                            Text(policy.title).tag(policy)
                        }
                    }
                    .pickerStyle(.segmented)
                } else {
                    Label("不复制文件；目录移动或离线后，其中的壁纸将不可用。", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)

            Divider()

            HStack {
                Text(L("扫描到 %d 个项目", scan.items.count))
                    .font(.headline)
                Spacer()
                if model.mode == .copy {
                    Button("全选可迁移项目", action: model.selectAll)
                    Button("取消全选", action: model.selectNone)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)

            List(scan.items) { item in
                HStack(spacing: 10) {
                    if model.mode == .copy {
                        Toggle("", isOn: Binding(
                            get: { model.selectedIDs.contains(item.id) },
                            set: { model.setSelected($0, item: item) }
                        ))
                        .labelsHidden()
                        .disabled(item.status.isBlocking)
                    }
                    Image(systemName: item.isPreset ? "slider.horizontal.3" : icon(for: item.kind))
                        .frame(width: 20)
                        .foregroundStyle(color(for: item.status))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title)
                            .lineLimit(1)
                        HStack(spacing: 8) {
                            Text(item.id).monospaced()
                            Text(item.isPreset ? L("预设") : item.kind.displayName)
                            Text(ByteCountFormatter.string(fromByteCount: item.allocatedSize, countStyle: .file))
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Label(item.status.title, systemImage: statusIcon(for: item.status))
                        .font(.caption)
                        .foregroundStyle(color(for: item.status))
                        .lineLimit(1)
                }
                .padding(.vertical, 3)
            }
            .listStyle(.inset)

            Divider()
            HStack {
                Button("返回", action: onBack)
                    .disabled(model.isMigrating)
                Spacer()
                if model.isMigrating {
                    Button("取消迁移", action: model.cancelMigration)
                    ProgressView(value: model.progress)
                        .frame(width: 160)
                    Text(model.progressLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 130, alignment: .leading)
                }
                Button(model.mode == .copy ? "开始迁移" : "使用此目录") {
                    model.migrate(contentViewModel: contentViewModel)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isMigrating || (model.mode == .copy && model.selectedIDs.isEmpty))
            }
            .padding(20)
        }
    }

    private func resultView(_ result: WorkshopMigrationResult) -> some View {
        VStack(spacing: 18) {
            Image(systemName: result.wasCancelled
                  ? "xmark.circle.fill"
                  : (result.failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"))
                .font(.system(size: 48))
                .foregroundStyle(result.failures.isEmpty && !result.wasCancelled ? Color.green : Color.orange)
            Text(model.result?.wasCancelled == true ? "迁移已取消" : "迁移完成")
                .font(.title.bold())
            HStack(spacing: 24) {
                summary(L("已迁移 %d", result.importedIDs.count), color: .green)
                summary(L("已跳过 %d", result.skippedIDs.count), color: .secondary)
                summary(L("失败 %d", result.failures.count), color: result.failures.isEmpty ? .secondary : .red)
            }
            if !result.failures.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(result.failures.keys.sorted(), id: \.self) { id in
                            Text("\(id)：\(result.failures[id] ?? "")")
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 140)
                .padding(10)
                .background(Color.red.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            }
            if let backup = result.backupDirectory {
                Button("在访达中显示替换前的备份") {
                    NSWorkspace.shared.activateFileViewerSelecting([backup])
                }
            }
            Button("完成", action: onComplete)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
        .padding(30)
    }

    private func completionView(title: LocalizedStringKey, detail: LocalizedStringKey, icon: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundStyle(.green)
            Text(title).font(.title.bold())
            Text(detail)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            Button("完成", action: onComplete)
                .buttonStyle(.borderedProminent)
        }
        .padding(30)
    }

    private var errorView: some View {
        VStack(spacing: 14) {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 44))
                .foregroundStyle(.orange)
            Text("无法扫描此目录")
                .font(.title2.bold())
            Text(model.errorMessage ?? L("未知错误"))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack {
                Button("返回", action: onBack)
                Button("重新扫描", action: model.startScan)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(30)
    }

    private func summary(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.headline)
            .foregroundStyle(color)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(color.opacity(0.08), in: Capsule())
    }

    private func icon(for kind: WallpaperKind) -> String {
        switch kind {
        case .scene: return "sparkles.rectangle.stack"
        case .web: return "globe"
        case .video: return "play.rectangle.fill"
        case .unsupported: return "questionmark.square.dashed"
        }
    }

    private func statusIcon(for status: WorkshopMigrationStatus) -> String {
        switch status {
        case .ready: return "checkmark.circle.fill"
        case .destinationExists: return "doc.on.doc.fill"
        case .missingDependency: return "link.badge.plus"
        case .unsupported, .invalidManifest, .missingEntry, .unsafePackage:
            return "exclamationmark.triangle.fill"
        }
    }

    private func color(for status: WorkshopMigrationStatus) -> Color {
        switch status {
        case .ready: return .green
        case .destinationExists: return .blue
        case .missingDependency: return .orange
        case .unsupported, .invalidManifest, .missingEntry, .unsafePackage: return .red
        }
    }
}
