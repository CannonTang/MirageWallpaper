//
//  Mirage Wallpaper
//
//  Shadertoy-compatible local shader editor.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

private enum ShadertoyPreviewStatus: Equatable {
    case idle
    case loading
    case ready(String)
    case failed(String)
}

private enum ShadertoyPerformancePreset: String, CaseIterable, Identifiable {
    case battery
    case balanced
    case quality
    case extreme
    case custom

    var id: Self { self }

    var displayName: String {
        switch self {
        case .battery: return "省电"
        case .balanced: return "平衡"
        case .quality: return "高质量"
        case .extreme: return "极致"
        case .custom: return "自定义"
        }
    }
}

private final class ShadertoyEditorModel: ObservableObject {
    @Published var draft: ShadertoyProjectDraft
    @Published var selectedPass: ShadertoyPassID = .image
    @Published var previewHTML = ""
    @Published var previewRevision = UUID()
    @Published var previewStatus: ShadertoyPreviewStatus = .idle
    @Published var previewPNG: Data?
    @Published var isSaving = false
    @Published var errorMessage: String?
    private var draftVersion = UUID()
    private var previewedDraftVersion: UUID?

    init(editingWallpaper: WEWallpaper?) {
        if let editingWallpaper {
            do {
                draft = try ShadertoyPackageBuilder.loadDraft(from: editingWallpaper)
            } catch {
                draft = ShadertoyProjectDraft()
                errorMessage = error.localizedDescription
            }
        } else {
            draft = ShadertoyPackageBuilder.builtInDefaultDraft()
                ?? ShadertoyProjectDraft()
        }
    }

    func refreshPreview() {
        errorMessage = nil
        previewStatus = .loading
        previewPNG = nil
        do {
            previewHTML = try ShadertoyPackageBuilder.makePreviewHTML(for: draft)
            previewedDraftVersion = draftVersion
            previewRevision = UUID()
        } catch {
            previewStatus = .failed(error.localizedDescription)
            errorMessage = error.localizedDescription
        }
    }

    func replaceSelectedCode(with code: String) {
        var next = draft
        next.updatePass(selectedPass) { $0.code = code }
        draft = next
        invalidatePreview()
    }

    func updateChannel(_ index: Int, _ update: (inout ShadertoyChannelDraft) -> Void) {
        var next = draft
        next.updatePass(selectedPass) { pass in
            guard pass.channels.indices.contains(index) else { return }
            update(&pass.channels[index])
        }
        draft = next
        invalidatePreview()
    }

    func updateRenderScale(_ value: Double) {
        guard draft.renderScale != value else { return }
        draft.renderScale = value
        invalidatePreview()
    }

    func updateFPSLimit(_ value: Int) {
        guard draft.fpsLimit != value else { return }
        draft.fpsLimit = value
        invalidatePreview()
    }

    func updateMaxDimension(_ value: Int) {
        guard draft.maxDimension != value else { return }
        draft.maxDimension = value
        invalidatePreview()
    }

    var performancePreset: ShadertoyPerformancePreset {
        switch (draft.renderScale, draft.fpsLimit, draft.maxDimension) {
        case (0.5, 30, 1920): return .battery
        case (0.75, 45, 2560): return .balanced
        case (1.0, 60, 4096): return .quality
        case (1.0, 120, 8192): return .extreme
        default: return .custom
        }
    }

    func applyPerformancePreset(_ preset: ShadertoyPerformancePreset) {
        var next = draft
        switch preset {
        case .battery:
            (next.renderScale, next.fpsLimit, next.maxDimension) = (0.5, 30, 1920)
        case .balanced:
            (next.renderScale, next.fpsLimit, next.maxDimension) = (0.75, 45, 2560)
        case .quality:
            (next.renderScale, next.fpsLimit, next.maxDimension) = (1.0, 60, 4096)
        case .extreme:
            (next.renderScale, next.fpsLimit, next.maxDimension) = (1.0, 120, 8192)
        case .custom:
            return
        }
        guard next != draft else { return }
        draft = next
        invalidatePreview()
    }

