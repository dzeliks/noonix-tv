import Foundation
import Observation

/// the ui language, like the tv's Desktop.setLanguage: english, or serbian (latin) from the same
/// i18n/noonix-tv_sr_Latn.ts the tv uses. views read it through L(), so a switch redraws them
@Observable
final class UILang: @unchecked Sendable {
    static let shared = UILang()
    /// "en" or "sr"
    private(set) var code = "en"
    @ObservationIgnored private var sr: [String: String] = [:]
    @ObservationIgnored private var srPlural: [String: [String]] = [:]
    /// lines the core sends in english (qml qsTranslate("core", …): genres, row titles, languages)
    @ObservationIgnored private var srCore: [String: String] = [:]

    var locale: Locale { Locale(identifier: code == "sr" ? "sr_Latn_RS" : "en_US") }

    /// what the mac's own languages say (qml Desktop.systemLanguage)
    static var system: String {
        Locale.preferredLanguages.first.map { $0.hasPrefix("sr") || $0.hasPrefix("hr") || $0.hasPrefix("bs") } == true ? "sr" : "en"
    }

    func set(_ c: String) {
        let c = c == "sr" ? "sr" : "en"
        if c == "sr", sr.isEmpty { load() }
        if c != code { code = c }
    }

    private func load() {
        guard let u = Bundle.main.url(forResource: "noonix-tv_sr_Latn", withExtension: "ts"), let p = XMLParser(contentsOf: u) else { return }
        let r = TsReader()
        p.delegate = r
        p.parse()
        // the first context wins ("History" is a nav title before it's a setting value)
        for (s, t) in r.out where sr[s] == nil { sr[s] = t }
        srCore = r.core
        for (s, t) in r.plural where srPlural[s] == nil { srPlural[s] = t }
        for (s, t) in Self.mac { sr[s] = t }
    }

    func tr(_ s: String) -> String {
        guard code == "sr" else { return s }
        return sr[s] ?? s
    }

    func core(_ s: String) -> String {
        let s = Self.device[s] ?? s
        guard code == "sr" else { return s }
        return srCore[s] ?? sr[s] ?? s
    }

    /// the core names this computer a pc: here it's a mac
    static let device = ["On This PC": "On This Mac", "This PC": "This Mac"]

    /// an addon on this computer (the core adds "(this PC)" to its name)
    static func addonName(_ s: String) -> String {
        s.hasSuffix(" (this PC)") ? String(s.dropLast(10)) + " (" + L("this Mac") + ")" : s
    }

    func plural(_ s: String, _ n: Int) -> String {
        if code == "sr", let f = srPlural[s], f.count == 3 {
            // serbian: 1, 21 · 2-4, 22-24 · the rest
            let i = n % 10 == 1 && n % 100 != 11 ? 0 : (2...4).contains(n % 10) && !(12...14).contains(n % 100) ? 1 : 2
            return f[i].replacingOccurrences(of: "%n", with: String(n))
        }
        // english source: "%n season(s)"
        return s.replacingOccurrences(of: "(s)", with: n == 1 ? "" : "s").replacingOccurrences(of: "%n", with: String(n))
    }

