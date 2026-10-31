import AppKit
import Combine
import DroppyKit
import IOKit.ps
import SwiftUI


struct EngineStatus: Decodable {
    struct Charging: Decodable { let pluggedIn: Bool; let allowCharging: Bool? }
    struct Battery: Decodable { let currentChargePercent: Int; let state: String }
    struct Configuration: Decodable { let enabled: Bool; let upperLimitPercent: Int; let lowerLimitPercent: Int }
    struct Compatibility: Decodable { let chargingControl: Bool; let chargeControlMode: String }
    let charging: Charging
    let battery: Battery
    let configuration: Configuration
    let compatibility: Compatibility
}

struct CommandFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// Run outside Droppy's main actor. No shell is used for routine controls.
enum Engine {
    static let executable = "/Library/PrivilegedHelperTools/local.chargeguard.batt"
    static let config = "/Library/Application Support/ChargeGuard/batt.json"
    static let socket = "/var/run/chargeguard-batt.sock"
    static func run(_ args: [String], executable: String = executable, timeout: Double = 15) async throws -> Data {
        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = args
            let out = Pipe(), err = Pipe()
            process.standardOutput = out; process.standardError = err
            try process.run()
            let timeoutWork = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutWork)
            process.waitUntilExit()
            timeoutWork.cancel()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let errors = err.fileHandleForReading.readDataToEndOfFile()
            guard process.terminationStatus == 0 else {
                throw CommandFailure(message: String(data: errors.isEmpty ? data : errors, encoding: .utf8) ?? "Le moteur ne répond pas.")
            }
            return data
        }.value
    }
    static func command(_ args: [String]) async throws -> Data {
        try await run(["--config", config, "--daemon-socket", socket] + args)
    }
    static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static func administer(_ script: URL, action: String) async throws {
        // Privileged osascript cannot read a script under protected Documents.
        // Stage the two fixed installer files in a fresh temporary directory.
        let fm = FileManager.default
        let stage = fm.temporaryDirectory.appendingPathComponent("ChargeGuard-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stage) }
        let stagedScript = stage.appendingPathComponent("setup.sh")
        try fm.copyItem(at: script, to: stagedScript)
        try fm.copyItem(at: script.deletingLastPathComponent().appendingPathComponent("batt"), to: stage.appendingPathComponent("batt"))
        let shell = "/bin/bash " + shellQuote(stagedScript.path) + " " + shellQuote(action)
        let literal = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        _ = try await run(["-e", "do shell script \"\(literal)\" with administrator privileges"], executable: "/usr/bin/osascript", timeout: 300)
    }
}

@objc(ChargeguardPrincipal)
public final class ChargeguardPrincipal: NSObject, DropletPrincipal {
    public override init() { super.init() }
    @MainActor public func makeDroplet() -> AnyObject { ChargeguardDroplet() }
}

@MainActor
public final class ChargeguardDroplet: NSObject, ObservableObject, Droplet {
    public nonisolated static let id: DropletID = "chargeguard"
    @Published var lower = 20.0
    @Published var upper = 80.0
    @Published var percent: Int?
    @Published var plugged = false
    @Published var charging = false
    @Published var enabled = false
    @Published var ready = false
    @Published var supported = true
    @Published var busy = false
    @Published var error: String?
    @Published var message = "Installation du moteur requise"
    @Published var pin = false
    @Published var appliedLower = 20
    @Published var appliedUpper = 80
    private var host: DropletHost?
    private var timer: Timer?
    private var work: Task<Void, Never>?
    private var polling = false
    private var active = false
    private let activity = CurrentValueSubject<LiveActivityState?, Never>(nil)
    private var demo = false
    private var controlMode = "legacy"
    var range: ChargeRange { ChargeRange(lower: Int(lower), upper: Int(upper)) }
    var hasPendingThresholds: Bool { Int(lower) != appliedLower || Int(upper) != appliedUpper }
    func setEditingThresholds(_ editing: Bool) { host?.shelf.setHoldsOpen(editing) }
    func discardThresholdChanges() { lower = Double(appliedLower); upper = Double(appliedUpper) }
    var tint: Color { error != nil ? .orange : (enabled ? .green : .secondary) }
    var statusTitle: String {
        if !ready { return "À configurer" }
        if !supported { return "Mac non compatible" }
        if !enabled { return "Charge libre" }
        if !plugged { return "Sur batterie" }
        return charging ? "Recharge en cours" : "Charge suspendue"
    }

