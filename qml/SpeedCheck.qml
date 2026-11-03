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
    property real liveScore: 0           // with a hardware decoder lifted to the top
    property real liveFps: 0
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
    readonly property var devZones: zonesFrom("needDevice", 80)
    function zoneIn(zs, v) {
        var z = -1
        for (var i = 0; i < zs.length; ++i) if (v >= zs[i].from) z = i
        return z
    }
    function label(zs, v) { var z = zoneIn(zs, v); return z >= 0 ? zs[z].label : "" }
    readonly property bool netDone: !!net && net.mbps !== undefined
    readonly property bool devDone: !!dev && dev.score !== undefined
    // what the cpu decodes (fps of 4k hevc 10-bit at 40 mbit/s, as calibrated), and whether a hardware decoder carries it
    function devText(d) {
        var fps = d.fps !== undefined && d.fps !== null ? d.fps : d.score
        return d.hardware ? qsTr("%1 fps (4K HDR, 40 Mbit/s) + hardware decoder").arg(fps) : qsTr("%1 fps (4K HDR, 40 Mbit/s)").arg(fps)
    }
    readonly property int netZone: netDone ? zoneIn(netZones, net.mbps) : -1
    readonly property int devZone: devDone ? zoneIn(devZones, dev.score) : -1
    readonly property bool bothDone: netDone && devDone
    readonly property string deviceName: qsTr("Device")
    readonly property bool netFailed: !!net && (!!net.error || !!net.skipped)
    readonly property string headline: {
        if (running || (!netDone && !devDone)) return ""
        if (bothDone) return (netZones[Math.min(netZone, devZone)] || {}).label || ""
        return ((netDone ? netZones[netZone] : devDone ? devZones[devZone] : null) || {}).label || ""
    }
    // only said when it's worth knowing: without internet the device alone decides
    readonly property string why: !running && netFailed && devDone ? qsTr("No internet, so it follows the device") : ""
    function open(auto) {
        choice = 1
        opacity = 1
        forceActiveFocus()
        Player.probeHevc10()
        Api.call("quality.options", {}, function (ok, d) {
            if (!ok) return
            sc.levels = d.levels || []
            if (!sc.net && d.mbps !== null && d.mbps !== undefined) sc.net = { mbps: d.mbps }
            if (!sc.dev && d.device !== null && d.device !== undefined) sc.dev = { score: d.device, fps: d.deviceFps, hardware: d.hardware }
            if (auto) sc.run()
        })
    }
    function close() { opacity = 0; closed() }
    // no internet worth waiting for: straight on to the device
    function skip() {
        if (!net || !net.running) return
        net = { skipped: true }
        Api.call("bench.skipInternet", {})
    }
    function run() {
        if (running) return
        var request = ++generation
        liveMbps = 0
        liveScore = 0
        liveFps = 0
        hwWait.tries = 0
        net = { running: true }
        dev = { next: true }
        // one after the other: the cpu test would slow the download down
        Api.call("bench.internet", {}, function (ok, d) {
            if (request !== sc.generation) return
            sc.net = ok ? d : sc.net && sc.net.skipped ? sc.net : { error: qsTr("No connection") }
            sc.device(request)
        })
    }
    // the hardware decoder check runs since open(); give it up to 3 s, without one the cpu decides
    function device(request) {
        if (request !== generation) return
        if (Player.hevc10 < 0 && hwWait.tries < 30) { hwWait.request = request; hwWait.start(); return }
        dev = { running: true }
        Api.call("bench.device", { hardware: Player.hevc10 === 1 }, function (ok, d) {
            if (request !== sc.generation) return
            sc.dev = ok ? d : { error: qsTr("Couldn't measure") }
            sc.measured()
        })
    }
    Timer { id: hwWait; interval: 100; property int request; property int tries: 0; onTriggered: { tries++; sc.device(request) } }
    Connections {
        target: Api
        function onPushed(name, d) {
            if (name === "bench" && d && sc.net && sc.net.running) sc.liveMbps = d.mbps
            else if (name === "benchDevice" && d && sc.dev && sc.dev.running) { sc.liveScore = d.score; sc.liveFps = d.fps }
        }
    }

    Glass { anchors.fill: parent; kind: "panel"; radius: 0; refraction: 0; dim: Theme.veil }
    Shield { onOutside: sc.close() }

    Item {
        anchors.centerIn: parent
        width: 880 * sc.u
        height: body.height + 2 * 44 * sc.u
        scale: sc.opacity > 0.5 ? 1 : 0.96
        Behavior on scale { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
        Glass { anchors.fill: parent; kind: "panel"; radius: 52 * sc.u }
        Column {
            id: body
            x: 58 * sc.u; y: 44 * sc.u
            width: parent.width - 116 * sc.u
            spacing: 0
            Text {
                text: qsTr("Speed check")
                color: Theme.fg
                font { family: Theme.display; pixelSize: 36 * sc.u; weight: Font.Bold }
            }
            Row {
                topPadding: 26 * sc.u
                spacing: 24 * sc.u
                Gauge {
                    width: (body.width - 24 * sc.u) / 2
                    title: qsTr("Internet")
                    zones: sc.netZones
                    value: sc.netDone ? sc.net.mbps : sc.liveMbps
                    measuring: !!sc.net && !!sc.net.running
                    measured: sc.netDone
                    decided: sc.bothDone
                    chosen: sc.netZone <= sc.devZone
                    number: sc.netDone ? String(sc.net.mbps) : measuring && sc.liveMbps > 0 ? String(Math.round(sc.liveMbps)) : ""
                    unit: qsTr("Mbit/s")
                    note: sc.net && sc.net.skipped ? qsTr("Skipped") : sc.net && sc.net.error ? sc.net.error : ""
                }
                Gauge {
                    width: (body.width - 24 * sc.u) / 2
                    title: sc.deviceName
                    zones: sc.devZones
                    value: sc.devDone ? sc.dev.score : sc.liveScore
                    measuring: !!sc.dev && !!sc.dev.running
                    measured: sc.devDone
                    waiting: !!sc.dev && !!sc.dev.next
                    // without internet the device alone decides
                    decided: sc.bothDone || (sc.netFailed && sc.devDone)
                    chosen: !sc.netDone || sc.devZone <= sc.netZone
                    number: sc.devDone ? String(sc.dev.fps !== undefined && sc.dev.fps !== null ? sc.dev.fps : sc.dev.score)
                                       : measuring && sc.liveFps > 0 ? String(Math.round(sc.liveFps)) : ""
                    unit: qsTr("fps · 4K HDR, 40 Mbit/s")
                    extra: (sc.devDone ? sc.dev.hardware : Player.hevc10 === 1) ? qsTr("+ hardware decoder") : ""
                    note: sc.dev && sc.dev.error ? sc.dev.error : ""
                }
            }
            // what it comes to: the weaker of the two
            Item {
                width: parent.width
                height: verdict.height + 70 * sc.u
                Column {
                    id: verdict
                    y: 34 * sc.u
                    width: parent.width
                    spacing: 6 * sc.u
                    opacity: sc.headline ? 1 : 0
                    Behavior on opacity { NumberAnimation { duration: 320 } }
                    Text {
                        width: parent.width
                        horizontalAlignment: Text.AlignHCenter
                        text: sc.headline ? qsTr("You can watch up to %1").arg(sc.headline) : " "
                        color: Theme.fg
                        font { family: Theme.display; pixelSize: 30 * sc.u; weight: Font.Bold }
                    }
                    Text {
                        width: parent.width
                        horizontalAlignment: Text.AlignHCenter
                        wrapMode: Text.WordWrap
                        text: sc.why ? qsTr("No internet, so it follows the device. Change it any time in Settings › Sources")
                                      : qsTr("You can change the picture quality any time in Settings › Sources")
                        color: Theme.fg3
                        font { family: Theme.text; pixelSize: 19 * sc.u }
                    }
                }
            }
            Row {
                topPadding: 8 * sc.u
                anchors.right: parent.right
                spacing: 20 * sc.u
                GlassButton {
                    // while the internet is measured it can be skipped (no connection, or no patience)
                    text: sc.net && sc.net.running ? qsTr("Skip") : qsTr("Run Again")
                    opacity: sc.running && !(sc.net && sc.net.running) ? 0.45 : 1
                    focused: sc.activeFocus && sc.choice === 0
                    pointerFocus: false
                    onPointed: sc.choice = 0
                    onClicked: sc.skipOrRun()
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

    function skipOrRun() { if (net && net.running) skip(); else run() }
    function act() { if (choice === 0) skipOrRun(); else close() }
    Keys.onReturnPressed: act()
    Keys.onEnterPressed: act()
    Keys.onLeftPressed: choice = 0
    Keys.onRightPressed: choice = 1
    Keys.onEscapePressed: close()
    Keys.onBackPressed: close()
    Keys.onPressed: function (e) { e.accepted = true }
}
