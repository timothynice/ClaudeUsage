import SwiftUI
import AppKit

/// Entry point. In `--hook <name>` mode we run the hook synchronously and exit
/// without launching the menu bar UI; otherwise the normal app starts.
@main
enum Main {
    static func main() {
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--hook"), index + 1 < args.count {
            HookCLI.run(event: args[index + 1])
            return
        }
        UsageRingApp.main()
    }
}

struct UsageRingApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = UsageModel()

    var body: some Scene {
        MenuBarExtra {
            StatsView(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar only — no Dock icon, no app switcher entry.
        NSApp.setActivationPolicy(.accessory)
    }
}

struct MenuBarLabel: View {
    @ObservedObject var model: UsageModel
    @AppStorage("showPercentInMenuBar") private var showPercent = false

    var body: some View {
        Image(nsImage: model.statusIcon)
        if showPercent, let pct = model.snapshot?.fiveHour?.utilization {
            Text("\(Int(pct.rounded()))%")
        }
    }
}
