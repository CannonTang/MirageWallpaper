//
//  Mirage Wallpaper
//
//  Copyright © 2026 王孝慈. All rights reserved.
//

import Foundation
import Security

final class SteamServiceManager: ObservableObject, @unchecked Sendable {
    static let shared = SteamServiceManager()

    @Published private(set) var isAvailable = false
    @Published private(set) var isLoggedIn = false
    @Published private(set) var loginState: SteamLoginState = .idle
    @Published private(set) var authenticationState: SteamServiceState = .unknown
    @Published private(set) var accountName = ""

    var savedUsername: String {
        get { UserDefaults.standard.string(forKey: usernameKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: usernameKey) }
    }

    var contentDirectory: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Mirage/Workshop/content/431960", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private let ioQueue = DispatchQueue(label: "cn.laobamac.Mirage.steam-service", qos: .userInitiated)
    private let keychainService = "cn.laobamac.Mirage.SteamService"
    private let usernameKey = "SteamServiceUsername"
    private var process: Process?
    private var input: FileHandle?
    private var outputBuffer = Data()
    private var requestHandlers: [String: (Bool, String?, String?) -> Void] = [:]
    private var downloadHandlers: [String: (DownloadState) -> Void] = [:]
    private var restoringSession = false
    private var explicitShutdown = false

    private init() {}

    func start() {
        ioQueue.async { [weak self] in
            self?.startOnQueue()
        }
    }

    func restoreSessionIfNeeded() {
        ioQueue.async { [weak self] in
            self?.restoreSessionOnQueue()
        }
    }

    func loginWithQR() {
        updateOnMain {
            self.loginState = .loggingIn
            self.authenticationState = .checking
        }
        ioQueue.async { [weak self] in
            guard let self else { return }
            self.restoringSession = false
            self.sendCommandOnQueue("loginQr") { success, message, errorCode in
                if !success { self.failAuthenticationRequest(code: errorCode, detail: message) }
            }
        }
    }

    func login(username: String, password: String) {
        updateOnMain {
            self.loginState = .loggingIn
            self.authenticationState = .checking
        }
        ioQueue.async { [weak self] in
            guard let self else { return }
            self.restoringSession = false
            var fields: [String: Any] = [
                "username": username,
                "password": password
            ]
            if let guardData = self.keychainValue(account: self.guardDataAccount(username)) {
                fields["guardData"] = guardData
            }
            self.sendCommandOnQueue("loginPassword", fields: fields) { success, message, errorCode in
                if !success { self.failAuthenticationRequest(code: errorCode, detail: message) }
            }
        }
    }

    @discardableResult
    func submitGuardCode(_ code: String) -> Bool {
        guard !code.isEmpty else { return false }
        sendCommand("submitChallenge", fields: ["code": code])
        return true
    }

    func cancelLogin() {
        ioQueue.async { [weak self] in
            guard let self else { return }
            self.restoringSession = false
            self.sendCommandOnQueue("cancelLogin")
            self.updateOnMain {
                self.loginState = self.isLoggedIn ? .success : .idle
            }
        }
    }

    func logout(completion: @escaping (Result<Void, Error>) -> Void) {
        let username = savedUsername
        updateOnMain {
            self.isLoggedIn = false
            self.loginState = .idle
        }
        sendCommand("logout") { [weak self] _, _, _ in
            guard let self else { return }
            self.deleteKeychainValue(account: self.refreshTokenAccount(username))
            self.deleteKeychainValue(account: self.guardDataAccount(username))
            self.savedUsername = ""
            self.restoringSession = false
            self.updateOnMain {
                self.isLoggedIn = false
                self.accountName = ""
                self.loginState = .idle
                self.authenticationState = .needsAction(L("需要登录 Steam"))
                completion(.success(()))
            }
        }
    }

    func downloadItem(workshopId: String, onProgress: @escaping (DownloadState) -> Void) {
        ioQueue.async { [weak self] in
            guard let self else { return }
            self.downloadHandlers[workshopId] = onProgress
            self.sendCommandOnQueue("download", fields: [
                "taskId": workshopId,
                "workshopId": workshopId,
                "outputRoot": self.contentDirectory.path
            ]) { success, message, errorCode in
                if !success {
                    let handler = self.downloadHandlers.removeValue(forKey: workshopId)
                    let localized = self.localizedError(code: errorCode, detail: message)
                    self.updateOnMain { handler?(.failed(localized)) }
                }
            }
        }
    }