    /// the mac's own wording (the tv says tv / pc where these say mac)
    static let mac: [String: String] = [
        "Your own movies and shows, and the sources you add, on this Mac. A few steps and you're watching.":
            "Tvoji filmovi i serije, i izvori koje dodaš, na ovom Mac-u. Par koraka i gledaš.",
        "Noonix TV plays the videos on this Mac and the sources you add yourself. Pick the folders your movies and shows are in; an addon or extension is optional.":
            "Noonix TV pušta snimke sa ovog Mac-a i izvore koje sam dodaš. Izaberi foldere u kojima su ti filmovi i serije; addon ili ekstenzija nisu obavezni.",
        "Noonix TV is only a player. It comes with no videos and no sources: it plays the files on your Mac and whatever addons or extensions you add yourself.":
            "Noonix TV je samo plejer. Ne dolazi ni sa jednim snimkom ni izvorom: pušta fajlove sa tvog Mac-a i addone ili ekstenzije koje sam dodaš.",
        "On this Mac": "Na ovom Mac-u",
        "No videos from this Mac yet": "Još nema snimaka sa ovog Mac-a",
        "A .noonix file on this Mac": ".noonix fajl na ovom Mac-u",
        "Pick it in the window that opened": "Izaberi u prozoru koji se otvorio",
        "How fast this internet connection and this Mac are. The next step picks a picture quality from it.":
            "Koliko su brzi internet i ovaj Mac. Prema tome sledeći korak bira kvalitet slike.",
        "This Mac": "Ovaj Mac",
        "This Mac is the weaker of the two": "Slabija karika je ovaj Mac",
        "this Mac": "ovaj Mac",
        "On This Mac": "Na ovom Mac-u",
        "May be too much for this Mac": "Možda je previše za ovaj Mac",
        "Starts Noonix TV when you sign in to this Mac": "Pokreće Noonix TV kad se prijaviš na Mac",
        "Starts Noonix TV when you sign in, handy on a Mac made for the TV": "Pokreće Noonix TV kad se prijaviš, zgodno za Mac namenjen televizoru",
        "Couldn't change it: move Noonix TV to Applications first": "Nije promenjeno: prvo premesti Noonix TV u Aplikacije",
        "A real keyboard works too, and ⌘V pastes. Back closes this.": "Radi i prava tastatura, a ⌘V lepi. Nazad zatvara.",
        "The player could not start.": "Plejer nije mogao da se pokrene.",
        "Open in Another Player": "Otvori u drugom plejeru",
        "Video playback through MPVKit (LGPL)": "Puštanje videa preko MPVKit-a (LGPL)",
        "Every bundled library with its license and source: THIRD-PARTY.txt in the app's Resources":
            "Svaka uključena biblioteka sa licencom i izvorom: THIRD-PARTY.txt u Resources aplikacije",
        "Logins are checked whenever the app runs": "Prijave se proveravaju dok aplikacija radi",
        "Open": "Otvori",
        "Match Hz": "Uskladi Hz",
        "Match the screen's refresh rate": "Uskladi osvežavanje ekrana",
        "Switches the screen to 24 / 25 / 50 / 60 Hz for each video (never the resolution or HDR)":
            "Prebacuje ekran na 24 / 25 / 50 / 60 Hz za svaki video (rezoluciju i HDR nikad ne dira)",
    ]
}

/// a ui line in the current language; %1, %2… filled from args (qsTr("…").arg(…))
func L(_ s: String, _ args: CustomStringConvertible...) -> String {
    var out = UILang.shared.tr(s)
    for (i, a) in args.enumerated() { out = out.replacingOccurrences(of: "%\(i + 1)", with: a.description) }
    return out
}

/// a line the core sent in english
func Lc(_ s: String) -> String { UILang.shared.core(s) }

/// a counted line: qsTr("%n season(s)", "", n)
func Ln(_ s: String, _ n: Int) -> String { UILang.shared.plural(s, n) }

/// .ts messages: source → translation (numerus ones as their forms)
private final class TsReader: NSObject, XMLParserDelegate {
    var out: [String: String] = [:]
    var core: [String: String] = [:]
    var plural: [String: [String]] = [:]
    private var context = ""
    private var text = "", source = "", numerus = false, forms: [String] = [], translation = ""

    func parser(_ p: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
        text = ""
        if e == "message" { numerus = a["numerus"] == "yes"; forms = []; source = ""; translation = "" }
    }

    func parser(_ p: XMLParser, foundCharacters s: String) { text += s }

    func parser(_ p: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName: String?) {
        switch e {
        case "source": source = text
        case "numerusform": forms.append(text)
        case "translation": translation = text
        case "name": context = text
        case "message":
            if numerus { if !forms.isEmpty { plural[source] = forms } } else if !translation.isEmpty {
                if out[source] == nil { out[source] = translation }
                if context == "core" { core[source] = translation }
            }
        default: break
        }
        text = ""
    }
}
