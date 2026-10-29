import SwiftUI

/// The controller tester: what each connected controller sends, with the Switch names nxnative gives its buttons
struct ControllersView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let pads = model.pads
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    Text("Press buttons and move the sticks: what lights up is what the game gets. nxnative maps buttons by position, as on a Switch controller, and gives each controller a player of its own in the order they connect (the keyboard plays as player 1).")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 20)
                    Toggle("Motion sensors", isOn: Binding(get: { pads.motionOn }, set: { pads.setMotion($0) }))
                        .toggleStyle(.switch)
                        .help("Turns on the gyro and accelerometer readout (a DualSense sends them only while asked)")
                }
                if pads.pads.isEmpty {
                    ContentUnavailableView {
                        Label("No controllers", systemImage: "gamecontroller")
                    } description: {
                        Text("Turn a controller on or connect it with a cable. A DualSense pairs in System Settings › Bluetooth (hold Create and PS until the light flashes).")
                    }
                    .frame(minHeight: 260)
                }
                ForEach(Array(pads.pads.enumerated()), id: \.element.id) { i, p in
                    PadCard(pad: p, player: i + 1)
                }
                KeyboardCard()
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Controllers")
        .onAppear { pads.start() }
        .onDisappear { pads.setMotion(false) }
    }
}

private struct PadCard: View {
    @Environment(AppModel.self) private var model
    let pad: PadState
    let player: Int

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 18) {
                    VStack(spacing: 8) {
                        HStack(spacing: 6) { key("ZL", wide: true); key("L", wide: true) }
                        dpad
                        StickView(point: pad.left, pressed: pad.pressed.contains("LS"), label: L("Left stick"))
                        TriggerBar(value: pad.zl, label: "ZL")
                    }
                    VStack(spacing: 10) {
                        HStack(spacing: 8) { key("−"); key("HOME"); key("CAPTURE"); key("+") }
                        Text("Home and Capture do nothing in the games").font(.caption2).foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity)
                    VStack(spacing: 8) {
                        HStack(spacing: 6) { key("R", wide: true); key("ZR", wide: true) }
                        face
                        StickView(point: pad.right, pressed: pad.pressed.contains("RS"), label: L("Right stick"))
                        TriggerBar(value: pad.zr, label: "ZR")
                    }
                }
                if model.pads.motionOn {
                    MotionView(pad: pad)
                }
                HStack {
                    if pad.hasHaptics { Button("Rumble") { model.pads.rumble(pad) } }
                    Button("Identify") { model.pads.identify(pad) }
                        .help("Lights the controller's player lights with its number")
                    Spacer()
                    Text(pad.hasMotion ? L("Has motion sensors") : L("No motion sensors")).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(8)
        } label: {
            HStack {
                Text(LF("Player %lld", player)).font(.headline)
                Text(pad.name).foregroundStyle(.secondary)
                Spacer()
                if let b = pad.battery {
                    Label(String(Int(b * 100)) + " %", systemImage: pad.charging ? "battery.100.bolt" : b > 0.5 ? "battery.75" : b > 0.2 ? "battery.25" : "battery.0")
                        .font(.caption)
                }
            }
        }
    }

    private var dpad: some View {
        VStack(spacing: 2) {
            key("UP", symbol: "arrowtriangle.up.fill")
            HStack(spacing: 2) { key("LEFT", symbol: "arrowtriangle.left.fill"); Color.clear.frame(width: 30, height: 30); key("RIGHT", symbol: "arrowtriangle.right.fill") }
            key("DOWN", symbol: "arrowtriangle.down.fill")
        }
    }

    private var face: some View {
        VStack(spacing: 2) {
            key("X")
            HStack(spacing: 2) { key("Y"); Color.clear.frame(width: 30, height: 30); key("A") }
            key("B")
        }
    }

    /// A Switch button: its name, the glyph it has on this controller, lit while pressed
    private func key(_ name: String, wide: Bool = false, symbol: String? = nil) -> some View {
        let on = pad.pressed.contains(name)
        let title = name == "HOME" ? "⌂" : name == "CAPTURE" ? "◉" : name
        return VStack(spacing: 0) {
            if let symbol { Image(systemName: symbol).font(.system(size: 11)) } else { Text(title).font(.system(size: 12, weight: .bold)) }
            if let g = pad.glyphs[name], symbol == nil { Image(systemName: g).font(.system(size: 8)).opacity(0.7) }
        }
        .frame(width: wide ? 44 : 30, height: 30)
        .background(on ? Color.accentColor : Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: wide ? 8 : 15))
        .foregroundStyle(on ? Color.white : Color.primary)
        .animation(.easeOut(duration: 0.08), value: on)
    }
}

private struct StickView: View {
    let point: CGPoint
    let pressed: Bool
    let label: String

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.2), lineWidth: 1.5)
            Circle().fill(pressed ? Color.accentColor : Color.primary.opacity(0.6))
                .frame(width: 14, height: 14)
                .offset(x: point.x * 26, y: -point.y * 26)
        }
        .frame(width: 66, height: 66)
        .help(label)
        .accessibilityLabel(label)
    }
}

private struct TriggerBar: View {
    let value: Float
    let label: String

    var body: some View {
        HStack(spacing: 6) {
            Text(label).font(.caption2.weight(.bold)).frame(width: 20)
            ProgressView(value: Double(value)).frame(width: 70)
        }
    }
}

private struct MotionView: View {
    let pad: PadState

    var body: some View {
        HStack(spacing: 24) {
            if let g = pad.gravity {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Gravity (G)").font(.caption.weight(.semibold))
                    Text(String(format: "x %+.2f  y %+.2f  z %+.2f", g.x, g.y, g.z)).font(.caption.monospaced())
                }
                // A level: tilting the controller moves the dot
                ZStack {
                    Circle().stroke(Color.primary.opacity(0.2))
                    Circle().fill(Color.orange).frame(width: 10, height: 10)
                        .offset(x: CGFloat(max(-1, min(1, g.x))) * 22, y: CGFloat(max(-1, min(1, g.y))) * 22)
                }
                .frame(width: 54, height: 54)
            }
            if let r = pad.rotation {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Rotation (rad/s)").font(.caption.weight(.semibold))
                    Text(String(format: "x %+.2f  y %+.2f  z %+.2f", r.x, r.y, r.z)).font(.caption.monospaced())
                }
            }
            if pad.gravity == nil && pad.rotation == nil {
                Text(pad.hasMotion ? L("Move the controller…") : L("This controller sends no motion.")).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// The keyboard's keys in the games (dm/host/front_mac.m)
private struct KeyboardCard: View {
    private let rows: [(String, String)] = [
        ("W A S D", "Left stick"), ("← ↑ → ↓", "D-pad"), ("J  K  U  I", "A  B  X  Y"), ("Q  E", "L  R"), ("Z  C", "ZL  ZR"),
        ("F  G", "Stick presses"), ("Return  Tab", "+  −"), ("Space", "Shake the controller (while held)"), ("Mouse", "Touch screen")
    ]

    var body: some View {
        GroupBox {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                ForEach(rows.indices, id: \.self) { i in
                    GridRow {
                        Text(rows[i].0).font(.callout.monospaced())
                        Text(LocalizedStringKey(rows[i].1)).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Keyboard", systemImage: "keyboard").font(.headline)
        }
    }
}