    public func activate(host: DropletHost) throws {
        self.host = host; active = true; demo = host.environment.isHarness
        lower = host.preferences.value(forKey: "lower", default: 20.0)
        upper = host.preferences.value(forKey: "upper", default: 80.0)
        if !range.valid { lower = 20; upper = 80 }
        appliedLower = Int(lower); appliedUpper = Int(upper)
        pin = host.preferences.value(forKey: "pin", default: false)
        if demo {
            percent = 64; plugged = true; enabled = true; ready = true
            message = "La charge reprendra à 20 % et s’arrêtera à 80 %."
            publishActivity(); return
        }
        readBattery()
        work = Task { [weak self] in await self?.refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refresh() }
        }
    }
    public func deactivate() {
        host?.shelf.setHoldsOpen(false)
        active = false; timer?.invalidate(); timer = nil; work?.cancel(); work = nil
        activity.send(nil); host = nil
        // The explicitly installed system daemon retains the configured limits.
        // Disabling the widget must not silently remove battery protection.
    }
    func settings() { _ = host?.workspace.openSettings() }
    func setPin(_ value: Bool) {
        pin = value; host?.preferences.setValue(value, forKey: "pin"); publishActivity()
    }
    private func publishActivity() {
        activity.send(ready && enabled ? LiveActivityState(priority: 5, accessibilityTitle: "Batterie, \(percent ?? 0) pour cent", joinsPersistentActivitySet: pin) : nil)
    }
    private func readBattery() {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return }
        for source in list {
            guard let value = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  value[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = value[kIOPSCurrentCapacityKey] as? Int,
                  let max = value[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            percent = current * 100 / max
            plugged = value[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            charging = value[kIOPSIsChargingKey] as? Bool ?? false
        }
    }
    func refresh() async {
        guard active, !demo, !polling, !busy else { return }
        polling = true; defer { polling = false }
        readBattery()
        guard FileManager.default.isExecutableFile(atPath: Engine.executable) else {
            ready = false; message = "Installez le moteur pour contrôler réellement la charge."; publishActivity(); return
        }
        do {
            let data = try await Engine.command(["status", "--json"])
            let state = try JSONDecoder().decode(EngineStatus.self, from: data)
            guard active else { return }
            ready = true; supported = state.compatibility.chargingControl
            controlMode = state.compatibility.chargeControlMode
            percent = state.battery.currentChargePercent; plugged = state.charging.pluggedIn
            charging = state.battery.state == "charging"; enabled = state.configuration.enabled
            if enabled {
                appliedUpper = state.configuration.upperLimitPercent
                appliedLower = state.configuration.lowerLimitPercent - (controlMode == "legacy" ? 1 : 0)
            }
            message = !supported ? "Ce firmware ne permet pas au moteur de contrôler la charge." : (enabled ? "La protection continue même si Droppy est fermé." : "Charge libre. Après une pause de 2 h, les seuils reviennent automatiquement.")
            publishActivity()
        } catch {
            guard active else { return }
            ready = false; enabled = false
            message = "Moteur indisponible. Ouvrez les réglages pour le réparer."
            publishActivity()
        }
    }
    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true; error = nil
        work = Task { [weak self] in
            guard let self else { return }
            do { try await operation() }
            catch { if self.active { self.error = String(error.localizedDescription.prefix(700)) } }
            self.busy = false
            if self.active { await self.refresh() }
        }
    }
    func apply() {
        guard range.valid else { error = "Le seuil de reprise doit précéder l’arrêt d’au moins 2 points."; return }
        let requested = range
        // Legacy batt resumes strictly below its lower limit. Map an inclusive
        // user threshold (20%) to the legacy boundary (21%).
        let engineLower = requested.engineLower(mode: controlMode)
        perform { [weak self] in
            guard let self else { return }
            if !self.demo {
                // Set a small delta first, so reducing the upper limit never leaves
                // an invalid intermediate lower limit in batt's validated API.
                _ = try await Engine.command(["lower-limit-delta", "1"])
                _ = try await Engine.command(["limit", String(requested.upper)])
                _ = try await Engine.command(["lower-limit-delta", String(requested.upper - engineLower)])
                let data = try await Engine.command(["status", "--json"])
                let actual = try JSONDecoder().decode(EngineStatus.self, from: data)
                guard actual.configuration.enabled,
                      actual.configuration.upperLimitPercent == requested.upper,
                      actual.configuration.lowerLimitPercent == engineLower else {
                    throw CommandFailure(message: "Le moteur n’a pas confirmé les deux seuils. Réessayez.")
                }
            }
            self.enabled = true
            self.appliedLower = requested.lower; self.appliedUpper = requested.upper
            self.host?.preferences.setValue(Double(requested.lower), forKey: "lower")
            self.host?.preferences.setValue(Double(requested.upper), forKey: "upper")
            self.message = "Seuils appliqués : \(requested.lower)–\(requested.upper) %."
        }
    }
    func pause() {
        perform { [weak self] in
            guard let self else { return }
            if !self.demo { _ = try await Engine.command(["disable", "--for=2h"]) }
            self.enabled = false
            self.message = "Charge libre pendant 2 h, puis reprise automatique des seuils."
        }
    }
    func install() {
        guard !demo else { return }
        let bundle = Bundle(for: ChargeguardPrincipal.self)
        guard let script = bundle.resourceURL?.appendingPathComponent("Assets/Engine/setup.sh"),
              FileManager.default.fileExists(atPath: script.path) else {
            error = "Le script d’installation est absent du bundle."; return
        }
        perform { [weak self] in
            try await Engine.administer(script, action: "install")
            try await Task.sleep(for: .seconds(3))
            guard let self else { return }
            self.message = "Moteur installé. Appliquez vos seuils."
        }
    }
    func uninstall() {
        guard !demo else { return }
        guard let script = Bundle(for: ChargeguardPrincipal.self).resourceURL?.appendingPathComponent("Assets/Engine/setup.sh") else { return }
        perform { try await Engine.administer(script, action: "uninstall") }
    }
}

