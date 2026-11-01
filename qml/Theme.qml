pragma Singleton
import QtQuick

// design tokens: a 1920x1080 grid scaled to the screen (u = 2 on the 4k tv)
QtObject {
    property real u: 1
    // a phone, tablet or android tv: no desktop parts, a device rather than a pc
    readonly property bool android: Qt.platform.os === "android"
    // how dark the frost behind a full-screen prompt or sheet is
    readonly property real veil: 0.74
    readonly property color skeleton: Qt.rgba(1, 1, 1, 0.1)
    // sf pro where the pc has it (apple's licence: it can't ship with us), else the bundled inter
    readonly property var families: Qt.fontFamilies()
    function has(f) { return families.indexOf(f) >= 0 }
    readonly property bool needInter: !has("SF Pro Display") || !has("SF Pro Text") || !has("SF Pro Rounded")
    property FontLoader inter: FontLoader { source: needInter ? "qrc:/fonts/InterVariable.ttf" : "" }
    readonly property string fallback: inter.name || "Inter"
    readonly property string display: has("SF Pro Display") ? "SF Pro Display" : fallback
    readonly property string text: has("SF Pro Text") ? "SF Pro Text" : fallback
    readonly property string rounded: has("SF Pro Rounded") ? "SF Pro Rounded" : fallback

    readonly property color bg: "#000000"
    readonly property color fg: "#FFFFFF"
    readonly property color fg2: Qt.rgba(1, 1, 1, 0.66)
    readonly property color fg3: Qt.rgba(1, 1, 1, 0.42)
    readonly property color accent: "#A56BFF"          // the mpv skin's purple
    readonly property color focusFg: "#1C1C1E"
    readonly property color cached: "#FFD60A"
    readonly property color danger: "#FF6F7D"

    readonly property real margin: 96 * u             // tv side margin
    readonly property real radius: 22 * u

    // springs shared by every focus lift, so the whole ui moves alike
    readonly property real springK: 4.2
    readonly property real springDamp: 0.62
    // cards under the mouse right now: with the mouse in use the focused card is lifted only
    // while the mouse is on a card (moving off it lets it down, back on lifts it again)
    property int pointedCards: 0

    function px(v) { return v * u }
    function time(secs) {
        secs = Math.max(0, Math.floor(secs || 0))
        var h = Math.floor(secs / 3600), m = Math.floor(secs / 60) % 60, s = secs % 60
        return (h ? h + ":" + String(m).padStart(2, "0") : m) + ":" + String(s).padStart(2, "0")
    }
    function runtime(mins) {
        if (!mins) return ""
        var h = Math.floor(mins / 60), m = mins % 60
        return h ? h + "h " + (m ? m + "m" : "") : m + "m"
    }
    // a counted line in english, which has no translation file to settle "(s)" in qsTr("%n season(s)", "", n)
    // language options with the chosen ones first, in the order chosen; the rest as they come
    function preferredFirst(opts, chosen) {
        var top = [], rest = []
        opts.forEach(function (o) { (chosen.indexOf(o.code) >= 0 ? top : rest).push(o) })
        top.sort(function (a, b) { return chosen.indexOf(a.code) - chosen.indexOf(b.code) })
        return top.concat(rest)
    }
    function counted(t, n) { return t.replace("(s)", n === 1 ? "" : "s") }
    // "today", "tomorrow", "Sat 25 Oct"
    function day(iso) {
        if (!iso) return ""
        var d = new Date(iso), now = new Date()
        var a = new Date(now.getFullYear(), now.getMonth(), now.getDate()), b = new Date(d.getFullYear(), d.getMonth(), d.getDate())
        var diff = Math.round((b - a) / 86400000)
        return diff === 0 ? qsTr("today") : diff === 1 ? qsTr("tomorrow") : Qt.formatDate(d, "ddd d MMM")
    }
    // subtitle timing: "+0.4 s", "−1.2 s"
    function signedSecs(s) { return (s > 0 ? "+" : s < 0 ? "−" : "") + Math.abs(s || 0).toFixed(1).replace(".", Qt.locale().decimalPoint) + " s" }
    // a line the core sent in english (qml/CoreStrings.js lists them), %1 = its count
    function coreText(msg, count) {
        var t = qsTranslate("core", msg || "")
        return count !== undefined && count !== null ? t.arg(count) : t
    }
    // the key sheets of the debrid services an extension can ask for
    readonly property var debridKeys: ({
        TORBOX_API_KEY: { title: qsTr("TorBox API key"), hint: qsTr("torbox.app › Settings › API key"), placeholder: "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" },
        REALDEBRID_API_KEY: { title: qsTr("Real-Debrid API token"), hint: qsTr("real-debrid.com/apitoken, signed in"), placeholder: qsTr("API token") },
        ALLDEBRID_API_KEY: { title: qsTr("AllDebrid API key"), hint: qsTr("alldebrid.com › Account › API keys › Create"), placeholder: qsTr("API key") }
    })
    // picture quality levels (quality.options) as setup / settings lines: the recommended one says so,
    // the ones above it say why they may not play well here
    // (setup shows the recommended one checked until something is picked)
    function qualityLines(q, setup) {
        if (!q || !q.levels) return []
        var names = { light: qsTr("Light"), hd: qsTr("Full HD"), "4k": qsTr("4K"), max: qsTr("Maximum") }
        var about = {
            light: qsTr("Up to 1080p in smaller files. Smooth even on slow internet"),
            hd: qsTr("1080p at full quality"),
            "4k": qsTr("4K and HDR, without the biggest untouched copies"),
            max: qsTr("Everything, up to untouched copies of 60 GB and more")
        }
        var cur = setup && !q.chosen ? q.recommended : q.current, rec = 0
        for (var i = 0; i < q.levels.length; ++i) if (q.levels[i].id === q.recommended) rec = i
        return q.levels.map(function (l, i) {
            var warn = i <= rec ? ""
                : !l.netOk ? qsTr("May stutter: wants about %1 Mbit/s, this connection has %2").arg(l.needMbps).arg(q.mbps)
                : !l.deviceOk ? (Theme.android ? qsTr("May be too much for this device") : qsTr("May be too much for this PC"))
                : qsTr("Not measured yet: may stutter here")
            return { label: l.id === q.recommended ? qsTr("%1 (Recommended)").arg(names[l.id]) : names[l.id],
                     detail: about[l.id] + (warn ? "  ·  " + warn : ""), checkable: true, checked: l.id === cur, act: "quality:" + l.id }
        })
    }
    // "ends at 23:41" for something that still has `secs` to go
    function endsAt(secs) {
        if (!secs || secs <= 0) return ""
        return Qt.formatTime(new Date(Date.now() + secs * 1000), "HH:mm")
    }
    // track language tags (iso 639-1/2, with or without a region: en-US, es-419) as names
    function langName(tag) {
        var parts = (tag || "").split(/[-_]/), l = parts[0].toLowerCase(), region = (parts[1] || "").toUpperCase()
        var regional = { "es-419": "Spanish (Latin America)", "pt-BR": "Portuguese (Brazil)", "fr-CA": "French (Canada)",
                         "zh-HANT": "Chinese (Traditional)", "zh-TW": "Chinese (Traditional)", "zh-HK": "Chinese (Hong Kong)" }
        var r = regional[l + "-" + region] || regional[l + "-" + (parts[1] || "")]
        if (r) return qsTranslate("core", r)
        var names = { eng: "English", en: "English", srp: "Serbian", sr: "Serbian", scc: "Serbian", hrv: "Croatian", hr: "Croatian", scr: "Croatian",
                      bos: "Bosnian", bs: "Bosnian", ger: "German", deu: "German", de: "German", fre: "French", fra: "French", fr: "French",
                      spa: "Spanish", es: "Spanish", ita: "Italian", it: "Italian", rus: "Russian", ru: "Russian", jpn: "Japanese", ja: "Japanese",
                      kor: "Korean", ko: "Korean", por: "Portuguese", pt: "Portuguese", slv: "Slovenian", sl: "Slovenian", mac: "Macedonian", mkd: "Macedonian",
                      pol: "Polish", pl: "Polish", dut: "Dutch", nld: "Dutch", nl: "Dutch", tur: "Turkish", tr: "Turkish", chi: "Chinese", zho: "Chinese", zh: "Chinese",
                      bul: "Bulgarian", bg: "Bulgarian", gre: "Greek", ell: "Greek", el: "Greek", cze: "Czech", ces: "Czech", cs: "Czech",
                      slo: "Slovak", slk: "Slovak", sk: "Slovak", hun: "Hungarian", hu: "Hungarian", rum: "Romanian", ron: "Romanian", ro: "Romanian",
                      swe: "Swedish", sv: "Swedish", dan: "Danish", da: "Danish", nor: "Norwegian", nob: "Norwegian", no: "Norwegian", nb: "Norwegian",
                      fin: "Finnish", fi: "Finnish", ice: "Icelandic", isl: "Icelandic", est: "Estonian", et: "Estonian", lav: "Latvian", lv: "Latvian",
                      lit: "Lithuanian", lt: "Lithuanian", ukr: "Ukrainian", uk: "Ukrainian", ara: "Arabic", ar: "Arabic", heb: "Hebrew", he: "Hebrew",
                      hin: "Hindi", hi: "Hindi", tha: "Thai", th: "Thai", vie: "Vietnamese", vi: "Vietnamese", ind: "Indonesian", id: "Indonesian",
                      may: "Malay", msa: "Malay", ms: "Malay", fil: "Filipino", tgl: "Filipino", cat: "Catalan", ca: "Catalan", baq: "Basque", eus: "Basque",
                      glg: "Galician", gl: "Galician", per: "Persian", fas: "Persian", fa: "Persian", alb: "Albanian", sqi: "Albanian", sq: "Albanian",
                      tam: "Tamil", ta: "Tamil", tel: "Telugu", te: "Telugu", is: "Icelandic", mk: "Macedonian",
                      mon: "Mongolian", mn: "Mongolian", kaz: "Kazakh", kk: "Kazakh", geo: "Georgian", kat: "Georgian", ka: "Georgian",
                      arm: "Armenian", hye: "Armenian", hy: "Armenian", ben: "Bengali", bn: "Bengali", urd: "Urdu", ur: "Urdu",
                      kan: "Kannada", kn: "Kannada", mal: "Malayalam", ml: "Malayalam", mar: "Marathi", mr: "Marathi",
                      lat: "Latin", la: "Latin", wel: "Welsh", cym: "Welsh", cy: "Welsh", gle: "Irish", ga: "Irish",
                      swa: "Swahili", sw: "Swahili", afr: "Afrikaans", af: "Afrikaans", zul: "Zulu", zu: "Zulu",
                      yue: "Cantonese", nno: "Norwegian", und: qsTr("Unknown") }
        return names[l] ? qsTranslate("core", names[l]) : (l ? l.toUpperCase() : qsTr("Unknown"))
    }
}
