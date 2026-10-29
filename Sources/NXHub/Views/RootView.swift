import SwiftUI
import AppKit
import IOKit.ps

/// The window: the start screen or one of the pages, a console look, keys and the controller moving through it
struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            PageView(page: model.page)
                .transition(.opacity)
        }
        .animation(.easeInOut(duration: 0.22), value: model.page)
        .overlay { if let g = model.closePrompt { ClosePrompt(game: g).transition(.opacity) } }
        .animation(.easeOut(duration: 0.15), value: model.closePrompt?.titleID)
        .overlay(alignment: .bottom) { NoticeBanner() }
        .groupBoxStyle(CardGroupBoxStyle())
        .preferredColorScheme(.dark)
        .foregroundStyle(Theme.text)
        .onAppear {
            model.openSettings = { model.page = .settings }
            if model.config.startFullScreen, let w = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 500 }), !w.styleMask.contains(.fullScreen) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { w.toggleFullScreen(nil) }
            }
        }
    }
}

/// The screen of a page
struct PageView: View {
    @Environment(AppModel.self) private var model
    let page: Page

    var body: some View {
        switch page {
        case .home: HomeView()
        case .library: LibraryPage()
        case .settings: SettingsPage()
        case .game(let id):
            if let g = model.games.first(where: { $0.titleID == id }) { GamePage(game: g) } else { HomeView() }
        case .catalog: CatalogPage()
        case .saves: SavesPage()
        case .mods(let id): ModsPage(initial: id)
        case .cheats(let id): CheatsPage(initial: id)
        case .controllers: PageShell(title: L("Controllers"), systemImage: "gamecontroller.fill") { ControllersView() }
        case .nxnative: NXNativePage()
        }
    }
}

/// A page with the shared header over its own content
struct PageShell<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: title, systemImage: systemImage)
            content()
        }
        .background(
            LinearGradient(colors: [Color(red: 0.09, green: 0.10, blue: 0.13), Theme.bg], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
        )
    }
}

struct CardGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            configuration.label.font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
            configuration.content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 18)
    }
}

private struct NoticeBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let n = model.notice {
            HStack(spacing: 10) {
                Image(systemName: "info.circle.fill").foregroundStyle(Theme.accent)
                Text(n).lineLimit(3)
                Spacer(minLength: 8)
                Button { model.notice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
            }
            .padding(14)
            .frame(maxWidth: 640)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.stroke))
            .shadow(radius: 12)
            .padding(18)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task(id: n) {
                try? await Task.sleep(for: .seconds(10))
                if model.notice == n { model.notice = nil }
            }
        }
    }
}

/// "Close <game>?": what the game has not saved is lost, as when the Switch closes software
private struct ClosePrompt: View {
    @Environment(AppModel.self) private var model
    let game: Game

    var body: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea().onTapGesture { model.closePrompt = nil }
            VStack(spacing: 16) {
                GameTileArt(game: game, size: 96).shadow(radius: 16)
                Text(LF("Close %@?", game.name)).font(.system(size: 24, weight: .bold)).multilineTextAlignment(.center)
                Text("What you have not saved in the game is lost.").foregroundStyle(Theme.secondary)
                HStack(spacing: 14) {
                    Button { model.closePrompt = nil } label: { Text("Cancel").frame(minWidth: 110) }.buttonStyle(GlassPill())
                    Button { Task { await model.closeGame() } } label: { Text("Close").frame(minWidth: 110) }.buttonStyle(PrimaryPill())
                }
                .padding(.top, 6)
                if !model.pads.pads.isEmpty {
                    HStack(spacing: 18) { Hint(glyph: "A", text: L("Close")); Hint(glyph: "B", text: L("Cancel")) }
                }
            }
            .padding(36)
            .frame(maxWidth: 480)
            .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Color(white: 0.11)))
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(Theme.stroke))
            .shadow(color: .black.opacity(0.5), radius: 30)
        }
    }
}

/// The Mac's battery, for the start screen's top bar (nil on a Mac without one)
enum MacBattery {
    /// On the power adapter (or a Mac without a battery)
    static var onAC: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return true }
        return (type as String) == kIOPMACPowerKey
    }

    static func read() -> (percent: Int, charging: Bool)? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  let cur = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            return (cur * 100 / max, (d[kIOPSIsChargingKey] as? Bool) ?? false)
        }
        return nil
    }
}