extension ChargeguardDroplet: ShelfWidgetProviding {
    public var widgetDescriptors: [ShelfWidgetDescriptor] {
        [ShelfWidgetDescriptor(id: "chargeguard", title: "Charge Guard", systemImage: "battery.75percent", layoutTraits: ShelfWidgetLayoutTraits(preferredSoloWidth: 420, preferredPairedWidth: 210, contentHeight: .fixed(244)))]
    }
    public func makeWidgetView(_ id: ShelfWidgetID, context: ShelfWidgetContext) -> AnyView { AnyView(ChargeWidget(model: self, context: context)) }
    public func makeWidgetSettingsPopover(_ id: ShelfWidgetID) -> AnyView? { AnyView(ChargeSettings(model: self).frame(width: 380)) }
}

private struct ChargeWidget: View {
    @ObservedObject var model: ChargeguardDroplet
    let context: ShelfWidgetContext
    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            HStack(spacing: DroppySpacing.xsm) {
                Image(systemName: "bolt.shield.fill").foregroundStyle(model.tint)
                Text("Charge Guard").fontWeight(.semibold)
                Spacer(minLength: 0)
                Button { model.settings() } label: { Image(systemName: "gearshape") }
                    .buttonStyle(DroppyCircleButtonStyle(size: 20))
                    .accessibilityLabel("Réglages avancés")
            }.font(.system(size: 12)).foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
            HStack(alignment: .firstTextBaseline) {
                Text(model.percent.map { "\($0) %" } ?? "—")
                    .font(.system(size: context.isCompact ? 28 : 34, weight: .semibold, design: .rounded)).monospacedDigit()
                Spacer(minLength: 0)
                if !context.isCompact {
                    Label(model.statusTitle, systemImage: model.charging ? "bolt.fill" : "leaf.fill")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(model.tint)
                }
            }
            ChargeGauge(percent: model.percent ?? 0, lower: model.appliedLower, upper: model.appliedUpper, tint: model.tint)
                .frame(height: 6)
            ThresholdControls(model: model)
                .disabled(!model.ready || !model.supported || model.busy)
            if let error = model.error {
                Text(error).font(.system(size: 10)).foregroundStyle(.orange).lineLimit(2)
                    .help(error)
            }
            Spacer(minLength: 0)
            if !model.ready {
                Button("Configurer") { model.settings() }
                    .buttonStyle(DroppyAccentButtonStyle(size: .small))
            } else {
                HStack(spacing: DroppySpacing.xsm) {
                    if model.hasPendingThresholds {
                        Button(model.busy ? "Application…" : "Appliquer") { model.apply() }
                            .buttonStyle(DroppyAccentButtonStyle(size: .small))
                            .disabled(model.busy || !model.range.valid || !model.supported)
                        Button { model.discardThresholdChanges() } label: { Image(systemName: "arrow.uturn.backward") }
                            .buttonStyle(DroppyCircleButtonStyle(size: 20))
                            .accessibilityLabel("Annuler les modifications des seuils")
                            .disabled(model.busy)
                    } else {
                        Button(model.enabled ? "Charge libre 2 h" : "Reprendre") { model.enabled ? model.pause() : model.apply() }
                            .buttonStyle(DroppyQuietButtonStyle(size: .small))
                            .disabled(model.busy || !model.supported)
                    }
                    Spacer(minLength: 0)
                    if !context.isCompact {
                        Text(model.hasPendingThresholds ? "À appliquer" : "\(model.appliedLower)–\(model.appliedUpper) % actifs")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
        .padding(context.contentInsets)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct ThresholdControls: View {
    @ObservedObject var model: ChargeguardDroplet
    var body: some View {
        VStack(spacing: DroppySpacing.sm) {
            thresholdRow(title: "Reprise", value: Int(model.lower), symbol: "arrow.down.to.line") {
                Slider(value: Binding(get: { model.lower }, set: {
                    model.lower = $0.rounded()
                    if model.upper < model.lower + 2 { model.upper = model.lower + 2 }
                }), in: 11...97, onEditingChanged: model.setEditingThresholds)
                .accessibilityLabel("Seuil de reprise de la charge")
            }
            thresholdRow(title: "Arrêt", value: Int(model.upper), symbol: "arrow.up.to.line") {
                Slider(value: Binding(get: { model.upper }, set: {
                    model.upper = $0.rounded()
                    if model.lower > model.upper - 2 { model.lower = model.upper - 2 }
                }), in: 13...99, onEditingChanged: model.setEditingThresholds)
                .accessibilityLabel("Seuil d’arrêt de la charge")
            }
        }.tint(.mint)
    }
    private func thresholdRow<Control: View>(title: String, value: Int, symbol: String, @ViewBuilder control: () -> Control) -> some View {
        VStack(spacing: 2) {
            HStack {
                Label(title, systemImage: symbol)
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                Spacer(minLength: 0)
                Text("\(value) %").monospacedDigit().fontWeight(.semibold)
            }.font(.system(size: 11))
            control().controlSize(.small)
        }
    }
}

private struct ChargeGauge: View {
    let percent: Int; let lower: Int; let upper: Int; let tint: Color
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.08))
                Capsule().fill(tint.opacity(0.18)).frame(width: geometry.size.width * Double(max(0, upper - lower)) / 100)
                    .offset(x: geometry.size.width * Double(lower) / 100)
                Capsule().fill(tint).frame(width: geometry.size.width * Double(min(100, max(0, percent))) / 100)
                ForEach([lower, upper], id: \.self) { mark in
                    Capsule().fill(.white.opacity(0.8)).frame(width: 2, height: 8)
                        .offset(x: geometry.size.width * Double(mark) / 100 - 1)
                }
            }
        }.accessibilityLabel("Batterie \(percent) %, plage \(lower) à \(upper) %")
    }
}

