import SwiftUI
import AppKit

@MainActor
final class UsageModel: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var profile: ProfileInfo?
    @Published private(set) var lastError: FetchError?
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var isRefreshing = false
    @Published private(set) var isAwaitingFix = false
    @Published private(set) var fixLaunchFailed = false

    private let client = UsageClient()
    private var pollTask: Task<Void, Never>?
    /// While set, poll every few seconds so the ring lights up promptly after
    /// the user finishes the fix.
    private var fastPollUntil: Date?

    /// Poll interval in seconds; override with `defaults write com.usagering.app refreshSeconds 30`.
    var refreshInterval: TimeInterval {
        let v = UserDefaults.standard.double(forKey: "refreshSeconds")
        return v >= 15 ? v : 60
    }

    init() {
        startPolling()
    }

    func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                let interval = self.nextPollInterval()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    /// Runs the banner's fix in Terminal: the official `claude auth login`
    /// flow, or a keychain lock/unlock where macOS asks for the password.
    /// Either way the app never handles credentials.
    func beginFix(_ action: FixAction) {
        let launched: Bool
        switch action {
        case .signIn: launched = LoginLauncher.launch()
        case .unlockKeychain: launched = KeychainUnlockLauncher.launch()
        }
        fixLaunchFailed = !launched
        guard launched else { return }
        isAwaitingFix = true
        fastPollUntil = Date().addingTimeInterval(300)
        startPolling()
    }

    private func nextPollInterval() -> TimeInterval {
        guard let fastPollUntil else { return refreshInterval }
        if Date() < fastPollUntil { return 5 }
        // Window elapsed without a successful fix; fall back to normal pace.
        self.fastPollUntil = nil
        isAwaitingFix = false
        return refreshInterval
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let snap = try await client.fetchUsage()
            snapshot = snap
            lastUpdated = Date()
            lastError = nil
            isAwaitingFix = false
            fixLaunchFailed = false
            fastPollUntil = nil
            if profile == nil {
                profile = try? await client.fetchProfile()
            }
        } catch let error as FetchError {
            lastError = error
        } catch {
            lastError = .network(error.localizedDescription)
        }
    }

    var statusIcon: NSImage {
        if let five = snapshot?.fiveHour {
            return RingIcon.ring(fraction: five.fraction, color: StatusColor.nsColor(for: five.utilization))
        }
        return RingIcon.attention()
    }

    var accountBadge: String? {
        snapshot?.accountType
    }
}