    func cancelDownload(workshopId: String) {
        sendCommand("cancelDownload", fields: ["taskId": workshopId])
    }

    func downloadedItemDirectory(workshopId: String) -> URL? {
        let url = contentDirectory.appending(path: workshopId, directoryHint: .isDirectory)
        return FileManager.default.fileExists(atPath: url.appending(path: "project.json").path) ? url : nil
    }

    func shutdown() {
        explicitShutdown = true
        ioQueue.sync {
            guard let process else { return }
            sendCommandOnQueue("shutdown")
            try? input?.close()
            let deadline = Date().addingTimeInterval(1.5)
            while process.isRunning && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }
            if process.isRunning { process.terminate() }
            self.process = nil
            input = nil
        }
    }

    private func startOnQueue() {
        guard process?.isRunning != true else { return }
        guard let executable = serviceExecutableURL() else {
            updateOnMain {
                self.isAvailable = false
                self.authenticationState = .unavailable(L("Steam 服务组件不可用"))
            }
            return
        }
        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = executable
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.terminationHandler = { [weak self] process in
            self?.ioQueue.async {
                self?.handleTermination(status: process.terminationStatus)
            }
        }
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.ioQueue.async { self?.consumeOutput(data) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            MirageLogService.shared.append(text, source: "steam-service")
        }
        do {
            try process.run()
            self.process = process
            input = stdinPipe.fileHandleForWriting
            explicitShutdown = false
            updateOnMain {
                self.isAvailable = true
                self.authenticationState = .checking
            }
            sendCommandOnQueue("hello")
            restoreSessionOnQueue()
        } catch {
            updateOnMain {
                self.isAvailable = false
                self.authenticationState = .unavailable(L("Steam 服务启动失败：%@", error.localizedDescription))
            }
        }
    }

    private func serviceExecutableURL() -> URL? {
        if let configured = ProcessInfo.processInfo.environment["MIRAGE_STEAM_SERVICE_PATH"], !configured.isEmpty {
            let url = URL(fileURLWithPath: configured)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        return nil
        #endif
        return Bundle.main.url(
            forResource: "MirageSteamService",
            withExtension: nil,
            subdirectory: "SteamService/\(architecture)"
        )
    }

    private func restoreSessionOnQueue() {
        let username = savedUsername
        guard !username.isEmpty, let token = keychainValue(account: refreshTokenAccount(username)) else {
            updateOnMain {
                self.authenticationState = .needsAction(L("需要登录 Steam"))
                self.loginState = .idle
            }
            return
        }
        restoringSession = true
        sendCommandOnQueue("restoreSession", fields: [
            "username": username,
            "refreshToken": token
        ]) { [weak self] success, message, errorCode in
            guard let self, !success else { return }
            self.restoringSession = false
            self.failAuthenticationRequest(code: errorCode, detail: message)
        }
    }

    private func sendCommand(_ command: String, fields: [String: Any] = [:], completion: ((Bool, String?, String?) -> Void)? = nil) {
        ioQueue.async { [weak self] in
            self?.sendCommandOnQueue(command, fields: fields, completion: completion)
        }
    }

    private func sendCommandOnQueue(_ command: String, fields: [String: Any] = [:], completion: ((Bool, String?, String?) -> Void)? = nil) {
        guard process?.isRunning == true, let input else {
            completion?(false, L("Steam 服务组件不可用"), nil)
            return
        }
        let requestId = UUID().uuidString
        var payload = fields.filter { !($0.value is NSNull) }
        payload["command"] = command
        payload["requestId"] = requestId
        if let completion { requestHandlers[requestId] = completion }
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload),
              var line = String(data: data, encoding: .utf8) else {
            requestHandlers.removeValue(forKey: requestId)
            completion?(false, L("Steam 服务请求无法编码"), nil)
            return
        }
        line.append("\n")
        do {
            try input.write(contentsOf: Data(line.utf8))
        } catch {
            requestHandlers.removeValue(forKey: requestId)
            completion?(false, error.localizedDescription, nil)
        }
    }

    private func consumeOutput(_ data: Data) {
        outputBuffer.append(data)
        while let newline = outputBuffer.firstIndex(of: 0x0A) {
            let line = outputBuffer[..<newline]
            outputBuffer.removeSubrange(...newline)
            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            handleEvent(object)
        }
    }

    private func handleEvent(_ event: [String: Any]) {
        guard let type = event["type"] as? String else { return }
        switch type {
        case "hello":
            updateOnMain { self.isAvailable = true }
        case "response":
            guard let requestId = event["requestId"] as? String,
                  let handler = requestHandlers.removeValue(forKey: requestId) else { return }
            handler(event["success"] as? Bool == true, event["message"] as? String, event["errorCode"] as? String)
        case "authState":
            handleAuthEvent(event)
        case "downloadState":
            handleDownloadEvent(event)
        default:
            break
        }
    }

    private func handleAuthEvent(_ event: [String: Any]) {
        guard let state = event["state"] as? String else { return }
        let username = event["accountName"] as? String
        let detail = event["message"] as? String
        let errorCode = event["errorCode"] as? String
        switch state {
        case "connecting", "authenticating":
            updateOnMain {
                self.loginState = .loggingIn
                self.authenticationState = .checking
            }
        case "qr":
            if let challenge = event["challengeUrl"] as? String {
                updateOnMain { self.loginState = .waitingForQR(challenge) }
            }
        case "waitingMobile":
            updateOnMain { self.loginState = .waitingForGuard(.mobileConfirm) }
        case "mobileCode":
            updateOnMain { self.loginState = .waitingForGuard(.mobile) }
        case "emailCode":
            updateOnMain { self.loginState = .waitingForGuard(.email) }
        case "loggedIn":
            let resolvedUsername = username ?? savedUsername
            if let token = event["refreshToken"] as? String, !token.isEmpty {
                setKeychainValue(token, account: refreshTokenAccount(resolvedUsername))
            }
            if let guardData = event["guardData"] as? String, !guardData.isEmpty {
                setKeychainValue(guardData, account: guardDataAccount(resolvedUsername))
            }
            savedUsername = resolvedUsername
            restoringSession = false
            updateOnMain {
                self.isLoggedIn = true
                self.accountName = resolvedUsername
                self.loginState = .success
                self.authenticationState = .available(L("会话已验证"))
            }
        case "failed":
            var message = localizedError(code: errorCode, detail: detail)
            if restoringSession {
                let username = savedUsername
                deleteKeychainValue(account: refreshTokenAccount(username))
                restoringSession = false
                if errorCode == "AUTH_FAILED" {
                    message = L("保存的 Steam 会话已失效，请重新登录")
                }
            }
            updateOnMain {
                self.isLoggedIn = false
                self.loginState = .failed(message)
                self.authenticationState = .unavailable(message)
            }
        case "loggedOut":
            if errorCode == "AUTH_CANCELLED" { return }
            let message = errorCode == nil && (detail?.isEmpty != false)
                ? L("需要登录 Steam")
                : localizedError(code: errorCode, detail: detail)
            updateOnMain {
                self.isLoggedIn = false
                self.loginState = .idle
                self.authenticationState = .needsAction(message)
            }
        default:
            break
        }
    }

    private func handleDownloadEvent(_ event: [String: Any]) {
        guard let taskId = event["taskId"] as? String,
              let state = event["state"] as? String,
              let handler = downloadHandlers[taskId] else { return }
        let next: DownloadState
        switch state {
        case "resolving":
            next = .resolving
        case "downloading":
            next = .downloading(DownloadProgress(
                receivedBytes: int64(event["receivedBytes"]),
                totalBytes: int64(event["totalBytes"]),
                bytesPerSecond: event["bytesPerSecond"] as? Double ?? 0,
                etaSeconds: event["etaSeconds"] as? Double
            ))
        case "validating":
            next = .validating
        case "completed":
            next = .completed
            downloadHandlers.removeValue(forKey: taskId)
        case "cancelled":
            next = .failed(L("下载已取消"))
            downloadHandlers.removeValue(forKey: taskId)
        case "failed":
            next = .failed(localizedError(code: event["errorCode"] as? String, detail: event["message"] as? String))
            downloadHandlers.removeValue(forKey: taskId)
        default:
            return
        }
        updateOnMain { handler(next) }
    }

    private func handleTermination(status: Int32) {
        process = nil
        input = nil
        outputBuffer.removeAll(keepingCapacity: true)
        let handlers = Array(downloadHandlers.values)
        let requests = Array(requestHandlers.values)
        downloadHandlers.removeAll()
        requestHandlers.removeAll()
        guard !explicitShutdown else { return }
        for request in requests { request(false, L("Steam 服务连接已中断"), "CONNECTION_LOST") }
        updateOnMain {
            self.isAvailable = false
            self.isLoggedIn = false
            self.loginState = .failed(L("Steam 服务意外退出（状态 %@）", String(status)))
            self.authenticationState = .unavailable(L("Steam 服务组件不可用"))
            for handler in handlers { handler(.failed(L("Steam 服务连接已中断"))) }
        }
    }

    private func failAuthenticationRequest(code: String?, detail: String?) {
        let message = localizedError(code: code, detail: detail)
        updateOnMain {
            self.isLoggedIn = false
            self.loginState = .failed(message)
            self.authenticationState = .unavailable(message)
        }
    }

    private func localizedError(code: String?, detail: String?) -> String {
        switch code {
        case "AUTH_FAILED": return L("Steam 登录失败，请检查账户信息或重新扫码")
        case "AUTH_SERVICE_TEMPORARY": return L("Steam 认证服务暂时未响应，请稍后重试")
        case "CONNECTION_LOST": return L("Steam 连接已中断")
        case "APP_INFO_UNAVAILABLE", "CONTENT_ACCESS_DENIED": return L("当前 Steam 账号无法访问 Wallpaper Engine 内容，请确认已拥有该应用")
        case "WORKSHOP_DETAILS_UNAVAILABLE": return L("Steam 未返回该创意工坊作品的有效信息")
        case "WRONG_APP": return L("该作品不属于 Wallpaper Engine 创意工坊")
        case "CONTENT_MANIFEST_MISSING", "WORKSHOP_DEPOT_MISSING", "MANIFEST_ACCESS_DENIED", "EMPTY_MANIFEST": return L("无法解析该创意工坊作品的下载内容")
        case "NO_CONTENT_SERVER", "CHUNK_DOWNLOAD_FAILED": return L("Steam 内容服务器下载失败，请稍后重试")
        case "VALIDATION_FAILED": return L("下载内容校验失败，请重试")
        case "PROJECT_JSON_MISSING": return L("下载内容中缺少 project.json")
        case "UNSAFE_PATH", "UNSUPPORTED_SYMLINK": return L("下载内容包含不安全的文件路径")
        case "NOT_AUTHENTICATED": return L("Steam 会话不可用，请重新登录")
        case "AUTH_CANCELLED": return L("登录已取消")
        case "DOWNLOAD_CANCELLED": return L("下载已取消")
        default:
            if let detail, !detail.isEmpty { return L("Steam 服务错误：%@", detail) }
            return L("Steam 服务操作失败")
        }
    }

    private func int64(_ value: Any?) -> Int64 {
        if let number = value as? NSNumber { return number.int64Value }
        return 0
    }

    private func updateOnMain(_ block: @escaping () -> Void) {
        DispatchQueue.main.async(execute: block)
    }

    private func refreshTokenAccount(_ username: String) -> String { "refresh-token:\(username.lowercased())" }
    private func guardDataAccount(_ username: String) -> String { "guard-data:\(username.lowercased())" }

    private func keychainValue(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func setKeychainValue(_ value: String, account: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
            var item = query
            item.merge(attributes) { _, new in new }
            SecItemAdd(item as CFDictionary, nil)
        }
    }

    private func deleteKeychainValue(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
