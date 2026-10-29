import SwiftUI

/// A game's settings from its app's launcher.json, kept where the app reads them (its saved choices): the same settings the app's own window shows,
/// also used when the app is opened from Finder or the Dock
struct SettingsFormView: View {
    let app: AppBundle
    var running = false
    @State private var settings: GameSettings?
    @State private var showAdvanced = false
    @State private var revision = 0

    var body: some View {
        let _ = revision
        VStack(alignment: .leading, spacing: 16) {
            if let s = settings {
                let hasLevels = s.list.settings.contains { $0.isBasic }
                ForEach(s.list.sections, id: \.self) { section in
                    let rows = s.list.settings.filter { $0.section == section && $0.kind != .unknown && s.visible($0) && (!hasLevels || $0.isBasic || showAdvanced) }
                    if !rows.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(LS(section)).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                            ForEach(rows) { row in
                                SettingRow(setting: row, settings: s) { revision += 1 }
                            }
                        }
                    }
                }
                HStack {
                    if hasLevels {
                        Toggle("Advanced settings", isOn: $showAdvanced).toggleStyle(.switch).controlSize(.small)
                    }
                    Spacer()
                    Button("Reset to Tested Defaults") { s.saved.resetAll(s.list); revision += 1 }
                        .disabled(!s.list.settings.contains { s.isChanged($0) })
                }
                Text(LocalizedStringKey(running ? "The game is running: changes apply the next time it starts." : "Saved in the game's app: they also apply when you open it from Finder or the Dock."))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("This app has no settings list: it was built before nxnative wrote one. Rebuild it to get its settings here.")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { settings = GameSettings(app: app) }
        .onChange(of: app) { settings = GameSettings(app: app) }
    }
}

private struct SettingRow: View {
    let setting: Setting
    let settings: GameSettings
    let changed: () -> Void

    var body: some View {
        let fixed = settings.fixed[setting.env]
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(LS(setting.label))
                    if !setting.note.isEmpty { Text(LS(setting.note)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }
                Spacer(minLength: 16)
                control.disabled(fixed != nil)
            }
            if let f = fixed {
                Text(LF("Set to %@ by %@", f.value, f.source)).font(.caption).foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder private var control: some View {
        switch setting.kind {
        case .choice:
            Picker("", selection: Binding(get: { settings.current(setting) }, set: { settings.set(setting, $0); changed() })) {
                ForEach(setting.choices, id: \.self) { c in Text(LS(c.label)).tag(c.value) }
            }
            .labelsHidden()
            .fixedSize()
        case .toggle:
            Toggle("", isOn: Binding(get: { settings.current(setting) == setting.on },
                                     set: { settings.set(setting, $0 ? (setting.on ?? "1") : (setting.off ?? "0")); changed() }))
                .labelsHidden()
                .toggleStyle(.switch)
        case .range:
            let lo = setting.min ?? 0, hi = Swift.max(setting.max ?? 1, lo + 0.0001)
            let value = Double(settings.current(setting)) ?? Double(setting.default) ?? lo
            HStack(spacing: 10) {
                Slider(value: Binding(get: { value }, set: { settings.set(setting, setting.format($0)); changed() }), in: lo...hi, step: setting.step ?? 0.05)
                    .frame(width: 180)
                Text(rangeLabel(value)).monospacedDigit().frame(minWidth: 70, alignment: .trailing)
            }
        case .unknown:
            EmptyView()
        }
    }

    /// The value, and for the render scale the size it gives (from the profile's base size)
    private func rangeLabel(_ v: Double) -> String {
        let s = setting.format(v)
        if let b = setting.base, b.docked.count == 2 {
            return "\(s) · \(Int((Double(b.docked[0]) * v).rounded()))×\(Int((Double(b.docked[1]) * v).rounded()))"
        }
        return s
    }
}
