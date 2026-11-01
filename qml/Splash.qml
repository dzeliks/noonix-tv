import QtQuick

// launch splash: the pink blooms out of the black window while the lockup (the overlay's launch
// card: same gradient, same lockup in the same place) slides up into place. with
// NOONIX_SPLASH_FAST=1 it starts on that card at once, so a card shown before can dissolve over
// it unseen. then the kitty glides to the middle while the
// name slides in behind it, its antennas sway from the move, it smiles, leans in and shrinks
// away to the middle as the pink fades off the ui. everything runs on animators (render
// thread): the ui is busy building itself underneath meanwhile.
FocusScope {
    id: splash
    property Item ui: null              // eases into place as the pink goes
    property bool revealed: false       // the launch card is gone (or there was none)
    property bool ready: false          // what's underneath has its content
    property string phase: "waiting"    // waiting, playing, done
    readonly property bool intro: Desktop.splashFast !== true
    property bool introDone: !intro
    property bool skipped: false        // a key during the intro: the quick way out after it
    signal starting()                   // put the right page under it now
    signal finished()

    // the card's lockup (the overlay tools/make_tiles.py): an 800x480 art box at 62.5 % of the
    // width, centred; icon 168 at x 91, name 88 px bold at x 289 on a baseline of 270.8
    readonly property real k: width * 0.625 / 800
    readonly property real bx: (width - 800 * k) / 2
    readonly property real by: (height - 480 * k) / 2
    readonly property real iconSize: 168 * k
    readonly property real iconX: bx + 91 * k
    readonly property real shift: width / 2 - (bx + 175 * k)   // the icon's way to the middle
    readonly property real slow: Desktop.splashSlow   // dev: NOONIX_SPLASH_SLOW=4 for recordings
    readonly property real res: Math.max(0.25, iconSize * 1.25 / 1024)   // svg px per icon unit

    function play() {
        if (phase !== "waiting" || !introDone) return
        phase = "playing"
        Desktop.mark("splash play")
        starting()
        if (skipped) { out.start(); return }
        show.start()
        antL.swing.start()
        antR.swing.start()
    }
    onRevealedChanged: {
        if (revealed && intro && !introDone && !introAnim.running) introAnim.start()
        if (revealed && ready) play()
    }
    onReadyChanged: if (revealed && ready) play()
    onIntroDoneChanged: if (revealed && ready) play()
    // any key: straight to the way out
    function skip() {
        if (phase === "waiting" && introAnim.running) skipped = true
        if (phase !== "playing" || out.running) return
        show.stop()
        out.start()
    }
    function finish() {
        if (phase === "done") return
        phase = "done"
        visible = false
        if (ui) ui.scale = 1
        finished()
    }
    Keys.onPressed: function (e) { e.accepted = true; skip() }

    component Part: Image {
        required property string file
        required property rect box      // icon units (the svg's viewBox)
        x: box.x; y: box.y; width: box.width; height: box.height
        source: "assets/kitty/" + file + ".svg"
        sourceSize: Qt.size(Math.ceil(box.width * splash.res), Math.ceil(box.height * splash.res))
        smooth: true
        mipmap: true
    }
    // one antenna: sways about the knob (the box's bottom centre), dragged by the glide and
    // springing back; amp -1 mirrors it, so the pair opens and closes like a v
    component Antenna: Part {
        id: ant
        property real amp: 1
        property int lag: 0
        box: Qt.rect(312, 100, 400, 312)
        transformOrigin: Item.Bottom
        readonly property var swing: SequentialAnimation {
            PauseAnimation { duration: ant.lag * splash.slow }
            RotationAnimator { target: ant; from: 0; to: -7 * ant.amp; duration: 310 * splash.slow; easing.type: Easing.OutSine }
            RotationAnimator { target: ant; from: -7 * ant.amp; to: 9 * ant.amp; duration: 430 * splash.slow; easing.type: Easing.InOutSine }
            RotationAnimator { target: ant; from: 9 * ant.amp; to: -5 * ant.amp; duration: 320 * splash.slow; easing.type: Easing.InOutSine }
            RotationAnimator { target: ant; from: -5 * ant.amp; to: 2.5 * ant.amp; duration: 280 * splash.slow; easing.type: Easing.InOutSine }
            RotationAnimator { target: ant; from: 2.5 * ant.amp; to: -1 * ant.amp; duration: 260 * splash.slow; easing.type: Easing.InOutSine }
            RotationAnimator { target: ant; from: -1 * ant.amp; to: 0; duration: 240 * splash.slow; easing.type: Easing.OutSine }
        }
    }

    readonly property var brand: ({ c1: "#D93D8A", c2: "#4A0E2F", glow: Qt.vector4d(1.0, 0.761, 0.882, 0.14) })   // the overlay brands.js "noonix-tv"

    // what the pink blooms out of (and the ui shows through once it's gone)
    Shield {}
    Rectangle {
        id: dark
        anchors.fill: parent
        color: "black"
        opacity: splash.intro ? 1 : 0
    }

    ShaderEffect {
        id: bg
        anchors.fill: parent
        opacity: splash.intro ? 0 : 1
        property color c1: splash.brand.c1
        property color c2: splash.brand.c2
        property vector4d glow: splash.brand.glow
        property real part: 0
        fragmentShader: "qrc:/shaders/splash.frag.qsb"
    }

    // the name, clipped at the icon's centre: it slides in behind the icon, all of it, and
    // never comes out the other side
    Item {
        id: nameClip
        x: splash.bx + 175 * splash.k
        opacity: splash.intro ? 0 : 1
        width: splash.width - x
        height: splash.height
        clip: true
        Text {
            id: name
            x: 114 * splash.k
            y: splash.by + 270.8 * splash.k - baselineOffset
            text: "Noonix TV"
            color: "white"
            renderType: Text.CurveRendering
            font { family: Theme.display; weight: Font.Bold; pixelSize: 88 * splash.k; letterSpacing: -2 * splash.k }
        }
    }

    Item {
        id: logo
        x: splash.iconX
        y: splash.by + 156 * splash.k
        opacity: splash.intro ? 0 : 1
        width: splash.iconSize; height: width
        Item {
            id: zoom
            anchors.fill: parent
            Item {
                width: 1024; height: 1024
                scale: logo.width / 1024
                transformOrigin: Item.TopLeft
                Part { file: "plate"; box: Qt.rect(0, 0, 1024, 1024) }
                Antenna { id: antL; file: "antenna-left" }
                // mirrored, same beat: they spread apart, swing back together and settle
                Antenna { id: antR; file: "antenna-right"; amp: -1 }
                Part { file: "head"; box: Qt.rect(232, 300, 560, 544) }
                // each eye closes into itself, then opens again as a happy arc in the same spot
                Part { id: eyeL; file: "eye-left"; box: Qt.rect(376, 544, 88, 112) }
                Part { id: eyeR; file: "eye-right"; box: Qt.rect(560, 544, 88, 112) }
                Part { id: happyL; file: "eye-happy-left"; box: Qt.rect(376, 544, 88, 112); opacity: 0 }
                Part { id: happyR; file: "eye-happy-right"; box: Qt.rect(560, 544, 88, 112); opacity: 0 }
                Part { file: "features"; box: Qt.rect(280, 640, 464, 96) }
                Part { id: mouth; file: "mouth"; box: Qt.rect(456, 688, 112, 48) }
                Part { id: smile; file: "smile"; box: Qt.rect(432, 680, 160, 112); opacity: 0; transformOrigin: Item.Top }
                Part { id: blush; file: "blush"; box: Qt.rect(334, 662, 356, 56); opacity: 0.5625 }   // 0.45 of the svg's 0.8
            }
        }
    }

    ShaderEffect {
        id: light
        anchors.fill: parent
        opacity: splash.intro ? 0 : 1
        property color c1: splash.brand.c1
        property color c2: splash.brand.c2
        property vector4d glow: splash.brand.glow
        property real part: 1
        fragmentShader: "qrc:/shaders/splash.frag.qsb"
    }

    readonly property var glide: [0.5, 0.0, 0.1, 1.0, 1, 1]
    readonly property var rise: [0.16, 1.0, 0.3, 1.0, 1, 1]
    readonly property real riseBy: 70 * k

    // the intro: the pink fades in over the black while the lockup rises into its place, a breath
    SequentialAnimation {
        id: introAnim
        ParallelAnimation {
            OpacityAnimator { target: bg; from: 0; to: 1; duration: 700 * splash.slow; easing.type: Easing.InOutSine }
            OpacityAnimator { target: light; from: 0; to: 1; duration: 700 * splash.slow; easing.type: Easing.InOutSine }
            YAnimator { target: logo; from: splash.by + 156 * splash.k + splash.riseBy; to: splash.by + 156 * splash.k; duration: 900 * splash.slow; easing.type: Easing.BezierSpline; easing.bezierCurve: splash.rise }
            YAnimator { target: nameClip; from: splash.riseBy; to: 0; duration: 900 * splash.slow; easing.type: Easing.BezierSpline; easing.bezierCurve: splash.rise }
            OpacityAnimator { target: logo; from: 0; to: 1; duration: 550 * splash.slow; easing.type: Easing.OutSine }
            OpacityAnimator { target: nameClip; from: 0; to: 1; duration: 550 * splash.slow; easing.type: Easing.OutSine }
        }
        PauseAnimation { duration: 200 * splash.slow }
        onFinished: splash.introDone = true
    }

    ParallelAnimation {
        id: show
        // the icon to the middle; the name goes the other way, all of it in behind the icon
        XAnimator { target: logo; from: splash.iconX; to: splash.iconX + splash.shift; duration: 1000 * splash.slow; easing.type: Easing.BezierSpline; easing.bezierCurve: splash.glide }
        XAnimator { target: nameClip; from: splash.bx + 175 * splash.k; to: splash.bx + 175 * splash.k + splash.shift; duration: 1000 * splash.slow; easing.type: Easing.BezierSpline; easing.bezierCurve: splash.glide }
        XAnimator { target: name; from: 114 * splash.k; to: -name.width - 4 * splash.k; duration: 1000 * splash.slow; easing.type: Easing.BezierSpline; easing.bezierCurve: splash.glide }
        // the smile: eyes close into themselves and open as happy arcs, the mouth grows open
        // from under the nose as the old one goes, cheeks warm up. staggered, never two faces at once
        SequentialAnimation {
            PauseAnimation { duration: 1160 * splash.slow }
            ParallelAnimation {
                ScaleAnimator { target: eyeL; from: 1; to: 0.25; duration: 150 * splash.slow; easing.type: Easing.InQuad }
                ScaleAnimator { target: eyeR; from: 1; to: 0.25; duration: 150 * splash.slow; easing.type: Easing.InQuad }
                OpacityAnimator { target: eyeL; from: 1; to: 0; duration: 150 * splash.slow; easing.type: Easing.InQuad }
                OpacityAnimator { target: eyeR; from: 1; to: 0; duration: 150 * splash.slow; easing.type: Easing.InQuad }
                OpacityAnimator { target: mouth; from: 1; to: 0; duration: 120 * splash.slow; easing.type: Easing.InQuad }
                SequentialAnimation {
                    PauseAnimation { duration: 70 * splash.slow }
                    ParallelAnimation {
                        OpacityAnimator { target: smile; from: 0; to: 1; duration: 140 * splash.slow }
                        ScaleAnimator { target: smile; from: 0.45; to: 1; duration: 420 * splash.slow; easing.type: Easing.OutCubic }
                    }
                }
                SequentialAnimation {
                    PauseAnimation { duration: 130 * splash.slow }
                    ParallelAnimation {
                        OpacityAnimator { target: happyL; from: 0; to: 1; duration: 120 * splash.slow }
                        OpacityAnimator { target: happyR; from: 0; to: 1; duration: 120 * splash.slow }
                        ScaleAnimator { target: happyL; from: 0.4; to: 1; duration: 360 * splash.slow; easing.type: Easing.OutCubic }
                        ScaleAnimator { target: happyR; from: 0.4; to: 1; duration: 360 * splash.slow; easing.type: Easing.OutCubic }
                    }
                }
                OpacityAnimator { target: blush; from: 0.5625; to: 1; duration: 520 * splash.slow; easing.type: Easing.InOutSine }
            }
        }
        // lean in, then all the way out to the middle as the pink lifts off the ui
        SequentialAnimation {
            PauseAnimation { duration: 1920 * splash.slow }
            ScaleAnimator { target: zoom; from: 1; to: 1.08; duration: 380 * splash.slow; easing.type: Easing.InOutSine }
            ScaleAnimator { target: zoom; from: 1.08; to: 0; duration: 640 * splash.slow; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.6, 0.0, 0.4, 1.0, 1, 1] }
        }
        SequentialAnimation {
            PauseAnimation { duration: 2440 * splash.slow }
            ParallelAnimation {
                OpacityAnimator { target: bg; from: 1; to: 0; duration: 520 * splash.slow; easing.type: Easing.InOutSine }
                OpacityAnimator { target: light; from: 1; to: 0; duration: 520 * splash.slow; easing.type: Easing.InOutSine }
                OpacityAnimator { target: dark; to: 0; duration: 520 * splash.slow; easing.type: Easing.InOutSine }
                ScaleAnimator { target: splash.ui; from: 1.05; to: 1; duration: 720 * splash.slow; easing.type: Easing.OutCubic }
            }
        }
        onFinished: splash.finish()
    }

    // skipped: the same way out, quick
    ParallelAnimation {
        id: out
        ScaleAnimator { target: zoom; to: 0; duration: 300; easing.type: Easing.InCubic }
        OpacityAnimator { target: name; to: 0; duration: 150 }
        OpacityAnimator { target: bg; to: 0; duration: 300; easing.type: Easing.InOutSine }
        OpacityAnimator { target: light; to: 0; duration: 300; easing.type: Easing.InOutSine }
        OpacityAnimator { target: dark; to: 0; duration: 300; easing.type: Easing.InOutSine }
        ScaleAnimator { target: splash.ui; to: 1; duration: 300; easing.type: Easing.OutCubic }
        onFinished: splash.finish()
    }
}
