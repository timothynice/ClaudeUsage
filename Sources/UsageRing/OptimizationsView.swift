import SwiftUI

/// The three token-optimization checkboxes. Each writes (reversibly) to the
/// user's global Claude Code config; the checkbox state is read back from that
/// config, so it reflects reality even if edited elsewhere.
struct OptimizationsView: View {
    private let manager = OptimizationManager()
    @State private var enabled: [String: Bool] = [:]
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Image(systemName: "bolt.fill").font(.system(size: 10))
                Text("Token optimization").font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(.secondary)

            ForEach(OptimizationManager.Optimization.allCases) { optimization in
                Toggle(isOn: binding(for: optimization)) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(optimization.title).font(.system(size: 12))
                        Text(optimization.subtitle)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.checkbox)
            }

            if let errorText {
                Text(errorText).font(.caption2).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Applies to all Claude Code work on this Mac. Changes take effect on the next session.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear(perform: refresh)
    }

    private func binding(for optimization: OptimizationManager.Optimization) -> Binding<Bool> {
        Binding(
            get: { enabled[optimization.id] ?? manager.isEnabled(optimization) },
            set: { newValue in
                do {
                    try manager.setEnabled(optimization, newValue)
                    enabled[optimization.id] = newValue
                    errorText = nil
                } catch {
                    // Reflect the true on-disk state rather than the attempted flip.
                    enabled[optimization.id] = manager.isEnabled(optimization)
                    errorText = "Couldn't update \(optimization.title). Check ~/.claude permissions."
                }
            })
    }

    private func refresh() {
        for optimization in OptimizationManager.Optimization.allCases {
            enabled[optimization.id] = manager.isEnabled(optimization)
        }
    }
}