    func handlePreviewStatus(_ status: ShadertoyPreviewStatus) {
        guard previewedDraftVersion == draftVersion else { return }
        previewStatus = status
    }

    var hasCurrentSuccessfulPreview: Bool {
        guard previewedDraftVersion == draftVersion,
              case .ready = previewStatus,
              previewPNG?.isEmpty == false else { return false }
        return true
    }

    func handleSnapshot(_ data: Data) {
        guard previewedDraftVersion == draftVersion,
              case .ready = previewStatus,
              !data.isEmpty else { return }
        previewPNG = data
    }

    private func invalidatePreview() {
        draftVersion = UUID()
        previewedDraftVersion = nil
        previewStatus = .idle
        previewPNG = nil
    }
}

struct ShadertoyImportView: View {
    @ObservedObject var contentViewModel: ContentViewModel
    @ObservedObject var wallpaperViewModel: WallpaperViewModel
    let onBack: () -> Void
    let onComplete: () -> Void
    let editingWallpaper: WEWallpaper?

    @StateObject private var model: ShadertoyEditorModel

    init(contentViewModel: ContentViewModel,
         wallpaperViewModel: WallpaperViewModel,
         editingWallpaper: WEWallpaper? = nil,
         onBack: @escaping () -> Void,
         onComplete: @escaping () -> Void) {
        self.contentViewModel = contentViewModel
        self.wallpaperViewModel = wallpaperViewModel
        self.editingWallpaper = editingWallpaper
        self.onBack = onBack
        self.onComplete = onComplete
        _model = StateObject(
            wrappedValue: ShadertoyEditorModel(editingWallpaper: editingWallpaper)
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            metadataBar
            Divider()
            HSplitView {
                editorPane
                    .frame(minWidth: 420, idealWidth: 620)
                previewPane
                    .frame(minWidth: 280, idealWidth: 460)
            }
            Divider()
            bottomBar
        }
        .onAppear {
            if model.previewHTML.isEmpty { model.refreshPreview() }
        }
    }

