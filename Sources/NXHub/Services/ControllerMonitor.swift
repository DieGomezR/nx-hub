import Foundation
import GameController
import AppKit
import CoreHaptics
import Observation

/// A connected controller as the tester shows it. Buttons carry the Switch names nxnative gives them: by position, as dm/host/front_mac.m maps them
/// (right face button A, bottom B, top X, left Y; Options +, Create −; Home and Capture have no function in the games)
@Observable
final class PadState: Identifiable {
    let id: ObjectIdentifier
    let controller: GCController
    let name: String
    let kind: String
    var pressed: Set<String> = []
    var left = CGPoint.zero
    var right = CGPoint.zero
    var zl: Float = 0
    var zr: Float = 0
    var gravity: (x: Double, y: Double, z: Double)?
    var rotation: (x: Double, y: Double, z: Double)?
    var battery: Float?
    var charging = false
    var hasMotion: Bool { controller.motion?.hasRotationRate ?? false }
    var hasHaptics: Bool { controller.haptics != nil }
    var hasLight: Bool { controller.light != nil }
    /// The glyph each Switch button has on this controller (SF Symbols name), when it reports one
    var glyphs: [String: String] = [:]
    @ObservationIgnored var engine: CHHapticEngine?
    @ObservationIgnored var lastMotion = Date.distantPast

    init(_ c: GCController) {
        controller = c
        id = ObjectIdentifier(c)
        name = c.vendorName ?? L("Controller")
        kind = c.productCategory
    }
}

/// A button press NX Hub's own screens act on (the console navigation): directions from the D-pad or the left stick, repeated while held
enum PadButton: String { case up = "UP", down = "DOWN", left = "LEFT", right = "RIGHT", a = "A", b = "B", x = "X", y = "Y", plus = "+", minus = "−", l = "L", r = "R"
    var isDirection: Bool { self == .up || self == .down || self == .left || self == .right }
}

@Observable
final class ControllerMonitor {
    var pads: [PadState] = []
    var motionOn = false
    /// Presses for NX Hub's navigation, only while NX Hub is the active app
    @ObservationIgnored var onButton: ((PadButton) -> Void)?
    /// The Home button (PS, Xbox, Home), pressed on any controller, also while a game is in front
    @ObservationIgnored var onHome: (() -> Void)?
    @ObservationIgnored private var backgroundReasons = Set<String>()
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var batteryTimer: Timer?
    @ObservationIgnored private var held: [ObjectIdentifier: Set<String>] = [:]
    @ObservationIgnored private var repeatTimer: Timer?
    @ObservationIgnored private var repeating: (pad: ObjectIdentifier, button: PadButton)?

