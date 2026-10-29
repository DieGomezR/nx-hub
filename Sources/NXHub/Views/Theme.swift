import SwiftUI
import AppKit
import CoreImage

/// The console look: a dark room, the selected game's art as light, glass panels, white pills
enum Theme {
    static let bg = Color(red: 0.055, green: 0.058, blue: 0.07)
    static let panel = Color.white.opacity(0.065)
    static let panelHi = Color.white.opacity(0.11)
    static let stroke = Color.white.opacity(0.10)
    static let accent = Color(red: 0.30, green: 0.86, blue: 0.98)
    static let text = Color.white
    static let secondary = Color.white.opacity(0.64)
    static let tertiary = Color.white.opacity(0.42)
    static let good = Color(red: 0.38, green: 0.88, blue: 0.55)
    static let warn = Color(red: 1.0, green: 0.72, blue: 0.28)
    static let bad = Color(red: 1.0, green: 0.42, blue: 0.42)
    static let corner: CGFloat = 18
}

extension View {
    /// A glass panel
    func card(padding: CGFloat = 18, corner: CGFloat = Theme.corner) -> some View {
        self.padding(padding)
            .background(RoundedRectangle(cornerRadius: corner, style: .continuous).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
    }
}

/// The white pill of the main action (Play)
struct PrimaryPill: ButtonStyle {
    var focused = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.black)
            .padding(.horizontal, 26).padding(.vertical, 12)
            .background(Capsule().fill(.white))
            .overlay(Capsule().stroke(Theme.accent, lineWidth: focused ? 3 : 0).padding(-4))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
            .animation(.spring(duration: 0.18), value: configuration.isPressed)
    }
}

/// A glass pill for the other actions
struct GlassPill: ButtonStyle {
    var tint: Color = .white
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 18).padding(.vertical, 10)
            .background(Capsule().fill(configuration.isPressed ? Theme.panelHi : Theme.panel))
            .overlay(Capsule().stroke(Theme.stroke))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(duration: 0.18), value: configuration.isPressed)
    }
}

/// A controller button as the hints show it: a circle with its letter
struct PadGlyph: View {
    let letter: String
    var body: some View {
        Text(letter)
            .font(.system(size: letter.count > 1 ? 9 : 11, weight: .heavy, design: .rounded))
            .foregroundStyle(.black)
            .frame(width: 20, height: 20)
            .background(Circle().fill(.white.opacity(0.9)))
    }
}

struct Hint: View {
    let glyph: String
    let text: String
    var body: some View {
        HStack(spacing: 6) {
            PadGlyph(letter: glyph)
            Text(text).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.secondary)
        }
    }
}

/// A small coloured label
struct Chip: View {
    let text: String
    var color: Color = Theme.accent
    var systemImage: String?
    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage).font(.system(size: 10, weight: .bold)) }
            Text(text).font(.system(size: 11, weight: .bold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.16)))
    }
}

/// The game's picture: its app's icon, else the icon its extraction kept; cached
enum GameArt {
    nonisolated(unsafe) private static var cache: [String: NSImage] = [:]
    static func image(_ g: Game) -> NSImage? {
        let key = g.titleID + (g.app?.url.path ?? "") + (g.app?.builtAt?.description ?? "")
        if let i = cache[key] { return i }
        var img: NSImage?
        if let app = g.app {
            let icns = app.url.appendingPathComponent("Contents/Resources/AppIcon.icns")
            img = NSImage(contentsOf: icns) ?? NSWorkspace.shared.icon(forFile: app.url.path)
        }
        if img == nil, let u = g.extractIcon { img = NSImage(contentsOf: u) }
        if let img { cache[key] = img }
        return img
    }
}

/// A picture blurred once, small (a blurred picture needs few pixels), instead of a live blur over the whole window on every frame. Cached per picture and radius
enum Blurred {
    nonisolated(unsafe) private static var caches: [Int: NSCache<NSImage, NSImage>] = [:]
    private static let context = CIContext()

    /// radius: the blur as it would look over a window about 1300 points wide
    static func image(_ img: NSImage, radius: CGFloat) -> NSImage? {
        let key = Int(radius)
        let cache = caches[key] ?? { let c = NSCache<NSImage, NSImage>(); c.countLimit = 24; caches[key] = c; return c }()
        if let c = cache.object(forKey: img) { return c }
        guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let src = CIImage(cgImage: cg)
        let scale = min(1, 520 / max(src.extent.width, 1))
        let small = src.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let sigma = Double(radius) * Double(small.extent.width) / 1300
        let soft = small.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: small.extent)
        guard let out = context.createCGImage(soft, from: small.extent) else { return nil }
        let result = NSImage(cgImage: out, size: NSSize(width: small.extent.width, height: small.extent.height))
        cache.setObject(result, forKey: img)
        return result
    }
}

/// The selected game's picture blurred across the whole window, under a dark veil
struct ArtBackground: View {
    let image: NSImage?
    var dim: Double = 0.55
    var blur: CGFloat = 80
    var opacity: Double = 0.55

    var body: some View {
        // The picture fills whatever space it is given and never asks for more (an image filled to a square would grow the window's layout past its edges)
        GeometryReader { geo in
            ZStack {
                Theme.bg
                if let image, let soft = Blurred.image(image, radius: blur) {
                    Image(nsImage: soft)
                        .resizable()
                        .interpolation(.medium)
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .saturation(blur > 40 ? 1.3 : 1.05)
                        .opacity(opacity)
                        .transition(.opacity)
                }
                LinearGradient(colors: [.black.opacity(dim * 0.5), .black.opacity(dim)], startPoint: .top, endPoint: .bottom)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .ignoresSafeArea()
    }
}

/// A rounded square of a game: its art, or a placeholder with its name
struct GameTileArt: View {
    let game: Game
    var size: CGFloat
    var body: some View {
        Group {
            if let img = GameArt.image(game) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    LinearGradient(colors: [Color(white: 0.22), Color(white: 0.12)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    VStack(spacing: 8) {
                        Image(systemName: "gamecontroller.fill").font(.system(size: size * 0.22)).foregroundStyle(Theme.tertiary)
                        Text(game.name).font(.system(size: max(10, size * 0.07), weight: .semibold)).foregroundStyle(Theme.secondary)
                            .multilineTextAlignment(.center).lineLimit(3).padding(.horizontal, 10)
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.09, style: .continuous))
    }
}

/// The header every page has: back to the start, its title, and its own actions
struct PageHeader<Actions: View>: View {
    @Environment(AppModel.self) private var model
    let title: String
    let systemImage: String
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(spacing: 14) {
            Button { model.goHome() } label: {
                HStack(spacing: 6) { Image(systemName: "chevron.left"); Text("Home") }
            }
            .buttonStyle(GlassPill())
            .keyboardShortcut(.cancelAction)
            Image(systemName: systemImage).font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.accent)
            Text(title).font(.system(size: 26, weight: .bold)).foregroundStyle(Theme.text)
            Spacer()
            actions()
        }
        .padding(.horizontal, 32).padding(.top, 22).padding(.bottom, 12)
    }
}

extension PageHeader where Actions == EmptyView {
    init(title: String, systemImage: String) { self.init(title: title, systemImage: systemImage) { EmptyView() } }
}
