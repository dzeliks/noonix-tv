import QtQuick

// pick one of a few: a line that used to step through its values opens this instead
FocusScope {
    id: ch
    readonly property real u: Theme.u
    property string title: ""
    property string detail: ""
    property var options: []             // { id, label, detail }
    property string current: ""
    property var pick: null              // function (id)
    signal closed()
    visible: opacity > 0
    opacity: 0
    Behavior on opacity { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

    function open(o) {
        title = o.title || ""; detail = o.detail || ""; options = o.options || []; current = o.current || ""; pick = o.pick || null
        list.currentIndex = Math.max(0, options.findIndex(function (x) { return x.id === ch.current }))
        opacity = 1
        list.forceActiveFocus()
    }
    function close() { opacity = 0; closed() }
    function choose() {
        var o = options[list.currentIndex], f = pick
        if (!o) return
        close()
        if (f) f(o.id)
    }

    Glass { anchors.fill: parent; kind: "panel"; radius: 0; refraction: 0; dim: Theme.veil }
    Shield { onOutside: ch.close() }

    Item {
        anchors.centerIn: parent
        width: 800 * ch.u
        height: body.height + 2 * 44 * ch.u
        scale: ch.opacity > 0.5 ? 1 : 0.96
        Behavior on scale { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
        Glass { anchors.fill: parent; kind: "panel"; radius: 52 * ch.u }
        Column {
            id: body
            x: 28 * ch.u; y: 44 * ch.u
            width: parent.width - 56 * ch.u
            spacing: 10 * ch.u
            Text {
                x: 30 * ch.u
                width: parent.width - 60 * ch.u
                text: ch.title
                color: Theme.fg
                wrapMode: Text.WordWrap
                font { family: Theme.display; pixelSize: 36 * ch.u; weight: Font.Bold }
            }
            Text {
                visible: text !== ""
                x: 30 * ch.u
                width: parent.width - 60 * ch.u
                bottomPadding: 12 * ch.u
                text: ch.detail
                color: Theme.fg2
                wrapMode: Text.WordWrap
                font { family: Theme.text; pixelSize: 23 * ch.u }
            }
            ListView {
                id: list
                width: parent.width
                height: contentHeight
                interactive: false
                model: ch.options
                keyNavigationEnabled: true
                delegate: Toggle {
                    required property var modelData
                    required property int index
                    width: list.width
                    label: modelData.label
                    detail: modelData.detail || ""
                    checkable: false
                    value: modelData.id === ch.current ? "✓" : ""
                    focused: ListView.isCurrentItem && list.activeFocus
                    grow: 1
                }
                Keys.onReturnPressed: ch.choose()
                Keys.onEnterPressed: ch.choose()
                Keys.onEscapePressed: ch.close()
                Keys.onBackPressed: ch.close()
            }
        }
    }
}