    private var metadataBar: some View {
        ViewThatFits(in: .horizontal) {
            wideMetadataLayout
            compactMetadataLayout
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private var wideMetadataLayout: some View {
        HStack(spacing: 14) {
            wallpaperTitleField
                .frame(minWidth: 210, idealWidth: 260)

            authorField
                .frame(width: 150)

            Spacer(minLength: 0)

            performancePresetPicker
                .frame(width: 125)
            renderScalePicker
                .frame(width: 145)
            fpsPicker
                .frame(width: 105)
            maxDimensionPicker
                .frame(width: 150)
        }
    }

    private var compactMetadataLayout: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                wallpaperTitleField
                    .frame(minWidth: 180, maxWidth: .infinity)
                authorField
                    .frame(width: 150)
            }

            HStack(alignment: .bottom, spacing: 10) {
                compactMetadataControl("优化") { performancePresetPicker }
                compactMetadataControl("渲染精度") { renderScalePicker }
                compactMetadataControl("FPS") { fpsPicker }
                compactMetadataControl("分辨率上限") { maxDimensionPicker }
            }
        }
    }

    private var wallpaperTitleField: some View {
        TextField("壁纸名称", text: Binding(
            get: { model.draft.title },
            set: { model.draft.title = $0 }
        ))
        .textFieldStyle(.roundedBorder)
    }

    private var authorField: some View {
        TextField("作者（可选）", text: Binding(
            get: { model.draft.author },
            set: { model.draft.author = $0 }
        ))
        .textFieldStyle(.roundedBorder)
    }

    private var performancePresetPicker: some View {
        Picker("优化", selection: Binding(
            get: { model.performancePreset },
            set: { model.applyPerformancePreset($0) }
        )) {
            ForEach(ShadertoyPerformancePreset.allCases) { preset in
                Text(preset.displayName).tag(preset)
            }
        }
        .help("一键选择性能与画质组合；单独修改后显示为自定义")
    }

    private var renderScalePicker: some View {
        Picker("渲染精度", selection: Binding(
            get: { model.draft.renderScale },
            set: { model.updateRenderScale($0) }
        )) {
            Text("25%").tag(0.25)
            Text("50%").tag(0.5)
            Text("75%").tag(0.75)
            Text("100%").tag(1.0)
        }
        .help("按屏幕分辨率的比例渲染；数值越低越省 GPU")
    }

    private var fpsPicker: some View {
        Picker("FPS", selection: Binding(
            get: { model.draft.fpsLimit },
            set: { model.updateFPSLimit($0) }
        )) {
            Text("15").tag(15)
            Text("24").tag(24)
            Text("30").tag(30)
            Text("45").tag(45)
            Text("60").tag(60)
            Text("90").tag(90)
            Text("120").tag(120)
        }
        .help("限制每秒渲染帧数；30 FPS 通常更省电")
    }

    private var maxDimensionPicker: some View {
        Picker("分辨率上限", selection: Binding(
            get: { model.draft.maxDimension },
            set: { model.updateMaxDimension($0) }
        )) {
            Text("720p").tag(1280)
            Text("1080p").tag(1920)
            Text("1440p").tag(2560)
            Text("4K").tag(4096)
            Text("8K").tag(8192)
        }
        .help("限制渲染缓冲区最长边，避免高分屏占用过多显存")
    }

    private func compactMetadataControl<Control: View>(
        _ title: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            control()
                .labelsHidden()
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var editorPane: some View {
        VStack(spacing: 12) {
            Picker("Pass", selection: $model.selectedPass) {
                ForEach(ShadertoyPassID.allCases) { pass in
                    Text(pass.displayName).tag(pass)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.selectedPass.displayName)
                        .font(.headline)
                    Text(passHelp)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    if let text = NSPasteboard.general.string(forType: .string), !text.isEmpty {
                        model.replaceSelectedCode(with: text)
                    }
                } label: {
                    Label("粘贴代码", systemImage: "doc.on.clipboard")
                }
                .help("用剪贴板内容替换当前 Pass；也可以直接在编辑器中按 ⌘V")
            }

            TextEditor(text: codeBinding)
                .font(.system(size: 12.5, design: .monospaced))
                .textSelection(.enabled)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.secondary.opacity(0.24))
                }

            HStack {
                Text("\(currentCode.components(separatedBy: .newlines).count) 行 · \(currentCode.count) 字符")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                if model.selectedPass != .common &&
                    currentCode.range(of: #"\bmainImage\s*\("#, options: .regularExpression) == nil {
                    Label("需要 mainImage()", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            if model.selectedPass.isRenderable {
                channelEditor
            }
        }
        .padding(16)
    }

    private var channelEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("输入通道")
                    .font(.headline)
                Spacer()
                Text("Buffer 引用支持上一帧自反馈")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(0..<4, id: \.self) { index in
                channelRow(index)
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.055))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func channelRow(_ index: Int) -> some View {
        let channel = currentPass.channels.indices.contains(index)
            ? currentPass.channels[index]
            : ShadertoyChannelDraft()
        return HStack(spacing: 8) {
            Text("iChannel\(index)")
                .font(.caption.monospaced())
                .frame(width: 68, alignment: .leading)

            Picker("", selection: channelSourceBinding(index)) {
                ForEach(ShadertoyChannelSource.allCases) { source in
                    Text(source.displayName).tag(source)
                }
            }
            .labelsHidden()
            .frame(width: 125)

            if channel.source == .texture {
                Button {
                    chooseTexture(for: index)
                } label: {
                    Text(channel.textureURL?.lastPathComponent ?? "选择图片…")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 100)
                }
            } else {
                Picker("", selection: channelFilterBinding(index)) {
                    ForEach(ShadertoyTextureFilter.allCases) { filter in
                        Text(filter.displayName).tag(filter)
                    }
                }
                .labelsHidden()
                .frame(width: 64)

                Picker("", selection: channelWrapBinding(index)) {
                    ForEach(ShadertoyTextureWrap.allCases) { wrap in
                        Text(wrap.displayName).tag(wrap)
                    }
                }
                .labelsHidden()
                .frame(width: 64)
            }

            Spacer(minLength: 0)
        }
    }

    private var previewPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("实时预览")
                    .font(.headline)
                Spacer()
                previewStatusLabel
            }

            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.black)
                if model.previewHTML.isEmpty {
                    ProgressView()
                        .controlSize(.large)
                } else {
                    ShadertoyPreviewWebView(
                        html: model.previewHTML,
                        revision: model.previewRevision,
                        onStatus: { status in model.handlePreviewStatus(status) },
                        onSnapshot: { data in model.handleSnapshot(data) }
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.secondary.opacity(0.25))
            }

            Button {
                model.refreshPreview()
            } label: {
                Label("编译并刷新预览", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            if case .failed(let message) = model.previewStatus {
                ScrollView {
                    Text(message)
                        .font(.caption.monospaced())
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 140)
                .padding(10)
                .background(Color.red.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            VStack(alignment: .leading, spacing: 5) {
                Label("可直接复制 Shadertoy 的 Common、Buffer A–D 和 Image 代码。", systemImage: "checkmark.circle")
                Label("支持普通图片、HDR OpenEXR、内置噪声、多 Pass 和 Buffer 自反馈。", systemImage: "square.stack.3d.up")
                Label("Sound、Cubemap、视频通道暂不支持。", systemImage: "info.circle")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Spacer(minLength: 0)
        }
        .padding(16)
    }

    @ViewBuilder
    private var previewStatusLabel: some View {
        switch model.previewStatus {
        case .idle:
            EmptyView()
        case .loading:
            Label("编译中", systemImage: "clock")
                .foregroundStyle(.secondary)
        case .ready:
            if model.previewPNG == nil {
                Label("正在生成封面", systemImage: "camera")
                    .foregroundStyle(.secondary)
            } else {
                Label("预览与封面已更新", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        case .failed:
            Label("编译失败", systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            if let errorMessage = model.errorMessage {
                Label(errorMessage, systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    bottomSafetyNote
                        .fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 12)
                    bottomActions
                }

                VStack(alignment: .leading, spacing: 8) {
                    bottomSafetyNote
                    HStack(spacing: 8) {
                        Spacer(minLength: 0)
                        bottomActions
                    }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private var bottomSafetyNote: some View {
        Text("Shader 只作为 GLSL 数据编译，不会执行粘贴内容中的 JavaScript。")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var bottomActions: some View {
        Button("返回", action: onBack)
            .disabled(model.isSaving)
        Button("仅保存") { save(apply: false) }
            .disabled(model.isSaving || !model.hasCurrentSuccessfulPreview)
        Button("保存并应用") { save(apply: true) }
            .buttonStyle(.borderedProminent)
            .disabled(model.isSaving || !model.hasCurrentSuccessfulPreview)
    }

    private var currentPass: ShadertoyPassDraft { model.draft.pass(model.selectedPass) }
    private var currentCode: String { currentPass.code }

    private var passHelp: String {
        switch model.selectedPass {
        case .common: return "公共函数和常量会插入到所有渲染 Pass。"
        case .image: return "最终输出；粘贴 Shadertoy 的 Image 代码。"
        default: return "离屏缓冲；可被其他 Pass 或自身的 iChannel 引用。"
        }
    }

    private var codeBinding: Binding<String> {
        Binding(
            get: { currentCode },
            set: { model.replaceSelectedCode(with: $0) }
        )
    }

    private func channelSourceBinding(_ index: Int) -> Binding<ShadertoyChannelSource> {
        Binding(
            get: {
                let pass = model.draft.pass(model.selectedPass)
                return pass.channels.indices.contains(index) ? pass.channels[index].source : .none
            },
            set: { value in model.updateChannel(index) { $0.source = value } }
        )
    }

    private func channelFilterBinding(_ index: Int) -> Binding<ShadertoyTextureFilter> {
        Binding(
            get: {
                let pass = model.draft.pass(model.selectedPass)
                return pass.channels.indices.contains(index) ? pass.channels[index].filter : .linear
            },
            set: { value in model.updateChannel(index) { $0.filter = value } }
        )
    }

    private func channelWrapBinding(_ index: Int) -> Binding<ShadertoyTextureWrap> {
        Binding(
            get: {
                let pass = model.draft.pass(model.selectedPass)
                return pass.channels.indices.contains(index) ? pass.channels[index].wrap : .repeatTexture
            },
            set: { value in model.updateChannel(index) { $0.wrap = value } }
        )
    }

    private func chooseTexture(for index: Int) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        var textureTypes: [UTType] = [.png, .jpeg, .gif, .webP, .bmp]
        if let openEXR = UTType(filenameExtension: "exr") {
            textureTypes.append(openEXR)
        }
        panel.allowedContentTypes = textureTypes
        panel.prompt = "选择纹理"
        panel.message = "选择用于 iChannel\(index) 的 PNG、JPEG、GIF、WebP、BMP 或 OpenEXR 纹理"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            model.updateChannel(index) {
                $0.source = .texture
                $0.textureURL = url
                $0.textureFormat = nil
                $0.textureWidth = nil
                $0.textureHeight = nil
            }
        }
    }

    private func save(apply: Bool) {
        model.errorMessage = nil
        guard model.hasCurrentSuccessfulPreview else {
            model.errorMessage = "请先刷新预览，并等待最新封面生成完成"
            return
        }
        do {
            try ShadertoyPackageBuilder.validate(model.draft)
        } catch {
            model.errorMessage = error.localizedDescription
            return
        }

        model.isSaving = true
        let draft = model.draft
        guard let preview = model.previewPNG else {
            model.isSaving = false
            model.errorMessage = "最新预览图尚未生成，请稍候再保存"
            return
        }
        let original = editingWallpaper
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let destination: URL
                if let original {
                    destination = try WallpaperLibrary.shared.updateShadertoyWallpaper(
                        original,
                        from: draft,
                        previewPNG: preview
                    )
                } else {
                    destination = try WallpaperLibrary.shared.createShadertoyWallpaper(
                        from: draft,
                        previewPNG: preview
                    )
                }
                let wallpaper = WEWallpaper.load(from: destination)
                DispatchQueue.main.async {
                    WEWallpaper.invalidateSizeCache()
                    contentViewModel.refresh()
                    // This package contains Mirage-owned HTML/JS; pasted text is
                    // base64-encoded JSON and reaches WebGL only as GLSL source.
                    wallpaperViewModel.trust(wallpaper)
                    if apply, wallpaper.isValid {
                        let runtime = original.map {
                            wallpaperViewModel.loadRuntime(for: $0)
                        } ?? WallpaperRuntimeState()
                        wallpaperViewModel.applyImportedWallpaper(
                            wallpaper,
                            runtime: runtime
                        )
                    } else if original != nil {
                        wallpaperViewModel.refreshStoredWallpaperReference(wallpaper)
                    }
                    model.isSaving = false
                    onComplete()
                }
            } catch {
                DispatchQueue.main.async {
                    model.isSaving = false
                    model.errorMessage = error.localizedDescription
                }
            }
        }
    }
}

private struct ShadertoyPreviewWebView: NSViewRepresentable {
    let html: String
    let revision: UUID
    let onStatus: (ShadertoyPreviewStatus) -> Void
    let onSnapshot: (Data) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(
            context.coordinator,
            name: "mirageShaderPreview"
        )
        let webView = WKWebView(frame: .zero, configuration: configuration)
        context.coordinator.webView = webView
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        if #available(macOS 13.3, *) { webView.isInspectable = true }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        guard context.coordinator.loadedRevision != revision else { return }
        context.coordinator.loadedRevision = revision
        context.coordinator.terminalStatus = nil
        onStatus(.loading)
        webView.loadHTMLString(html, baseURL: nil)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: ShadertoyPreviewWebView
        var loadedRevision: UUID?
        var terminalStatus: String?
        weak var webView: WKWebView?

        init(parent: ShadertoyPreviewWebView) {
            self.parent = parent
        }

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard message.name == "mirageShaderPreview",
                  let object = message.body as? [String: Any],
                  let type = object["type"] as? String else { return }
            let text = object["message"] as? String ?? ""
            handle(type: type, text: text)
        }

        private func handle(type: String, text: String) {
            guard terminalStatus == nil else { return }
            switch type {
            case "ready":
                terminalStatus = type
                parent.onStatus(.ready(text))
                guard let webView else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    self.capture(webView)
                }
            case "error":
                terminalStatus = type
                parent.onStatus(.failed(text))
            default:
                break
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            pollDocumentStatus(webView, attemptsRemaining: 50)
        }

        private func pollDocumentStatus(_ webView: WKWebView, attemptsRemaining: Int) {
            guard terminalStatus == nil else { return }
            let script = """
            JSON.stringify({
              type: document.documentElement.dataset.mirageShaderStatus || "",
              message: document.documentElement.dataset.mirageShaderMessage || "",
              readyState: document.readyState,
              scriptCount: document.scripts.length,
              configLength: (window.__MIRAGE_SHADER_CONFIG_B64 || "").length,
              runtimeLoaded: !!window.wallpaperPropertyListener,
              canvasSize: (() => {
                const canvas = document.getElementById("mirage-shader-canvas");
                return canvas ? `${canvas.width}x${canvas.height}` : "missing";
              })()
            })
            """
            webView.evaluateJavaScript(script) { [weak self, weak webView] value, _ in
                guard let self, let webView, self.terminalStatus == nil else { return }
                if let text = value as? String,
                   let data = text.data(using: .utf8),
                   let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let type = object["type"] as? String ?? ""
                    if type == "ready" || type == "error" {
                        self.handle(type: type, text: object["message"] as? String ?? "")
                        return
                    }
                    guard attemptsRemaining > 0 else {
                        self.terminalStatus = "timeout"
                        let readyState = object["readyState"] as? String ?? "unknown"
                        let scripts = object["scriptCount"] as? Int ?? 0
                        let configLength = object["configLength"] as? Int ?? 0
                        let runtimeLoaded = object["runtimeLoaded"] as? Bool ?? false
                        let runtimeDescription = runtimeLoaded ? "已载入" : "未载入"
                        let canvasSize = object["canvasSize"] as? String ?? "unknown"
                        self.parent.onStatus(.failed(
                            "预览运行超时（页面：\(readyState)，脚本：\(scripts)，配置：\(configLength) B，运行时：\(runtimeDescription)，画布：\(canvasSize)）。"
                        ))
                        return
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    self.pollDocumentStatus(webView, attemptsRemaining: attemptsRemaining - 1)
                }
            }
        }

        private func capture(_ webView: WKWebView) {
            let configuration = WKSnapshotConfiguration()
            configuration.afterScreenUpdates = true
            webView.takeSnapshot(with: configuration) { image, _ in
                guard let image,
                      let tiff = image.tiffRepresentation,
                      let representation = NSBitmapImageRep(data: tiff),
                      let png = representation.representation(using: .png, properties: [:]) else {
                    return
                }
                self.parent.onSnapshot(png)
            }
        }

        func webView(_ webView: WKWebView,
                     didFail navigation: WKNavigation!,
                     withError error: Error) {
            parent.onStatus(.failed(error.localizedDescription))
        }

        func webView(_ webView: WKWebView,
                     didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            parent.onStatus(.failed(error.localizedDescription))
        }
    }
}
