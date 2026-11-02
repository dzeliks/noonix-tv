import QtQuick

// the speed check, from settings or first setup: internet, then this device, each on a gauge cut
// into the picture quality zones. what you can watch is the weaker of the two
FocusScope {
    id: sc
    readonly property real u: Theme.u
    property var levels: []
    property var net: null               // null, { running }, { mbps }, { error }
    property var dev: null
    property real liveMbps: 0
    property int choice: 1
    property int generation: 0
    readonly property bool running: (!!net && !!net.running) || (!!dev && (!!dev.running || !!dev.next))
    signal measured()
    signal closed()
    visible: opacity > 0
    opacity: 0
    Behavior on opacity { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }

    readonly property var names: ({ light: qsTr("Light"), hd: qsTr("Full HD"), "4k": qsTr("4K"), max: qsTr("Maximum") })
    readonly property var colors: ["#FF7A6B", "#FFC24B", "#32D583", "#63C7FF"]
    function zonesFrom(key, top) {
        return levels.map(function (l, i) {
            var next = levels[i + 1]
            return { label: sc.names[l.id] || l.id, from: l[key], to: next ? next[key] : top, color: sc.colors[i % sc.colors.length] }
        })
    }
    readonly property var netZones: zonesFrom("needMbps", 600)
    readonly property var devZones: zonesFrom("needDevice", 130)
    function zoneIn(zs, v) {
        var z = -1
        for (var i = 0; i < zs.length; ++i) if (v >= zs[i].from) z = i
        return z
    }
    function label(zs, v) { var z = zoneIn(zs, v); return z >= 0 ? zs[z].label : "" }
    readonly property bool netDone: !!net && net.mbps !== undefined
    readonly property bool devDone: !!dev && dev.score !== undefined
    readonly property int netZone: netDone ? zoneIn(netZones, net.mbps) : -1
    readonly property int devZone: devDone ? zoneIn(devZones, dev.score) : -1
    readonly property bool bothDone: netDone && devDone
    readonly property string deviceName: Theme.android ? qsTr("This device") : qsTr("This PC")
    readonly property string headline: {
        if (running || (!netDone && !devDone)) return ""
        if (bothDone) return (netZones[Math.min(netZone, devZone)] || {}).label || ""
        return netDone ? netZones[netZone].label : devDone ? devZones[devZone].label : ""
    }
    readonly property string why: {
        if (running) return ""
        if (bothDone) return netZone < devZone ? qsTr("Your internet is the weaker of the two")
                           : devZone < netZone ? (Theme.android ? qsTr("This device is the weaker of the two") : qsTr("This PC is the weaker of the two"))
                           : qsTr("Both reach the same zone")
        return netDone || devDone ? qsTr("Only one of the two could be measured") : ""
    }

    function open(auto) {
        choice = 1
        opacity = 1
        forceActiveFocus()
        Api.call("quality.options", {}, function (ok, d) {
            if (!ok) return
            sc.levels = d.levels || []
            if (!sc.net && d.mbps !== null && d.mbps !== undefined) sc.net = { mbps: d.mbps }
            if (!sc.dev && d.device !== null && d.device !== undefined) sc.dev = { score: d.device }
            if (auto) sc.run()
        })
    }
    function close() { opacity = 0; closed() }
    function run() {
        if (running) return
        var request = ++generation
        liveMbps = 0
        net = { running: true }
        dev = { next: true }
        // one after the other: the cpu test would slow the download down
        Api.call("bench.internet", {}, function (ok, d) {
            if (request !== sc.generation) return
            sc.net = ok ? d : { error: qsTr("Couldn't measure") }
            sc.dev = { running: true }
            Api.call("bench.device", {}, function (ok2, d2) {
                if (request !== sc.generation) return
                sc.dev = ok2 ? d2 : { error: qsTr("Couldn't measure") }
                sc.measured()
            })
        })
    }
    Connections {
        target: Api
        function onPushed(name, d) { if (name === "bench" && d && sc.net && sc.net.running) sc.liveMbps = d.mbps }
    }

    Glass { anchors.fill: parent; kind: "panel"; radius: 0; refraction: 0; dim: Theme.veil }
    Shield { onOutside: sc.close() }

    Item {
        anchors.centerIn: parent
        width: 1440 * sc.u
        height: body.height + 2 * 48 * sc.u
        scale: sc.opacity > 0.5 ? 1 : 0.96
        Behavior on scale { NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }
        Glass { anchors.fill: parent; kind: "panel"; radius: 60 * sc.u }
        Column {
            id: body
            x: 48 * sc.u; y: 48 * sc.u
            width: parent.width - 96 * sc.u
            spacing: 24 * sc.u
            Text {
                text: qsTr("Speed check")
                color: Theme.fg
                font { family: Theme.display; pixelSize: 42 * sc.u; weight: Font.Bold }
            }
            Row {
                spacing: 24 * sc.u
                Gauge {
                    width: (body.width - 24 * sc.u) / 2
                    height: 560 * sc.u
                    title: qsTr("Internet")
                    zones: sc.netZones
                    value: sc.netDone ? sc.net.mbps : sc.net && sc.net.running ? sc.liveMbps : 0
                    measured: sc.netDone
                    number: sc.netDone ? String(sc.net.mbps) : sc.net && sc.net.running && sc.liveMbps > 0 ? String(Math.round(sc.liveMbps)) : ""
                    unit: qsTr("Mbit/s")
                    note: sc.net && sc.net.error ? sc.net.error : ""
                    weakest: sc.bothDone && sc.netZone <= sc.devZone
                }
                Gauge {
                    width: (body.width - 24 * sc.u) / 2
                    height: 560 * sc.u
                    title: sc.deviceName
                    zones: sc.devZones
                    value: sc.devDone ? sc.dev.score : 0
                    measured: sc.devDone
                    busy: !!sc.dev && !!sc.dev.running
                    waiting: !!sc.dev && !!sc.dev.next
                    number: sc.devDone ? String(sc.dev.score) : ""
                    unit: qsTr("points")
                    note: sc.dev && sc.dev.error ? sc.dev.error : ""
                    weakest: sc.bothDone && sc.devZone <= sc.netZone
                }
            }
            // what it comes to: the weaker of the two
            Item {
                width: parent.width
                height: 84 * sc.u
                Column {
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 2 * sc.u
                    opacity: sc.headline ? 1 : 0
                    Behavior on opacity { NumberAnimation { duration: 320 } }
                    Text {
                        text: qsTr("You can watch up to %1").arg(sc.headline)
                        color: Theme.fg
                        font { family: Theme.display; pixelSize: 34 * sc.u; weight: Font.Bold }
                    }
                    Text {
                        text: sc.why
                        color: Theme.fg2
                        font { family: Theme.text; pixelSize: 23 * sc.u }
                    }
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: sc.running
                    text: qsTr("Measuring…")
                    color: Theme.fg2
                    font { family: Theme.display; pixelSize: 30 * sc.u; weight: Font.Medium }
                }
                Row {
                    anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                    spacing: 20 * sc.u
                    GlassButton {
                        text: qsTr("Run Again")
                        opacity: sc.running ? 0.45 : 1
                        focused: sc.activeFocus && sc.choice === 0
                        pointerFocus: false
                        onPointed: sc.choice = 0
                        onClicked: sc.run()
                    }
                    GlassButton {
                        primary: true
                        text: qsTr("Done")
                        focused: sc.activeFocus && sc.choice === 1
                        pointerFocus: false
                        onPointed: sc.choice = 1
                        onClicked: sc.close()
                    }
                }
            }
        }
    }

    function act() { if (choice === 0) run(); else close() }
    Keys.onReturnPressed: act()
    Keys.onEnterPressed: act()
    Keys.onLeftPressed: choice = 0
    Keys.onRightPressed: choice = 1
    Keys.onEscapePressed: close()
    Keys.onBackPressed: close()
    Keys.onPressed: function (e) { e.accepted = true }
}