    func start() {
        guard observers.isEmpty else { return }
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] n in
            if let c = n.object as? GCController { self?.add(c) }
        })
        observers.append(nc.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] n in
            if let c = n.object as? GCController { self?.pads.removeAll { $0.controller === c }; self?.held[ObjectIdentifier(c)] = nil }
        })
        for c in GCController.controllers() { add(c) }
        batteryTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.updateBatteries() }
    }

    /// Controller input also while another app is in front (a game started from NX Hub: its Home button, its cheats' key conditions)
    func monitorInBackground(_ reason: String, _ on: Bool) {
        if on { backgroundReasons.insert(reason) } else { backgroundReasons.remove(reason) }
        GCController.shouldMonitorBackgroundEvents = !backgroundReasons.isEmpty
    }

    func stop() {
        setMotion(false)
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers.removeAll()
        batteryTimer?.invalidate(); batteryTimer = nil
        for p in pads { p.controller.extendedGamepad?.valueChangedHandler = nil }
        pads.removeAll()
    }

    private func add(_ c: GCController) {
        guard !pads.contains(where: { $0.controller === c }), let g = c.extendedGamepad else { return }
        let p = PadState(c)
        // Home is NX Hub's (back to the game, or to the start screen), not macOS's (which opens Launchpad or the Games app with it); the game's host does the same in front
        c.physicalInputProfile.buttons[GCInputButtonHome]?.preferredSystemGestureState = .disabled
        let map: [(GCControllerButtonInput?, String)] = [(g.buttonB, "A"), (g.buttonA, "B"), (g.buttonY, "X"), (g.buttonX, "Y"),
                                                        (g.leftShoulder, "L"), (g.rightShoulder, "R"), (g.leftTrigger, "ZL"), (g.rightTrigger, "ZR"),
                                                        (g.buttonMenu, "+"), (g.buttonOptions, "−"), (g.leftThumbstickButton, "LS"), (g.rightThumbstickButton, "RS"), (g.buttonHome, "HOME")]
        var glyphs: [String: String] = [:]
        for (b, n) in map { if let s = b?.sfSymbolsName { glyphs[n] = s } }
        if let share = c.physicalInputProfile.buttons[GCInputButtonShare], let s = share.sfSymbolsName { glyphs["CAPTURE"] = s }
        p.glyphs = glyphs
        g.valueChangedHandler = { [weak self, weak p] pad, _ in
            guard let p else { return }
            var s = Set<String>()
            for (b, n) in [(pad.buttonB, "A"), (pad.buttonA, "B"), (pad.buttonY, "X"), (pad.buttonX, "Y"), (pad.leftShoulder, "L"), (pad.rightShoulder, "R"),
                           (pad.leftTrigger, "ZL"), (pad.rightTrigger, "ZR"), (pad.buttonMenu, "+")] where b.isPressed { s.insert(n) }
            if pad.buttonOptions?.isPressed == true { s.insert("−") }
            if pad.leftThumbstickButton?.isPressed == true { s.insert("LS") }
            if pad.rightThumbstickButton?.isPressed == true { s.insert("RS") }
            if pad.buttonHome?.isPressed == true { s.insert("HOME") }
            if pad.controller?.physicalInputProfile.buttons[GCInputButtonShare]?.isPressed == true { s.insert("CAPTURE") }
            if pad.dpad.up.isPressed { s.insert("UP") }
            if pad.dpad.down.isPressed { s.insert("DOWN") }
            if pad.dpad.left.isPressed { s.insert("LEFT") }
            if pad.dpad.right.isPressed { s.insert("RIGHT") }
            if s != p.pressed { p.pressed = s }
            p.left = CGPoint(x: CGFloat(pad.leftThumbstick.xAxis.value), y: CGFloat(pad.leftThumbstick.yAxis.value))
            p.right = CGPoint(x: CGFloat(pad.rightThumbstick.xAxis.value), y: CGFloat(pad.rightThumbstick.yAxis.value))
            p.zl = pad.leftTrigger.value
            p.zr = pad.rightTrigger.value
            var nav = s
            let lx = pad.leftThumbstick.xAxis.value, ly = pad.leftThumbstick.yAxis.value
            if ly > 0.6 { nav.insert("UP") } else if ly < -0.6 { nav.insert("DOWN") }
            if lx > 0.6 { nav.insert("RIGHT") } else if lx < -0.6 { nav.insert("LEFT") }
            self?.navigate(p.id, nav)
        }
        pads.append(p)
        updateBatteries()
        if motionOn { motion(p, true) }
    }

    /// New presses become navigation events; a held direction repeats (after 0.35 s, every 0.11 s)
    private func navigate(_ pad: ObjectIdentifier, _ now: Set<String>) {
        let before = held[pad] ?? []
        held[pad] = now
        if let r = repeating, r.pad == pad, !now.contains(r.button.rawValue) { stopRepeat() }
        if now.contains("HOME") && !before.contains("HOME") { onHome?() }
        guard NSApp.isActive else { return }
        for name in now.subtracting(before) {
            guard let b = PadButton(rawValue: name) else { continue }
            onButton?(b)
            if b.isDirection { startRepeat(pad, b) }
        }
    }
    private func startRepeat(_ pad: ObjectIdentifier, _ b: PadButton) {
        stopRepeat()
        repeating = (pad, b)
        repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
            guard let self, self.repeating?.button == b else { return }
            self.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.11, repeats: true) { [weak self] _ in
                guard let self, let r = self.repeating, NSApp.isActive else { self?.stopRepeat(); return }
                self.onButton?(r.button)
            }
        }
    }
    private func stopRepeat() { repeatTimer?.invalidate(); repeatTimer = nil; repeating = nil }

    private func updateBatteries() {
        for p in pads {
            p.battery = p.controller.battery.map { $0.batteryLevel }
            p.charging = p.controller.battery?.batteryState == .charging
        }
    }

    /// The gyro and accelerometer: a DualSense or DualShock 4 sends them only while asked (they use the battery)
    func setMotion(_ on: Bool) {
        motionOn = on
        for p in pads { motion(p, on) }
    }

    private func motion(_ p: PadState, _ on: Bool) {
        guard let m = p.controller.motion else { return }
        if m.sensorsRequireManualActivation { m.sensorsActive = on }
        if !on { m.valueChangedHandler = nil; p.gravity = nil; p.rotation = nil; return }
        m.valueChangedHandler = { [weak p] m in
            guard let p, Date().timeIntervalSince(p.lastMotion) > 1.0 / 30 else { return }
            p.lastMotion = Date()
            if m.hasGravityAndUserAcceleration { p.gravity = (m.gravity.x, m.gravity.y, m.gravity.z) }
            else { p.gravity = (m.acceleration.x, m.acceleration.y, m.acceleration.z) }
            if m.hasRotationRate { p.rotation = (m.rotationRate.x, m.rotationRate.y, m.rotationRate.z) }
        }
    }

    /// Half a second of rumble on the controller's own motors
    func rumble(_ p: PadState) {
        guard let engine = p.engine ?? p.controller.haptics?.createEngine(withLocality: .default) else { return }
        p.engine = engine
        do {
            try engine.start()
            let ev = CHHapticEvent(eventType: .hapticContinuous,
                                   parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                                                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.4)],
                                   relativeTime: 0, duration: 0.5)
            let player = try engine.makePlayer(with: CHHapticPattern(events: [ev], parameters: []))
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            p.engine = nil
        }
    }

    /// Lights the controller's player LEDs (and a DualSense's light bar) with its number in the list, the order nxnative gives players in
    func identify(_ p: PadState) {
        guard let i = pads.firstIndex(where: { $0 === p }) else { return }
        p.controller.playerIndex = GCControllerPlayerIndex(rawValue: i) ?? .indexUnset
        let colors: [(Float, Float, Float)] = [(0.1, 0.4, 1), (1, 0.15, 0.15), (0.1, 0.9, 0.3), (1, 0.8, 0.1)]
        let c = colors[i % colors.count]
        p.controller.light?.color = GCColor(red: c.0, green: c.1, blue: c.2)
    }
}
