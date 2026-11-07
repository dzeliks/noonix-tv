import QtQuick

// "2024 · Drama, Crime · 2h 46m · ★ 8.4 · 16+ · Ends at 23:41"
Row {
    id: meta
    property var item: null
    property var details: null
    readonly property real u: Theme.u
    // an episode has its own length: the show's is only a fallback
    readonly property bool episode: !!item && (item.kind || (details && details.kind)) === "episode"
    readonly property int runtime: episode ? ((item && item.runtime) || (details && details.runtime) || 0)
                                           : ((details && details.runtime) || (item && item.runtime) || 0)
    // what is left to watch: the resume point counts. a whole show has no end time
    readonly property real remaining: {
        if (!item) return 0
        var kind = item.kind || (details && details.kind) || ""
        if (kind !== "movie" && kind !== "episode") return 0
        if (item.duration && item.position) return item.duration - item.position
        return runtime * 60
    }
    // the room it has (0: any). short of it the genres go first, then the rating
    property real maxWidth: 0
    function partsFor(genres) {
        var p = []
        if (!item) return p
        if (item.year) p.push(String(item.year))
        var g = (item.genres || []).slice(0, 2)
        if (genres && g.length) p.push(g.map(function (x) { return qsTranslate("core", x) }).join(", "))
        if (runtime) p.push(Theme.runtime(runtime))
        if (details && details.certification) p.push(details.certification)
        return p
    }
    TextMetrics { id: fullM; font: first.font; text: meta.partsFor(true).join("  ·  ") }
    TextMetrics { id: shortM; font: first.font; text: meta.partsFor(false).join("  ·  ") }
    TextMetrics { id: starM; font: first.font; text: rating.text }
    TextMetrics { id: endM; font: ends.font; text: ends.text }
    readonly property real tail: (item && item.rating > 0 ? starM.advanceWidth + spacing : 0) + (ends.visible ? endM.advanceWidth + spacing : 0)
    readonly property int level: maxWidth <= 0 || fullM.advanceWidth + tail <= maxWidth ? 0
                                 : shortM.advanceWidth + tail <= maxWidth ? 1 : 2
    readonly property var parts: partsFor(level === 0)
    spacing: 14 * u

    Text {
        id: first
        anchors.verticalCenter: parent.verticalCenter
        text: meta.parts.join("  ·  ")
        color: Theme.fg2
        font { family: Theme.text; pixelSize: 24 * meta.u; weight: Font.Medium }
    }
    Text {
        id: rating
        anchors.verticalCenter: parent.verticalCenter
        visible: meta.level < 2 && !!meta.item && meta.item.rating > 0
        text: "★ " + (meta.item ? meta.item.rating : "")
        color: Theme.fg2
        font { family: Theme.text; pixelSize: 24 * meta.u; weight: Font.Medium }
    }
    Text {
        id: ends
        anchors.verticalCenter: parent.verticalCenter
        visible: meta.remaining > 0
        // Clock.minute: re-evaluated once a minute
        text: (Clock.minute, qsTr("Ends at %1").arg(Theme.endsAt(meta.remaining)))
        color: Theme.fg
        font { family: Theme.text; pixelSize: 24 * meta.u; weight: Font.DemiBold }
    }
}
