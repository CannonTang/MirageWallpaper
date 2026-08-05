//
//  Mirage Wallpaper
//
//  Copyright © 2026 王孝慈. All rights reserved.
//

import SwiftUI
import WebKit
import Combine

struct WorkshopItemDetail: View {
    var item: WorkshopItem?
    @ObservedObject var workshopViewModel: WorkshopViewModel

    @State private var isLoaded = false

    var body: some View {
        VStack {
            if let item {
                detailContent(for: item)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "sidebar.right")
                        .font(.system(size: 32))
                        .foregroundStyle(.tertiary)
                    Text("点击壁纸查看详情")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: item?.id) { _ in
            isLoaded = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isLoaded = true
                }
            }
        }
        .onAppear {
            isLoaded = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isLoaded = true
                }
            }
        }
    }

    @ViewBuilder
    func detailContent(for item: WorkshopItem) -> some View {
        ScrollView {
            VStack(spacing: 16) {
                if !isLoaded {
                    VStack(spacing: 12) {
                        ProgressView()
                            .scaleEffect(1.2)
                        Text("正在加载壁纸详情...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: 280, height: 280)
                    .background(Color.secondary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    WorkshopImage(
                        url: item.previewImageURL,
                        contentMode: .fill,
                        isAnimating: true
                    )
                        .frame(width: 280, height: 280)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(Color.white.opacity(0.7), lineWidth: 3)
                        )
                }

                Text(item.title)
                    .font(.headline)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)

                if !item.creatorSteamId.isEmpty {
                    Button {
                        if let creator = WorkshopCreator(item: item) {
                            workshopViewModel.openCreatorProfile(creator)
                        }
                    } label: {
                        HStack(spacing: 10) {
                            creatorAvatar(for: item)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.creatorDisplayName)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                                Text(LocalizedStringKey("查看作者主页和作品"))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "arrow.up.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)

                    if let creator = WorkshopCreator(item: item), creator.profileURL != nil {
                        Button {
                            workshopViewModel.openCreatorWorkshop(creator)
                        } label: {
                            Label(LocalizedStringKey("在 Steam 中查看作者"), systemImage: "safari")
                        }
                        .buttonStyle(.link)
                    }
                }

                if item.isPreset {
                    Label("创意工坊预设：需要对应的基础壁纸", systemImage: "slider.horizontal.3")
                        .font(.caption.bold())
                        .foregroundStyle(.purple)
                        .padding(8)
                        .frame(maxWidth: .infinity)
                        .background(Color.purple.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                }

                HStack(spacing: 16) {
                    StatView(icon: "arrow.down.circle.fill", value: item.formattedSubscriptions, label: "订阅")
                    StatView(icon: "heart.fill", value: item.formattedFavorited, label: "收藏")
                    StatView(icon: "eye.fill", value: item.formattedViews, label: "浏览")
                }

                HStack(spacing: 12) {
                    Label(item.displayTypeName, systemImage: "tag.fill")
                    Label(item.formattedFileSize, systemImage: "doc.fill")
                    if let rating = item.ageRating {
                        let tint: Color = rating == .everyone
                            ? .secondary
                            : (rating == .mature ? .red : .orange)
                        Label(rating.displayName, systemImage: rating == .everyone ? "checkmark.seal" : "exclamationmark.triangle")
                            .foregroundStyle(tint)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                sectionHeader("标签")
                tagList(for: item)

                sectionHeader("描述")
                if item.itemDescription.isEmpty {
                    Text("暂无描述")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    Text(item.itemDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(8)
                }

                sectionHeader("操作")
                downloadSection(for: item)

                Button {
                    let urlStr = "https://steamcommunity.com/sharedfiles/filedetails/?id=\(item.publishedFileId)"
                    if let url = URL(string: urlStr) {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("在 Steam 中查看", systemImage: "safari")
                        .frame(maxWidth: .infinity)
                }

                sectionHeader("信息")
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Workshop ID")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(item.publishedFileId)
                    }
                    HStack {
                        Text("更新时间")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(item.timeUpdated, style: .date)
                    }
                }
                .font(.caption)
            }
            .padding([.horizontal, .top])
        }

        HStack {
            Spacer()
            Button {
                AppDelegate.shared.mainWindowController.close()
            } label: {
                Text("确定").frame(width: 50)
            }
            .buttonStyle(.borderedProminent)
            Button {
                AppDelegate.shared.mainWindowController.close()
            } label: {
                Text("取消").frame(width: 50)
            }
        }
        .padding()
    }

    @ViewBuilder
    func downloadSection(for item: WorkshopItem) -> some View {
        let hasDownloadTask = workshopViewModel.downloadState(for: item.publishedFileId) != nil
        let installed = workshopViewModel.installedItem(workshopId: item.publishedFileId)
        if let installed, installed.needsPresetDependency {
            VStack(spacing: 6) {
                Text("预设已下载，但缺少基础壁纸 \(installed.presetDependency?.rawValue ?? "")")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                Button {
                    workshopViewModel.requestPresetDependency(for: installed)
                } label: {
                    Label("下载基础壁纸", systemImage: "square.stack.3d.up.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        } else if !hasDownloadTask, installed?.isValid == true {
            Button { } label: {
                Label(LocalizedStringKey(item.isPreset ? "预设已安装" : "已下载"), systemImage: "checkmark.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .disabled(true)
        } else if workshopViewModel.steamSetupState != .ready {
            VStack(spacing: 6) {
                Text(workshopViewModel.steamServiceStatus.workshopDownload.summary)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                Button {
                    AppDelegate.shared.openSteamSetup()
                } label: {
                    Label(
                        LocalizedStringKey(workshopViewModel.steamSetupState == .steamCMDMissing ? "安装 SteamCMD" : "登录全球 Steam"),
                        systemImage: "person.crop.circle.badge.exclamationmark"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        } else if let state = workshopViewModel.downloadState(for: item.publishedFileId) {
            switch state {
            case .downloading(let percent):
                VStack(spacing: 4) {
                    if let percent {
                        ProgressView(value: percent)
                            .animation(.linear, value: percent)
                    } else {
                        ProgressView(value: 0)
                    }
                    Text(percent.map { L("%d%% 下载中…", Int($0 * 100)) } ?? L("正在连接 Steam…"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Button {
                    workshopViewModel.cancelDownload(item)
                } label: {
                    Label("取消下载", systemImage: "xmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            case .queued:
                Button { } label: {
                    Label("排队中...", systemImage: "clock")
                        .frame(maxWidth: .infinity)
                }
                .disabled(true)
            case .starting:
                HStack {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("正在启动 SteamCMD…")
                        .font(.caption)
                }
            case .validating:
                HStack {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("正在验证下载文件…")
                        .font(.caption)
                }
            case .failed(let msg):
                Text(msg)
                    .font(.caption2)
                    .foregroundStyle(.red)
                Button {
                    if let task = workshopViewModel.downloadQueue.first(where: { $0.id == item.publishedFileId }) {
                        workshopViewModel.retryDownload(task)
                    }
                } label: {
                    Label("重试", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            case .completed:
                Button { } label: {
                    Label("已完成", systemImage: "checkmark.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(true)
            }
        } else {
            Button {
                workshopViewModel.downloadItem(item)
            } label: {
                Label(LocalizedStringKey(item.isPreset ? "下载预设" : "下载壁纸"), systemImage: "arrow.down.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    func tagList(for item: WorkshopItem) -> some View {
        if item.tags.isEmpty {
            Text("暂无标签")
                .font(.caption)
                .foregroundStyle(.tertiary)
        } else {
            HStack {
                ForEach(item.tags.prefix(6), id: \.self) { tag in
                    Text(tag)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background {
                            RoundedRectangle(cornerRadius: 12)
                                .colorInvert()
                                .foregroundStyle(Color.primary)
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.secondary, lineWidth: 1)
                        }
                }
                if item.tags.count > 6 {
                    Text("+\(item.tags.count - 6)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    func sectionHeader(_ title: LocalizedStringKey) -> some View {
        HStack(spacing: 3) {
            Text(title)
            VStack {
                Divider().frame(height: 1).overlay(Color.accentColor)
            }
        }
    }

    @ViewBuilder
    func creatorAvatar(for item: WorkshopItem) -> some View {
        AsyncImage(url: item.creatorAvatarURL) { phase in
            if case .success(let image) = phase {
                image
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 34, height: 34)
        .clipShape(Circle())
    }
}

struct StatView: View {
    var icon: String
    var value: String
    var label: LocalizedStringKey

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption)
                .bold()
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}

struct CreatorProfileView: View {
    let creator: WorkshopCreator
    @ObservedObject var workshopViewModel: WorkshopViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                AsyncImage(url: creator.avatarURL) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    } else {
                        Image(systemName: "person.crop.circle.fill")
                            .resizable()
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 42, height: 42)
                .clipShape(Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(creator.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text(L("Steam ID：%@", creator.steamId))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Spacer(minLength: 0)

                if let profileURL = creator.profileURL {
                    Button {
                        NSWorkspace.shared.open(profileURL)
                    } label: {
                        Image(systemName: "safari")
                    }
                    .buttonStyle(.plain)
                    .help(L("在 Steam 中查看作者"))
                }

                Button {
                    workshopViewModel.showCreatorProfile = false
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .help(L("关闭作者主页"))
            }
            .padding(12)

            Divider()

            if creator.workshopURL != nil {
                CreatorWorkshopWebView(
                    creator: creator,
                    workshopViewModel: workshopViewModel
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "person.crop.circle.badge.exclamationmark")
                        .font(.system(size: 30))
                        .foregroundStyle(.secondary)
                    Text(L("无法打开作者主页"))
                        .font(.headline)
                    Text(L("该作者没有可用的 Steam 主页地址。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

struct CreatorWorkshopWebView: NSViewRepresentable {
    let creator: WorkshopCreator
    @ObservedObject var workshopViewModel: WorkshopViewModel

    private static let messageHandlerName = "mirageDownload"

    func makeCoordinator() -> Coordinator {
        Coordinator(workshopViewModel: workshopViewModel)
    }

    func makeNSView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(
            source: Self.downloadButtonScript(),
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false
        ))
        controller.add(context.coordinator, name: Self.messageHandlerName)

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        configuration.websiteDataStore = .default()

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        context.coordinator.attach(webView)
        context.coordinator.load(creator: creator, in: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.load(creator: creator, in: webView)
        context.coordinator.syncDownloadStatuses()
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: Self.messageHandlerName
        )
        coordinator.detach()
    }

    private static func downloadButtonScript() -> String {
        let labels = [
            "download": L("下载"),
            "queued": L("已加入下载队列"),
            "downloading": L("下载中…"),
            "downloaded": L("已下载"),
            "retry": L("重试下载")
        ]
        let data = try? JSONSerialization.data(withJSONObject: labels)
        let json = data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

        return """
        (() => {
          if (window.MirageWorkshop) return;
          const labels = \(json);
          const states = Object.create(null);

          const style = document.createElement('style');
          style.textContent = `
            .mirage-download-button {
              position: absolute; right: 8px; bottom: 8px; z-index: 2147483647;
              min-height: 28px; padding: 5px 10px; border: 1px solid rgba(255,255,255,.35);
              border-radius: 5px; color: #fff; background: rgba(20,22,26,.88);
              font: 600 12px -apple-system, BlinkMacSystemFont, sans-serif;
              box-shadow: 0 2px 8px rgba(0,0,0,.35); cursor: pointer;
            }
            .mirage-download-button:hover { background: rgba(48,105,164,.96); }
            .mirage-download-button[data-status="queued"],
            .mirage-download-button[data-status="downloading"] { cursor: progress; opacity: .9; }
            .mirage-download-button[data-status="downloaded"] { background: rgba(42,115,66,.94); cursor: default; }
            .mirage-download-button[data-status="failed"] { background: rgba(145,52,52,.94); }
          `;
          (document.head || document.documentElement).appendChild(style);

          function workshopID(link) {
            try {
              const url = new URL(link.href, location.href);
              if (!url.pathname.includes('/sharedfiles/filedetails/')) return null;
              const id = url.searchParams.get('id');
              return id && /^[0-9]+$/.test(id) ? id : null;
            } catch (_) { return null; }
          }

          function applyState(button, state) {
            const status = state?.status || 'download';
            button.dataset.status = status;
            button.textContent = state?.text || labels.download;
            button.disabled = status === 'queued' || status === 'downloading' || status === 'downloaded';
          }

          function decorate() {
            document.querySelectorAll('a[href*="sharedfiles/filedetails"]').forEach(link => {
              const id = workshopID(link);
              if (!id || link.querySelector(`.mirage-download-button[data-id="${id}"]`)) return;
              const button = document.createElement('button');
              button.type = 'button';
              button.className = 'mirage-download-button';
              button.dataset.id = id;
              applyState(button, states[id]);
              button.addEventListener('click', event => {
                event.preventDefault();
                event.stopImmediatePropagation();
                if (button.dataset.status === 'downloaded' || button.dataset.status === 'queued' || button.dataset.status === 'downloading') return;
                states[id] = { status: 'queued', text: labels.queued };
                applyState(button, states[id]);
                window.webkit.messageHandlers.mirageDownload.postMessage({ type: 'download', id });
              }, true);
              if (getComputedStyle(link).position === 'static') link.style.position = 'relative';
              link.appendChild(button);
            });
          }

          window.MirageWorkshop = {
            setStatuses(next) {
              Object.keys(next || {}).forEach(id => { states[id] = next[id]; });
              document.querySelectorAll('.mirage-download-button[data-id]').forEach(button => {
                applyState(button, states[button.dataset.id]);
              });
            }
          };

          new MutationObserver(decorate).observe(document.documentElement, { childList: true, subtree: true });
          decorate();
        })();
        """
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        private weak var workshopViewModel: WorkshopViewModel?
        private weak var webView: WKWebView?
        private var downloadObserver: AnyCancellable?
        private var loadedCreatorID: String?

        init(workshopViewModel: WorkshopViewModel) {
            self.workshopViewModel = workshopViewModel
            super.init()
            downloadObserver = Publishers.CombineLatest(
                workshopViewModel.$downloadQueue,
                workshopViewModel.$installedWorkshopIDs
            )
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in
                self?.syncDownloadStatuses()
            }
        }

        func attach(_ webView: WKWebView) {
            self.webView = webView
        }

        func detach() {
            downloadObserver?.cancel()
            downloadObserver = nil
            webView = nil
        }

        func load(creator: WorkshopCreator, in webView: WKWebView) {
            guard loadedCreatorID != creator.id else { return }
            loadedCreatorID = creator.id
            guard let url = creator.workshopURL else { return }
            webView.load(URLRequest(url: url))
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == CreatorWorkshopWebView.messageHandlerName,
                  let body = message.body as? [String: Any],
                  body["type"] as? String == "download",
                  let id = body["id"] as? String,
                  !id.isEmpty,
                  id.allSatisfy(\.isNumber),
                  UInt64(id) ?? 0 > 0 else { return }

            workshopViewModel?.downloadWorkshopID(id) { [weak self] accepted in
                guard !accepted else { return }
                self?.setStatus(
                    for: id,
                    status: "failed",
                    text: L("无法获取壁纸信息，点击重试")
                )
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            syncDownloadStatuses()
        }

        func syncDownloadStatuses() {
            guard let workshopViewModel, let webView else { return }
            var values: [String: [String: String]] = [:]
            for id in workshopViewModel.installedWorkshopIDs {
                values[id] = ["status": "downloaded", "text": L("已下载")]
            }
            for task in workshopViewModel.downloadQueue {
                values[task.id] = Self.statusValue(for: task.state)
            }
            guard let data = try? JSONSerialization.data(withJSONObject: values),
                  let json = String(data: data, encoding: .utf8) else { return }
            webView.evaluateJavaScript("window.MirageWorkshop?.setStatuses(\(json));")
        }

        private func setStatus(for id: String, status: String, text: String) {
            let value = [id: ["status": status, "text": text]]
            guard let data = try? JSONSerialization.data(withJSONObject: value),
                  let json = String(data: data, encoding: .utf8) else { return }
            webView?.evaluateJavaScript("window.MirageWorkshop?.setStatuses(\(json));")
        }

        private static func statusValue(for state: DownloadState) -> [String: String] {
            switch state {
            case .queued:
                return ["status": "queued", "text": L("已加入下载队列")]
            case .starting:
                return ["status": "downloading", "text": L("正在连接 Steam…")]
            case .downloading(let percent):
                let text = percent.map { L("%d%% 下载中…", Int($0 * 100)) } ?? L("下载中…")
                return ["status": "downloading", "text": text]
            case .validating:
                return ["status": "downloading", "text": L("正在验证下载文件…")]
            case .completed:
                return ["status": "downloaded", "text": L("已下载")]
            case .failed:
                return ["status": "failed", "text": L("下载失败，点击重试")]
            }
        }
    }
}
