import QtQuick

// "finding the best source": a glass dialog in the middle of the screen with apple's spinner,
// up from the search until the first video frame; back cancels
FocusScope {
    id: f
    readonly property real u: Theme.u
    property var target: null            // {kind, tmdb, season?, episode?}
    property var details: null
    property string episodeTitle: ""
    property string status: ""
    property string detail: ""
    signal cancel()
    visible: opacity > 0
    opacity: 0
    // cut, never fade, once the video is up (hdr under a fading window dips)
    Behavior on opacity { enabled: !win.videoUp; NumberAnimation { duration: 220; easing.type: Easing.OutQuad } }

    function open(t, from) {
        target = t
        episodeTitle = from && from.episodeTitle ? from.episodeTitle : ""
        details = null
        status = qsTr("Finding the best source…")
        detail = ""
        opacity = 1
        forceActiveFocus()
        var want = t.tmdb
        Api.call("tmdb.details", { kind: t.kind === "movie" ? "movie" : "show", id: t.tmdb }, function (ok, d) {
            if (ok && f.target && f.target.tmdb === want) f.details = d
        })
    }
    // what was picked, while it opens
    function starting(s) {
        status = qsTr("Starting")
        var bits = []
        if (s.resolution >= 2160) bits.push("4K")
        else if (s.resolution > 0) bits.push(s.resolution + "p")
        var hdr = s.hdr || []
        if (hdr.indexOf("DV") >= 0) bits.push("Dolby Vision")
        else if (hdr.length) bits.push(hdr[0])
        if (s.source) bits.push(s.source)
        if (s.group) bits.push(s.group)
        detail = bits.join("  ·  ")
    }
    function close() { opacity = 0 }

    Keys.onEscapePressed: cancel()
    Keys.onBackPressed: cancel()
    Keys.onPressed: function (e) { e.accepted = true }   // nothing else while it searches

    // the page behind, frosted
    Glass { anchors.fill: parent; kind: "panel"; radius: 0; refraction: 0; dim: Theme.veil }
    Shield {}

    Glass {
        id: card
        anchors.centerIn: parent
        width: 760 * f.u
        height: col.height + 2 * 56 * f.u
        radius: 56 * f.u
        kind: "panel"
        scale: f.opacity > 0.5 ? 1 : 0.94
        Behavior on scale { SpringAnimation { spring: Theme.springK; damping: Theme.springDamp; epsilon: 0.0005 } }
    }
    Column {
        id: col
        anchors.centerIn: card
        width: card.width - 2 * 64 * f.u
        spacing: 18 * f.u
        scale: card.scale

        Logo {
            anchors.horizontalCenter: parent.horizontalCenter
            width: 440 * f.u
            height: 120 * f.u
            titleSize: 52 * f.u
            source: f.details && f.details.logo ? f.details.logo : ""
            loading: !f.details
            title: f.details ? f.details.title || "" : ""
        }
        Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            visible: text !== ""
            elide: Text.ElideRight
            text: !f.target || f.target.kind === "movie" || !f.target.season ? ""
                : "S" + f.target.season + " · E" + f.target.episode + (f.episodeTitle ? "  " + f.episodeTitle : "")
            color: Theme.fg2
            font { family: Theme.display; pixelSize: 26 * f.u; weight: Font.DemiBold }
        }
        Item { width: 1; height: 14 * f.u }
        Spinner {
            anchors.horizontalCenter: parent.horizontalCenter
            width: 60 * f.u; height: width
            running: f.visible
        }
        Item { width: 1; height: 6 * f.u }
        Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: f.status
            color: Theme.fg
            font { family: Theme.display; pixelSize: 29 * f.u; weight: Font.DemiBold }
        }
        Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
            visible: text !== ""
            text: f.detail
            color: Theme.fg2
            font { family: Theme.text; pixelSize: 23 * f.u; weight: Font.Medium }
        }
    }
}
