#if os(macOS)
import AppKit
#else
import UIKit
#endif
import CoreImage.CIFilterBuiltins
import SwiftUI

/// a website from settings (qml SiteCard): a qr code for the phone, or the browser on this mac
@MainActor @Observable
final class SiteCardModel {
    let url: String
    let title: String
    /// 0: open in browser, 1: close
    var index = 0

    init(url: String, title: String) {
        self.url = url
        self.title = title
    }

    func key(_ k: Key, app: AppModel) {
        switch k {
        case .left: index = 0
        case .right: index = 1
        case .ok: activate(index, app: app)
        case .back: app.site = nil
        default: break
        }
    }

    func activate(_ i: Int, app: AppModel) {
        if i == 0, let u = URL(string: url) { Platform.open(u) }
        app.site = nil
    }

    /// the code as sharp pixels: one per module, scaled up without smoothing
    static func qr(_ text: String) -> NSImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(text.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage,
              let cg = CIContext().createCGImage(out, from: out.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

struct SiteCardView: View {
    @Environment(AppModel.self) private var app
    let model: SiteCardModel

    var body: some View {
        let u = app.u
        ZStack {
            Color.black.opacity(0.4).contentShape(.rect).onTapGesture { app.site = nil }
            VStack(spacing: 0) {
                // the code on its own white tile, like a phone's own qr sheets
                RoundedRectangle(cornerRadius: 36 * u).fill(.white)
                    .frame(width: 340 * u, height: 340 * u)
                    .overlay {
                        if let img = SiteCardModel.qr(model.url) {
                            Image(nsImage: img).resizable().interpolation(.none).padding(18 * u)
                        }
                    }
                Text(model.title).font(Theme.display(46 * u, .bold)).foregroundStyle(Theme.fg)
                    .padding(.top, 34 * u)
                Text(L("Scan it with your phone's camera")).font(Theme.text(27 * u, .medium)).foregroundStyle(Theme.fg2)
                    .padding(.top, 10 * u)
                HStack(spacing: 20 * u) {
                    GlassButton(text: L("Open in Browser"), primary: true, focused: model.index == 0, u: u)
                        .onContinuousHover { phase in if case .active = phase, Input.pointerLive { model.index = 0 } }
                        .onTapGesture { model.activate(0, app: app) }
                    GlassButton(text: L("Close"), focused: model.index == 1, u: u)
                        .onContinuousHover { phase in if case .active = phase, Input.pointerLive { model.index = 1 } }
                        .onTapGesture { model.activate(1, app: app) }
                }
                .padding(.top, 38 * u)
            }
            .padding(.vertical, 60 * u)
            .frame(width: 760 * u)
            .panelGlass(52 * u, u: u)
            .contentShape(.rect)
            .onTapGesture {}
        }
    }
}