extension ChargeguardDroplet: SettingsPaneProviding {
    public func makeSettingsPane(context: SettingsPaneContext) -> AnyView { AnyView(ChargeSettings(model: self)) }
    public var settingsSearchEntries: [SettingsSearchEntry] { [SettingsSearchEntry(title: "Seuils de charge", keywords: ["batterie", "charge", "20", "80", "limite"])] }
}

private struct ChargeSettings: View {
    @ObservedObject var model: ChargeguardDroplet
    var body: some View {
        DropletSettingsPane {
            DropletSettingsCard {
                DropletControlRow(title: "Contrôle de la batterie", infoTip: model.message) {
                    Text(model.statusTitle).foregroundStyle(model.tint)
                }
                if !model.ready {
                    DropletControlRow(title: "Moteur de charge", infoTip: "Installation unique avec le mot de passe administrateur. Le service fonctionne en arrière-plan, même sans Droppy.") {
                        Button("Installer / réparer") { model.install() }.disabled(model.busy)
                    }
                }
            }
            DropletSettingsSection { settingsSectionHeader("Plage de charge") } content: {
                DropletSettingsCard {
                    DropletSliderRow(title: "Reprendre la charge à", value: "\(Int(model.lower)) %", binding: $model.lower, range: 11...97)
                    DropletSliderRow(title: "Arrêter la charge à", value: "\(Int(model.upper)) %", binding: $model.upper, range: 13...99)
                    DropletControlRow(title: "Appliquer les seuils", infoTip: "Le Mac doit être branché pour charger. Entre les deux seuils, il conserve son état de charge. Une charge suspendue ne force pas la décharge.") {
                        Button("Appliquer") { model.apply() }.disabled(!model.range.valid || !model.ready || !model.supported || model.busy)
                    }
                    DropletControlRow(title: "Préréglage 20–80 %") {
                        Button("Sélectionner") { model.lower = 20; model.upper = 80 }
                    }
                }
            }
            DropletSettingsCard {
                DropletControlRow(title: "Charge libre pendant 2 h", infoTip: "Autorise jusqu’à 100 %, puis restaure automatiquement la limite, même si Droppy est fermé.") {
                    Button("Autoriser") { model.pause() }.disabled(!model.ready || !model.enabled || model.busy)
                }
                DropletToggleRow(title: "Afficher près de la notch", subtitle: "Garde le niveau de batterie visible quand la protection est active.", isOn: Binding(get: { model.pin }, set: { model.setPin($0) }))
            }
            if let error = model.error {
                DropletSettingsCard { Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
            }
            DropletSettingsCard {
                DropletControlRow(title: "Désinstaller le moteur", infoTip: "Rétablit la charge normale et supprime le service système. Retirer uniquement le widget laisse la protection active.") {
                    Button("Désinstaller…") { model.uninstall() }.disabled(!model.ready || model.busy)
                }
            }
        }
    }
}

extension ChargeguardDroplet: LiveActivityProviding {
    public var liveActivityState: AnyPublisher<LiveActivityState?, Never> { activity.eraseToAnyPublisher() }
    public func makeCompactLeading() -> AnyView { AnyView(CompactBattery(model: self, leading: true)) }
    public func makeCompactTrailing() -> AnyView { AnyView(CompactBattery(model: self, leading: false)) }
    public func makeExpanded(context: LiveActivityContext) -> AnyView { AnyView(EmptyView()) }
}
private struct CompactBattery: View {
    @ObservedObject var model: ChargeguardDroplet
    let leading: Bool
    var body: some View {
        Group {
            if leading { Image(systemName: model.charging ? "bolt.fill" : "leaf.fill").foregroundStyle(model.tint) }
            else { Text(model.percent.map { "\($0)%" } ?? "—").monospacedDigit() }
        }.font(.system(size: 12, weight: .semibold))
    }
}
