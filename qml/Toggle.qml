import QtQuick

// a settings line: label, detail, on/off switch or a value on the right
Item {
    id: t
    property string label: ""
    property string detail: ""
    property string value: ""
    property bool checkable: true
    property bool checked: false
    property string badge: ""            // a rank number for ordered choices
    property url icon: ""                // a wide logo before the label (credits)
    property bool focused: false
    property bool wrapLabel: false
    property real radius: 24 * u
    property real grow: 1.02             // focus lift; 1 inside tight popovers
    readonly property real u: Theme.u
    signal toggled()
    height: Math.max((detail ? 108 : 84) * u, texts.implicitHeight + 40 * u)
    // a long detail opens up while the row has the focus. never on the way in: a new row only
    // gets its width after it exists, and would grow into place
    property bool settled: false
    Component.onCompleted: Qt.callLater(function () { t.settled = true })
    Behavior on height { enabled: t.settled; NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }

    Rectangle {
        anchors.fill: parent
        radius: t.radius
        color: t.focused ? "white" : "transparent"
        scale: t.focused ? t.grow : 1
        Behavior on scale { SpringAnimation { spring: Theme.springK; damping: Theme.springDamp; epsilon: 0.0005 } }
    }
    Image {
        id: ic
        visible: t.icon != ""
        source: t.icon
        anchors { left: parent.left; leftMargin: 30 * t.u; verticalCenter: parent.verticalCenter }
        height: 30 * t.u
        width: visible ? Math.round(height * (implicitWidth > 0 && implicitHeight > 0 ? implicitWidth / implicitHeight : 1)) : 0
        sourceSize.height: Math.round(height)
        fillMode: Image.PreserveAspectFit
        smooth: true
    }
    Column {
        id: texts
        anchors { left: ic.visible ? ic.right : parent.left; leftMargin: (ic.visible ? 26 : 30) * t.u; right: side.left; rightMargin: 20 * t.u; verticalCenter: parent.verticalCenter }
        spacing: 4 * t.u
        Text {
            width: parent.width
            text: t.label
            wrapMode: t.wrapLabel ? Text.WordWrap : Text.NoWrap
            elide: t.wrapLabel ? Text.ElideNone : Text.ElideRight
            color: t.focused ? Theme.focusFg : Theme.fg
            font { family: Theme.text; pixelSize: 26 * t.u; weight: Font.Medium }
        }
        Text {
            visible: t.detail !== ""
            width: parent.width
            text: t.detail
            // release names have no spaces: break them anywhere rather than run under the value
            wrapMode: Text.WrapAtWordBoundaryOrAnywhere
            maximumLineCount: t.focused ? 8 : 2
            elide: Text.ElideRight
            color: t.focused ? Qt.rgba(0.1, 0.1, 0.12, 0.6) : Theme.fg3
            font { family: Theme.text; pixelSize: 20 * t.u }
        }
    }
    Item {
        id: side
        anchors { right: parent.right; rightMargin: 30 * t.u; verticalCenter: parent.verticalCenter }
        // a short value keeps some room: copy turning into copied can't push the detail onto a new line
        width: Math.max(sw.visible ? sw.width : 0, val.visible ? Math.max(val.implicitWidth, 100 * t.u) : 0, rank.visible ? rank.width : 0)
        height: parent.height
        Text {
            id: val
            visible: !t.checkable && t.value !== ""
            anchors { right: parent.right; verticalCenter: parent.verticalCenter }
            text: t.value
            color: t.focused ? Theme.focusFg : Theme.fg2
            font { family: Theme.text; pixelSize: 24 * t.u }
        }
        Rectangle {
            id: rank
            visible: t.badge !== ""
            anchors { right: sw.visible ? sw.left : parent.right; rightMargin: sw.visible ? 18 * t.u : 0; verticalCenter: parent.verticalCenter }
            width: 40 * t.u; height: width; radius: width / 2
            color: Theme.accent
            Text { anchors.centerIn: parent; text: t.badge; color: "white"; font { family: Theme.rounded; pixelSize: 22 * t.u; weight: Font.Bold } }
        }
        Rectangle {
            id: sw
            visible: t.checkable
            anchors { right: parent.right; verticalCenter: parent.verticalCenter }
            width: 84 * t.u; height: 48 * t.u; radius: height / 2
            color: t.checked ? "#30D158" : (t.focused ? Qt.rgba(0, 0, 0, 0.18) : Qt.rgba(1, 1, 1, 0.2))
            Behavior on color { ColorAnimation { duration: 160 } }
            Rectangle {
                width: parent.height - 8 * t.u; height: width; radius: width / 2
                y: 4 * t.u
                x: t.checked ? parent.width - width - 4 * t.u : 4 * t.u
                color: "white"
                Behavior on x { SpringAnimation { spring: 5; damping: 0.66; epsilon: 0.25 } }
            }
        }
    }

    Pointer {}
}
