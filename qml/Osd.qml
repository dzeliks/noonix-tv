import QtQuick
import QtQuick.Effects

// playback controls, tv osc layout on the 1080 grid: logo/title + episode line bottom
// left, seek bar, times, then a liquid glass row: subtitles + audio left, -10 / play / +10
// in the middle, next episode + exit right; clock + "ends at" top right; skip pill and the
// next episode card (no countdown, house rule)
FocusScope {
    id: osd
    readonly property real u: Theme.u
    readonly property var item: Player.item
    readonly property real pos: scrubLevel > 0 ? scrubT : Player.position
    readonly property real dur: Player.duration
    property bool shown: false
    property string zone: "bar"          // bar | row | skip | tracks
    property int rowIndex: 3
    property string exitArmed: ""        // back once more exits
    readonly property bool nextButton: nextReady && Player.state !== "ended"
    // no refresh switching on android
    readonly property var buttons: ["subs", "audio", "match", "rew", "play", "fwd"].concat(nextButton ? ["next"] : [], Theme.android ? [] : ["hz"], ["exit"])
    property bool pickerOpen: false          // a track picker covers the left side
    readonly property bool chromeShown: shown || Player.state === "ended"
    onChromeShownChanged: Player.setSubtitleLift(chromeShown)
    // the glass over video runs while any of this is on screen
    readonly property bool glassUp: chrome.visible || pill.visible
    readonly property string subLabel: {
        var t = (Player.subtitleTracks || []).filter(function (x) { return x.selected })[0]
        return t ? Theme.langName(t.lang) : qsTr("Off")
    }
    readonly property string audioLabel: {
        var t = (Player.audioTracks || []).filter(function (x) { return x.selected })[0]
        if (!t) return qsTr("Audio")
        var ch = t.channels === 6 ? "5.1" : t.channels === 8 ? "7.1" : t.channels === 2 ? qsTr("Stereo") : ""
        // a track without a language says what it is, not "unknown"
        var known = t.lang && t.lang !== "und"
        return (known ? Theme.langName(t.lang) : qsTr("Audio")) + (ch ? "  ·  " + ch : "")
    }
    // the segment we're in (intro / recap / outro), from chapters, introdb or the guess
    readonly property var segment: {
        var segs = Player.segments || []
        for (var i = 0; i < segs.length; ++i)
            if (pos >= segs[i].start && pos < segs[i].end - 1) return segs[i]
        return null
    }
    readonly property bool nextReady: !!(Player.next && Player.next.stream)
    // the next episode card: the outro, or the last 50 s when the outro starts later (or isn't known)
    readonly property bool nearEnd: Player.duration > 300 && pos >= Player.duration - 50
    readonly property bool nextUp: nextReady && (Player.state === "ended" || nearEnd || (!!segment && segment.kind === "outro"))
    readonly property bool pillShown: (!!segment && Player.state === "playing") || nextUp
    signal exit()
    signal pickTracks(string kind, real x, real w)
    // the match sheet, above the row like the track picker
    signal rateMatch(real x, real w)

    component RowButton: GlassButton {
        id: rb
        required property string key
        glass: true
        pointerFocus: false
        onPointed: { osd.zone = "row"; osd.rowIndex = osd.buttons.indexOf(rb.key); osd.show() }
        onClicked: osd.act(rb.key)
        focused: osd.zone === "row" && osd.buttons[osd.rowIndex] === key
        height: 76 * osd.u
        iconSize: 34 * osd.u
    }

    // the controls always come up on play / pause; seeking keeps the bar
    function show(secs, z) {
        if (!shown) {
            zone = z || "row"
            rowIndex = buttons.indexOf("play")
        }
        shown = true
        hideTimer.interval = (secs || 5) * 1000
        if (!Player.paused && !pickerOpen) hideTimer.restart(); else hideTimer.stop()
    }
    function hide() { shown = false; zone = "bar"; exitArmed = "" }
    // left alone while playing: the controls go down, wherever the focus is
    Timer { id: hideTimer; onTriggered: if (!Player.paused && !osd.pickerOpen) osd.hide() }
    onPickerOpenChanged: if (!pickerOpen && shown) show()
    Connections {
        target: Player
        function onPausedChanged() { if (Player.paused) osd.show(); else osd.show(2) }
        function onStateChanged() {
            if (Player.state === "playing") osd.show(5)
            // the end: the next episode card takes the focus, ok plays it
            else if (Player.state === "ended") { osd.show(); osd.zone = osd.nextReady ? "skip" : "row" }
        }
    }

    // ---- fast-forward / rewind scrubbing (like remote.lua): x8 doubling to x1024, the other
    // button slows down then turns round; paused while the thumb moves, previews from the cache;
    // ok / play / an arrow jumps there, back cancels
    readonly property var scrubRates: [8, 16, 32, 64, 128, 256, 512, 1024]
    property int scrubLevel: 0
    property int scrubDir: 0
    property real scrubT: 0
    property real scrubStart: 0
    property real scrubCacheEnd: 0
    property real scrubShown: -1
    property bool scrubWasPaused: false
    readonly property int scrubRate: scrubLevel > 0 ? scrubRates[scrubLevel - 1] : 0
    function scrubPress(dir) {
        if (scrubLevel === 0) {
            scrubDir = dir; scrubLevel = 1
            scrubT = Player.position; scrubStart = scrubT; scrubShown = -1
            scrubCacheEnd = Player.position + Player.cacheAhead
            scrubWasPaused = Player.paused
            Player.setPaused(true)
            show(0, "bar")
            zone = "bar"
        } else if (scrubDir === dir) {
            scrubLevel = Math.min(scrubRates.length, scrubLevel + 1)
        } else {
            scrubLevel--
            if (scrubLevel === 0) { scrubDir = dir; scrubLevel = 1 }
        }
        show()
    }
    function scrubStop(commit) {
        if (scrubLevel === 0) return false
        scrubLevel = 0
        if (commit) Player.seekTo(scrubT)
        else if (scrubShown >= 0) Player.seekTo(scrubStart)
        Player.setPaused(scrubWasPaused)
        show(2)
        return true
    }
    Timer {
        interval: 250
        repeat: true
        running: osd.scrubLevel > 0
        onTriggered: {
            var t = osd.scrubT + osd.scrubDir * osd.scrubRate * 0.25
            osd.scrubT = Math.max(0, osd.dur > 0 ? Math.min(t, osd.dur - 1) : t)
            // the picture follows only where it's already in memory
            var cached = osd.scrubT >= osd.scrubStart - 20 && osd.scrubT <= osd.scrubCacheEnd
            if (cached && (osd.scrubShown < 0 || Math.abs(osd.scrubT - osd.scrubShown) >= 1)) {
                Player.seekPreview(osd.scrubT)
                osd.scrubShown = osd.scrubT
            }
        }
    }
    Connections {
        target: Player
        function onItemChanged() { osd.scrubLevel = 0 }
    }

    // ---- left / right: 10 s a tap, held = faster and faster (gamepad.lua's curve)
    property int holdDir: 0
    property real holdStart: 0
    property real holdLast: 0
    property real holdTotal: 0
    property string bubble: ""
    function heldSeek(dir) {
        var now = Date.now()
        if (dir !== holdDir || now - holdLast > 450) {
            holdDir = dir; holdStart = now; holdLast = now; holdTotal = 10
            Player.seek(dir * 10)
        } else {
            if (now - holdLast < 180) return
            holdLast = now
            var held = (now - holdStart) / 1000
            var amount = Math.min(Math.max(10, 3 + held * held * 14), 60)
            holdTotal += amount
            Player.seek(dir * amount)
        }
        bubble = (dir > 0 ? "+" : "−") + Theme.time(holdTotal)
        bubbleTimer.restart()
        show(2, "bar")
    }
    Timer { id: bubbleTimer; interval: 1200; onTriggered: { osd.bubble = ""; osd.holdDir = 0 } }

    function skipAction() {
        if (nextUp) { Player.playNext(); return }
        if (segment) Player.seekTo(segment.kind === "outro" ? Math.max(0, dur - 1) : segment.end)
    }
    // the sheet spans the left group (subtitles, audio, this button), like the track picker
    function openMatch() {
        var l = subsBtn.mapToItem(osd, 0, 0).x, r = matchBtn.mapToItem(osd, matchBtn.width, 0).x
        osd.rateMatch(l, r - l)
    }
    function act(b) {
        // the open picker goes down with anything else; the buttons that open one swap or close it
        if (pickerOpen && b !== "subs" && b !== "audio" && b !== "match") win.closePickers()
        if (b === "play") Player.togglePause()
        else if (b === "rew") Player.seek(-10)
        else if (b === "fwd") Player.seek(10)
        else if (b === "subs" || b === "audio") {
            // the picker spans both buttons, whichever opened it
            var l = subsBtn.mapToItem(osd, 0, 0).x, r = audioBtn.mapToItem(osd, audioBtn.width, 0).x
            osd.pickTracks(b === "subs" ? "sub" : "audio", l, r - l)
        }
        else if (b === "match") openMatch()
        else if (b === "next") { Player.playNext(); return }
        else if (b === "hz") Player.setRefreshMatch(!Player.refreshMatch)
        else if (b === "exit") osd.exit()
        show()
    }

    Keys.onPressed: function (e) {
        var k = e.key
        if (Desktop.debug) console.log("osd key", k, "shown", shown, "zone", zone, "scrub", scrubLevel)
        // a modifier alone (alt-tab, a shortcut on its way) isn't a press
        if (k === Qt.Key_Alt || k === Qt.Key_Control || k === Qt.Key_Shift || k === Qt.Key_Meta || k === Qt.Key_AltGr) { e.accepted = false; return }
        e.accepted = true
        var playKey = k === Qt.Key_MediaTogglePlayPause || k === Qt.Key_MediaPlay || k === Qt.Key_MediaPause || k === Qt.Key_Space
        if (k === Qt.Key_AudioForward) { scrubPress(1); return }
        if (k === Qt.Key_AudioRewind) { scrubPress(-1); return }
        if (scrubLevel > 0) {
            if (k === Qt.Key_Escape || k === Qt.Key_Back) scrubStop(false)
            else if (playKey || k === Qt.Key_Return || k === Qt.Key_Enter || k === Qt.Key_Left || k === Qt.Key_Right) scrubStop(true)
            return
        }
        if (playKey) { Player.togglePause(); return }
        if (k === Qt.Key_MediaStop) { osd.exit(); return }
        if (k === Qt.Key_PageUp) { Player.seek(30); show(); return }
        if (k === Qt.Key_PageDown) { Player.seek(-30); show(); return }
        if (k === Qt.Key_MediaNext) { if (nextReady) Player.playNext(); return }
        // the menu key: the match sheet, like a card's options while browsing
        if (k === Qt.Key_Menu) { show(); zone = "row"; rowIndex = buttons.indexOf("match"); openMatch(); return }
        if (k === Qt.Key_Escape || k === Qt.Key_Back) {
            if (exitArmed === "exit" || Player.state === "ended") { osd.exit(); return }
            if (shown) { hide(); return }
            // first back with the controls down: land on exit, a second one leaves
            show(); zone = "row"; rowIndex = buttons.length - 1; exitArmed = "exit"
            return
        }
        exitArmed = ""
        if (!shown) {
            if (k === Qt.Key_Left) { heldSeek(-1); return }
            if (k === Qt.Key_Right) { heldSeek(1); return }
            if ((k === Qt.Key_Return || k === Qt.Key_Enter) && pillShown) { skipAction(); return }
            show()
            return
        }
        if (zone === "bar") {
            if (k === Qt.Key_Left) { heldSeek(-1); return }
            else if (k === Qt.Key_Right) { heldSeek(1); return }
            else if (k === Qt.Key_Return || k === Qt.Key_Enter) Player.togglePause()
            else if (k === Qt.Key_Down) { zone = "row"; rowIndex = buttons.indexOf("play") }
            else if (k === Qt.Key_Up && pillShown) zone = "skip"
            else if (k === Qt.Key_Up) { hide(); return }
        } else if (zone === "row") {
            if (k === Qt.Key_Left) rowIndex = Math.max(0, rowIndex - 1)
            else if (k === Qt.Key_Right) rowIndex = Math.min(buttons.length - 1, rowIndex + 1)
            else if (k === Qt.Key_Up) zone = "bar"
            else if (k === Qt.Key_Return || k === Qt.Key_Enter) act(buttons[rowIndex])
        } else if (zone === "skip") {
            if (k === Qt.Key_Down) zone = "bar"
            else if (k === Qt.Key_Return || k === Qt.Key_Enter) skipAction()
        }
        show()
    }

    // the mouse: moving shows the controls, a click on the picture plays / pauses
    MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.NoButton
        cursorShape: osd.chromeShown ? Qt.ArrowCursor : Qt.BlankCursor
        onPositionChanged: if (Input.pointerLive()) osd.show()
        // a handler: mouse areas skip presses qt tags as a touchpad's
        TapHandler {
            acceptedButtons: Qt.LeftButton
            onTapped: {
                if (osd.pickerOpen) win.closePickers()
                else if (osd.shown) Player.togglePause()
                else osd.show()
            }
        }
    }

    // ---- the controls (fade as one)
    Item {
        id: chrome
        anchors.fill: parent
        opacity: osd.chromeShown ? 1 : 0
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: 260; easing.type: Easing.OutQuad } }

        Rectangle {
            anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
            height: 560 * osd.u
            gradient: Gradient {
                GradientStop { position: 0.0; color: Qt.rgba(0, 0, 0, 0) }
                GradientStop { position: 0.55; color: Qt.rgba(0, 0, 0, 0.42) }
                GradientStop { position: 1.0; color: Qt.rgba(0, 0, 0, 0.7) }
            }
        }
        Rectangle {
            anchors { left: parent.left; right: parent.right; top: parent.top }
            height: 220 * osd.u
            gradient: Gradient {
                GradientStop { position: 0.0; color: Qt.rgba(0, 0, 0, 0.55) }
                GradientStop { position: 1.0; color: Qt.rgba(0, 0, 0, 0) }
            }
        }

        // clock + ends at (top right, like an mpv osc)
        Column {
            anchors { right: parent.right; rightMargin: Theme.margin; top: parent.top; topMargin: 56 * osd.u }
            spacing: 2 * osd.u
            Text {
                anchors.right: parent.right
                text: Clock.hhmm
                color: Theme.fg
                font { family: Theme.rounded; pixelSize: 46 * osd.u; weight: Font.Bold }
            }
            Text {
                anchors.right: parent.right
                visible: osd.dur - osd.pos > 1
                // follows seeks (position) and the clock: paused, the end moves on every minute
                text: (Clock.minute, qsTr("Ends at %1").arg(Theme.endsAt(osd.dur - osd.pos)))
                color: Theme.fg2
                font { family: Theme.text; pixelSize: 25 * osd.u; weight: Font.Medium }
            }
        }

        // logo / title in a fixed box, bottom edge at H-336
        Logo {
            opacity: chipBox.on || osd.pickerOpen ? 0 : 1
            Behavior on opacity { NumberAnimation { duration: 160 } }
            x: Theme.margin
            y: parent.height - 336 * osd.u - height
            width: 520 * osd.u
            height: 150 * osd.u
            align: Qt.AlignLeft
            titleSize: 54 * osd.u
            source: osd.item && osd.item.logo ? osd.item.logo : ""
            title: osd.item ? osd.item.title || "" : ""
        }
        Text {
            x: Theme.margin
            y: parent.height - 298 * osd.u
            opacity: chipBox.on || osd.pickerOpen ? 0 : 1
            Behavior on opacity { NumberAnimation { duration: 160 } }
            text: osd.item && osd.item.subtitle ? osd.item.subtitle : ""
            color: Theme.fg
            font { family: Theme.display; pixelSize: 30 * osd.u; weight: Font.DemiBold }
        }

        // seek bar at H-214
        Item {
            id: bar
            x: Theme.margin
            width: parent.width - 2 * Theme.margin
            y: parent.height - 214 * osd.u
            height: 8 * osd.u
            readonly property real frac: osd.dur > 0 ? Math.min(1, osd.pos / osd.dur) : 0
            readonly property bool foc: osd.zone === "bar"
            Rectangle { anchors.fill: parent; radius: height / 2; color: Qt.rgba(1, 1, 1, 0.25) }
            // click or drag along the bar to go there
            MouseArea {
                anchors { fill: parent; topMargin: -24 * osd.u; bottomMargin: -24 * osd.u }
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                function go(x) { if (osd.pickerOpen) win.closePickers(); if (osd.dur > 0) Player.seekTo(Math.max(0, Math.min(1, x / width)) * osd.dur); osd.show(0, "bar") }
                onPressed: function (m) { go(m.x) }
                onPositionChanged: function (m) { if (pressed) go(m.x) }
            }
            // buffered ahead
            Rectangle {
                height: parent.height; radius: height / 2
                width: osd.dur > 0 ? Math.min(1, (osd.pos + Player.cacheAhead) / osd.dur) * parent.width : 0
                color: Qt.rgba(1, 1, 1, 0.22)
            }
            Rectangle {
                height: parent.height; radius: height / 2
                width: bar.frac * parent.width
                color: bar.foc ? Theme.accent : "white"
                // only while it shows: a running animation makes the window draw every vsync
                Behavior on width { enabled: !Player.buffering && osd.chromeShown; NumberAnimation { duration: 250 } }
            }
            // segment marks (intro / recap / credits)
            Repeater {
                model: Player.segments || []
                Rectangle {
                    required property var modelData
                    visible: osd.dur > 0
                    x: modelData.start / osd.dur * bar.width
                    width: Math.max(2, (modelData.end - modelData.start) / osd.dur * bar.width)
                    height: bar.height
                    color: Qt.rgba(1, 1, 1, 0.12)
                }
            }
            Rectangle {
                width: 26 * osd.u; height: width; radius: width / 2
                x: bar.frac * bar.width - width / 2
                anchors.verticalCenter: parent.verticalCenter
                color: "white"
                // only while the bar has focus: the fill says where it is otherwise
                scale: bar.foc ? 1 : 0.2
                opacity: bar.foc ? 1 : 0
                Behavior on scale { NumberAnimation { duration: 160 } }
                Behavior on opacity { NumberAnimation { duration: 160 } }
            }
            // scrub speed / held-seek jump, riding above the thumb
            Item {
                id: chipBox
                readonly property bool on: osd.scrubLevel > 0 || osd.bubble !== ""
                width: chipRow.width + 40 * osd.u
                height: 56 * osd.u
                x: Math.max(-Theme.margin + 24 * osd.u, Math.min(bar.width - width + Theme.margin - 24 * osd.u, bar.frac * bar.width - width / 2))
                y: -height - 26 * osd.u
                opacity: on ? 1 : 0
                visible: opacity > 0
                Behavior on opacity { NumberAnimation { duration: 160 } }
                Glass { anchors.fill: parent; kind: "chip"; radius: height / 2 }
                Row {
                    id: chipRow
                    anchors.centerIn: parent
                    spacing: 10 * osd.u
                    Symbol {
                        visible: osd.scrubLevel > 0
                        anchors.verticalCenter: parent.verticalCenter
                        width: 26 * osd.u; height: width
                        name: osd.scrubDir > 0 ? "forward" : "rewind"
                        weight: 1
                        color: Theme.fg
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: osd.scrubLevel > 0 ? "×" + osd.scrubRate + "   " + Theme.time(osd.scrubT) : osd.bubble
                        color: Theme.fg
                        font { family: Theme.text; pixelSize: 24 * osd.u; weight: Font.DemiBold; features: { "tnum": 1 } }
                    }
                }
            }
        }
        Text {
            x: Theme.margin
            y: parent.height - 170 * osd.u
            opacity: osd.pickerOpen ? 0 : 1
            Behavior on opacity { NumberAnimation { duration: 160 } }
            text: Theme.time(osd.pos)
            color: Theme.fg2
            font { family: Theme.text; pixelSize: 25 * osd.u; weight: Font.Medium; features: { "tnum": 1 } }
        }
        Text {
            anchors { right: parent.right; rightMargin: Theme.margin }
            y: parent.height - 170 * osd.u
            text: "-" + Theme.time(osd.dur - osd.pos)
            color: Theme.fg2
            font { family: Theme.text; pixelSize: 25 * osd.u; weight: Font.Medium; features: { "tnum": 1 } }
        }

        // the row at H-86: glass at rest, white when focused
        Row {
            x: Theme.margin
            y: parent.height - 86 * osd.u - height / 2
            spacing: 18 * osd.u
            RowButton { id: subsBtn; key: "subs"; icon: "subtitles"; text: osd.subLabel }
            RowButton { id: audioBtn; key: "audio"; icon: "audio"; text: osd.audioLabel }
            RowButton { id: matchBtn; key: "match"; icon: "feedback" }
        }
        // transport in one glass capsule
        Item {
            id: transport
            anchors.horizontalCenter: parent.horizontalCenter
            y: parent.height - 86 * osd.u - height / 2
            // 14 round the 76 circles and 10 round play: the end circles sit concentric in the capsule
            width: tRow.width + 28 * osd.u
            height: 104 * osd.u
            Glass { anchors.fill: parent; kind: "chip"; radius: height / 2 }
            Row {
                id: tRow
                anchors.centerIn: parent
                spacing: 10 * osd.u
                Repeater {
                    model: ["rew", "play", "fwd"]
                    Item {
                        required property var modelData
                        readonly property bool foc: osd.zone === "row" && osd.buttons[osd.rowIndex] === modelData
                        width: (modelData === "play" ? 84 : 76) * osd.u
                        height: width
                        anchors.verticalCenter: parent.verticalCenter
                        Rectangle {
                            anchors.fill: parent
                            radius: width / 2
                            color: parent.foc ? "white" : "transparent"
                            scale: parent.foc ? 1.1 : 1
                            Behavior on scale { SpringAnimation { spring: Theme.springK; damping: Theme.springDamp; epsilon: 0.0005 } }
                            Behavior on color { ColorAnimation { duration: 140 } }
                        }
                        Symbol {
                            anchors.centerIn: parent
                            width: (modelData === "play" ? 46 : 38) * osd.u; height: width
                            weight: 2.2
                            color: parent.foc ? Theme.focusFg : Theme.fg
                            name: modelData === "play" ? (Player.paused ? "play" : "pause") : modelData === "rew" ? "back10" : "fwd10"
                        }
                        Pointer {
                            okKey: false
                            onPointed: { osd.zone = "row"; osd.rowIndex = osd.buttons.indexOf(modelData); osd.show() }
                            onTapped: osd.act(modelData)
                        }
                    }
                }
            }
        }
        Row {
            anchors { right: parent.right; rightMargin: Theme.margin }
            y: parent.height - 86 * osd.u - height / 2
            spacing: 18 * osd.u
            RowButton { key: "next"; icon: "next"; text: qsTr("Next Episode"); visible: osd.nextButton }
            RowButton { key: "hz"; icon: Player.refreshMatch ? "check" : "tv"; text: qsTr("Match Hz"); visible: !Theme.android }
            RowButton { key: "exit"; icon: "xmark" }
        }
    }

    // ---- skip pill / next episode (shown without the controls too)
    Item {
        id: pill
        readonly property bool next: osd.nextUp
        readonly property bool foc: osd.zone === "skip" || !osd.shown
        anchors { right: parent.right; rightMargin: Theme.margin }
        y: parent.height - (osd.shown ? 300 : 150) * osd.u - height
        Behavior on y { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }
        width: next ? 340 * osd.u : pillText.implicitWidth + 80 * osd.u
        height: next ? (340 - 24) * osd.u * 9 / 16 + 88 * osd.u : 84 * osd.u
        opacity: osd.pillShown ? 1 : 0
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: 300 } }

        RectangularShadow {
            anchors.fill: pillBg
            radius: pillBg.radius
            offset.y: 16 * osd.u
            blur: 44 * osd.u
            color: Qt.rgba(0, 0, 0, 0.55)
            opacity: pill.foc ? 1 : 0.5
        }
        Glass {
            anchors.fill: parent
            kind: pill.next ? "panel" : "chip"
            radius: pillBg.radius
            opacity: pill.foc ? 0 : 1
            Behavior on opacity { NumberAnimation { duration: 140 } }
        }
        Rectangle {
            id: pillBg
            anchors.fill: parent
            radius: pill.next ? 30 * osd.u : height / 2
            color: pill.foc ? "white" : "transparent"
            Behavior on color { ColorAnimation { duration: 140 } }
        }
        Art {
            visible: pill.next
            x: 12 * osd.u; y: 12 * osd.u
            width: parent.width - 24 * osd.u
            height: width * 9 / 16
            radius: 18 * osd.u
            source: Player.next && Player.next.still ? Player.next.still : ""
        }
        Column {
            visible: pill.next
            anchors { left: parent.left; right: parent.right; bottom: parent.bottom; margins: 20 * osd.u; bottomMargin: 18 * osd.u }
            Text {
                text: qsTr("Next Episode")
                color: pill.foc ? Qt.rgba(0.1, 0.1, 0.12, 0.6) : Theme.fg2
                font { family: Theme.text; pixelSize: 16 * osd.u; weight: Font.DemiBold }
            }
            Text {
                width: parent.width
                elide: Text.ElideRight
                text: Player.next ? "S" + Player.next.season + " · E" + Player.next.episode + (Player.next.title ? "  " + Player.next.title : "") : ""
                color: pill.foc ? Theme.focusFg : Theme.fg
                font { family: Theme.display; pixelSize: 21 * osd.u; weight: Font.DemiBold }
            }
        }
        Text {
            id: pillText
            visible: !pill.next
            anchors.centerIn: parent
            text: !osd.segment ? "" : osd.segment.kind === "intro" ? qsTr("Skip Intro")
                : osd.segment.kind === "recap" ? qsTr("Skip Recap") : qsTr("Skip Credits")
            color: pill.foc ? Theme.focusFg : Theme.fg
            font { family: Theme.display; pixelSize: 29 * osd.u; weight: Font.DemiBold }
        }
    }

    // buffering
    Spinner {
        anchors.centerIn: parent
        width: 72 * osd.u; height: width
        visible: Player.buffering
    }
}
