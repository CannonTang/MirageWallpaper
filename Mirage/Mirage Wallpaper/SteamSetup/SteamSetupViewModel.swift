//
//  Mirage Wallpaper
//
//  Copyright © 2026 王孝慈. All rights reserved.
//

import SwiftUI
import Combine

class SteamSetupViewModel: ObservableObject {
    @Published var currentStep = 0
    @Published var loginState: SteamLoginState = .idle
    @Published var username = ""
    @Published var password = ""
    @Published var guardCode = ""
    @Published var errorMessage: String?
    @Published private(set) var guardWaitElapsed = 0
    @Published private(set) var reusableSessionUsername: String?

    private var guardWaitStartedAt: Date?
    private var guardWaitTimer: Timer?
    private var qrChallenge = ""
    private var qrChallengeUpdatedAt: Date?
    private var qrRefreshTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    let totalSteps = 3

    var canProceed: Bool {
        switch currentStep {
        case 0, 2: return true
        case 1: return loginState == .success
        default: return false
        }
    }

    init() {
        let manager = SteamServiceManager.shared
        username = manager.savedUsername
        reusableSessionUsername = manager.isLoggedIn ? manager.accountName : nil
        loginState = manager.loginState
        manager.$loginState
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                self?.applyLoginState(state)
            }
            .store(in: &cancellables)
        manager.$isLoggedIn
            .receive(on: RunLoop.main)
            .sink { [weak self] isLoggedIn in
                guard let self else { return }
                self.reusableSessionUsername = isLoggedIn ? manager.accountName : nil
                if isLoggedIn && !manager.accountName.isEmpty { self.username = manager.accountName }
            }
            .store(in: &cancellables)
    }

    func useSavedSession() {
        guard SteamServiceManager.shared.isLoggedIn else {
            errorMessage = L("保存的 Steam 会话已失效，请重新登录")
            return
        }
        username = SteamServiceManager.shared.accountName
        loginState = .success
        errorMessage = nil
    }

    func startQRLogin() {
        stopQRRefreshWatchdog()
        errorMessage = nil
        password = ""
        SteamServiceManager.shared.loginWithQR()
    }

    func refreshQRCode() {
        stopQRRefreshWatchdog()
        errorMessage = nil
        SteamServiceManager.shared.loginWithQR()
    }

    func login() {
        guard !username.isEmpty, !password.isEmpty else {
            errorMessage = L("请输入用户名和密码")
            return
        }
        errorMessage = nil
        SteamServiceManager.shared.login(username: username, password: password)
    }

    func submitGuardCode() {
        let code = guardCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else {
            errorMessage = L("请输入验证码")
            return
        }
        guard SteamServiceManager.shared.submitGuardCode(code) else {
            errorMessage = L("Steam Guard 会话已结束，请重新登录")
            return
        }
        guardCode = ""
        errorMessage = nil
        loginState = .loggingIn
    }

    func cancelLogin() {
        SteamServiceManager.shared.cancelLogin()
        stopGuardWaitUpdates()
        stopQRRefreshWatchdog()
        password = ""
        guardCode = ""
        loginState = SteamServiceManager.shared.loginState
        errorMessage = nil
    }

    func cancelPendingWork() {
        if !SteamServiceManager.shared.isLoggedIn { SteamServiceManager.shared.cancelLogin() }
        stopGuardWaitUpdates()
        stopQRRefreshWatchdog()
        password = ""
        guardCode = ""
    }

    func reset() {
        cancelPendingWork()
        currentStep = 0
        loginState = SteamServiceManager.shared.loginState
        errorMessage = nil
        username = SteamServiceManager.shared.savedUsername
    }

    func completeSetup() {}

    func nextStep() {
        guard currentStep < totalSteps - 1 else { return }
        currentStep += 1
    }

    func previousStep() {
        guard currentStep > 0 else { return }
        if currentStep == 1 && !SteamServiceManager.shared.isLoggedIn { cancelLogin() }
        currentStep -= 1
    }

    private func applyLoginState(_ state: SteamLoginState) {
        loginState = state
        switch state {
        case .waitingForGuard(.mobileConfirm):
            stopQRRefreshWatchdog()
            startGuardWaitUpdates()
        case .failed(let message):
            stopGuardWaitUpdates()
            stopQRRefreshWatchdog()
            errorMessage = message
        case .success:
            stopGuardWaitUpdates()
            stopQRRefreshWatchdog()
            errorMessage = nil
            password = ""
            guardCode = ""
            username = SteamServiceManager.shared.accountName
            if currentStep == 1 { currentStep = 2 }
        case .waitingForQR(let challenge):
            stopGuardWaitUpdates()
            startQRRefreshWatchdog(challenge: challenge)
            errorMessage = nil
        case .waitingForGuard:
            stopQRRefreshWatchdog()
            errorMessage = nil
        case .idle, .loggingIn:
            stopGuardWaitUpdates()
            stopQRRefreshWatchdog()
        }
    }

    private func startQRRefreshWatchdog(challenge: String) {
        if qrChallenge != challenge {
            qrChallenge = challenge
            qrChallengeUpdatedAt = Date()
        }
        guard qrRefreshTimer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self,
                  case .waitingForQR = self.loginState,
                  let updatedAt = self.qrChallengeUpdatedAt,
                  Date().timeIntervalSince(updatedAt) >= 30 else { return }
            self.refreshQRCode()
        }
        qrRefreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopQRRefreshWatchdog() {
        qrRefreshTimer?.invalidate()
        qrRefreshTimer = nil
        qrChallenge = ""
        qrChallengeUpdatedAt = nil
    }

    private func startGuardWaitUpdates() {
        guard guardWaitTimer == nil else { return }
        guardWaitStartedAt = Date()
        guardWaitElapsed = 0
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, let startedAt = self.guardWaitStartedAt else { return }
            self.guardWaitElapsed = max(0, Int(Date().timeIntervalSince(startedAt)))
        }
        guardWaitTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopGuardWaitUpdates() {
        guardWaitTimer?.invalidate()
        guardWaitTimer = nil
        guardWaitStartedAt = nil
        guardWaitElapsed = 0
    }

    deinit {
        guardWaitTimer?.invalidate()
        qrRefreshTimer?.invalidate()
    }
}
