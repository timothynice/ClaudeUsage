import SwiftUI
import AppKit
import ServiceManagement

struct StatsView: View {
    @ObservedObject var model: UsageModel
    @AppStorage("showPercentInMenuBar") private var showPercent = false
    @State private var launchAtLogin = false
    @State private var launchAtLoginError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let error = model.lastError {
                ErrorBanner(
                    error: error,
                    isAwaitingSignIn: model.isAwaitingSignIn,
                    launchFailed: model.signInLaunchFailed,
                    onSignIn: { model.beginSignIn() })
            }
            if let snapshot = model.snapshot {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(snapshot.windows) { window in
                        UsageRow(window: window)
                    }
                    if let credits = snapshot.credits {
                        CreditsRow(credits: credits)
                    }
                }
            } else if model.lastError == nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading usage…").font(.callout).foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            }
            Divider()
            settings
            footer
        }
        .padding(14)
        .frame(width: 330)
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            Task { await model.refresh() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text("Claude usage")
                    .font(.system(size: 14, weight: .semibold))
                if let badge = model.accountBadge {
                    Text(badge.uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                        .foregroundStyle(Color.accentColor)
                }
                Spacer()
                if model.isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        Task { await model.refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Refresh now")
                }
            }
            if let profile = model.profile {
                Text([profile.organization, profile.email].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Show percentage in menu bar", isOn: $showPercent)
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in
                    setLaunchAtLogin(enabled)
                }
            if let launchAtLoginError {
                Text(launchAtLoginError)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.checkbox)
        .font(.system(size: 12))
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let updated = model.lastUpdated {
                Text("Updated \(updated.formatted(date: .omitted, time: .standard))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Link("claude.ai", destination: URL(string: "https://claude.ai/settings/usage")!)
                .font(.caption)
            Button("Quit") { NSApp.terminate(nil) }
                .font(.caption)
                .keyboardShortcut("q")
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = "Launch at login needs the installed app (`make install`)."
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

struct UsageRow: View {
    let window: UsageWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(window.label)
                    .font(.system(size: 12.5, weight: .medium))
                Spacer()
                if let resets = window.resetsAt {
                    Text(Self.resetText(resets))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("\(Int(window.utilization.rounded()))%")
                    .font(.system(size: 12.5, weight: .semibold))
                    .monospacedDigit()
            }
            UsageBar(fraction: window.fraction, color: StatusColor.color(for: window.utilization))
        }
    }

    static func resetText(_ date: Date) -> String {
        let seconds = date.timeIntervalSinceNow
        if seconds <= 30 { return "Resets soon" }
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes < 60 { return "Resets in \(minutes) min" }
        if seconds < 86_400 {
            let hours = minutes / 60
            let rest = minutes % 60
            return rest == 0 ? "Resets in \(hours)h" : "Resets in \(hours)h \(rest)m"
        }
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEE j:mm")
        return "Resets \(formatter.string(from: date))"
    }
}

struct CreditsRow: View {
    let credits: CreditsInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Usage credits")
                    .font(.system(size: 12.5, weight: .medium))
                Spacer()
                Text("\(dollars(credits.usedUSD)) of \(dollars(credits.limitUSD))")
                    .font(.system(size: 12.5, weight: .semibold))
                    .monospacedDigit()
            }
            // No credit headroom reads as "exhausted" (full red bar), matching
            // Claude Code's own usage panel.
            if credits.limitUSD > 0 {
                let pct = min(credits.usedUSD / credits.limitUSD, 1) * 100
                UsageBar(fraction: pct / 100, color: StatusColor.color(for: pct))
            } else {
                UsageBar(fraction: 1, color: StatusColor.color(for: 100))
            }
        }
    }

    private func dollars(_ value: Double) -> String {
        String(format: "$%.2f", value)
    }
}

struct UsageBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                if fraction > 0 {
                    Capsule()
                        .fill(color)
                        .frame(width: max(6, geo.size.width * min(max(fraction, 0), 1)))
                }
            }
        }
        .frame(height: 6)
    }
}

struct ErrorBanner: View {
    let error: FetchError
    var isAwaitingSignIn: Bool = false
    var launchFailed: Bool = false
    var onSignIn: (() -> Void)?

    @State private var isHovering = false

    private var isActionable: Bool {
        error.isSignInFixable && onSignIn != nil && !isAwaitingSignIn
    }

    var body: some View {
        if isActionable {
            Button { onSignIn?() } label: { banner }
                .buttonStyle(.plain)
                .onHover { hovering in
                    isHovering = hovering
                    if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
                .accessibilityLabel("Sign in to Claude Code")
                .accessibilityHint("Opens the claude auth login flow in Terminal")
                .help("Opens `claude auth login` in Terminal")
        } else {
            banner
        }
    }

    private var banner: some View {
        VStack(alignment: .leading, spacing: 5) {
            if isAwaitingSignIn {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for sign-in to finish…")
                        .font(.system(size: 12, weight: .semibold))
                }
                Text("Complete the login in the Terminal window that opened. This panel updates on its own.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Label(error.title, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.orange)
                Text(error.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if launchFailed {
                    Text("Couldn't open Terminal automatically — run `claude auth login` yourself.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else if isActionable {
                    // Only advertise the button when it actually does something.
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.forward.app.fill")
                        Text("Sign in to Claude Code")
                    }
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.accentColor.opacity(isHovering ? 1.0 : 0.85)))
                    .padding(.top, 2)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(Color.orange.opacity(isHovering && isActionable ? 0.16 : 0.1)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.25), lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}
