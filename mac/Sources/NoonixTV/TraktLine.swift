import SwiftUI

/// where to enter the trakt code: on this device a tap opens the page (qml TraktCode here), else
/// the phone does it
struct TraktCodeLine: View {
    let code: String?
    let url: String
    let u: CGFloat
    var weight: Font.Weight = .regular

    var body: some View {
        // touch on this device: the page is a tap away, here
        let here = Platform.phone || Theme.touch
        Text(code == nil ? L("Asking Trakt for a code…")
             : here ? L("Tap to open %1, then enter", url) : L("On your phone, open %1 and enter", url))
            .font(Theme.text(27 * u, weight)).foregroundStyle(Theme.fg2)
            .multilineTextAlignment(.center)
            .contentShape(.rect)
            .onTapGesture {
                guard here, code != nil else { return }
                let full = url.hasPrefix("http") ? url : "https://" + url
                if let link = URL(string: full) { Platform.open(link) }
            }
    }
}
