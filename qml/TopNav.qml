import QtQuick

// glass tab pill (tvos 26) with the profile on the left and the clock on the right
FocusScope {
    id: nav
    property string page: "home"
    property var profile: null
    readonly property real u: Theme.u
    readonly property var tabs: [
        { id: "search", icon: "search", label: "" },
        { id: "home", label: qsTr("Home") },
        { id: "movies", label: qsTr("Movies") },
        { id: "shows", label: qsTr("Shows") },
        { id: "library", label: qsTr("Library") },
        { id: "settings", icon: "gear", label: "" }
    ]
    property int index: 1
    signal chosen(string page)
    signal profileRequested()
    height: 150 * u

    function sync() { for (var i = 0; i < tabs.length; ++i) if (tabs[i].id === page) index = i }
    onPageChanged: sync()
    Component.onCompleted: sync()

    // left of the tabs is the avatar (-1): ok there asks who's watching
    readonly property bool onAvatar: index < 0 && activeFocus
    Keys.onLeftPressed: if (index > 0) { index--; chosen(tabs[index].id) } else if (profile) index = -1
    Keys.onRightPressed: if (index < tabs.length - 1) { index++; chosen(tabs[index].id) }
    // ok on a tab goes into its page, like down
    signal entered()
    Keys.onReturnPressed: if (index < 0) profileRequested(); else entered()
    Keys.onEnterPressed: if (index < 0) profileRequested(); else entered()
    onActiveFocusChanged: if (!activeFocus && index < 0) sync()

    // avatar: the profile's colour, like the pads
    Avatar {
        id: avatar
        x: Theme.margin
        anchors.verticalCenter: pill.verticalCenter
        visible: !!nav.profile
        size: 64 * nav.u
        colour: nav.profile ? nav.profile.color || "green" : "green"
        image: nav.profile ? nav.profile.avatar || "" : ""
        letter: nav.profile ? nav.profile.name.charAt(0).toUpperCase() : ""
        scale: nav.onAvatar ? 1.16 : avatarPt.hovered ? 1.08 : 1
        Behavior on scale { SpringAnimation { spring: Theme.springK; damping: Theme.springDamp; epsilon: 0.0005 } }
        Rectangle {
            anchors { fill: parent; margins: -7 * nav.u }
            radius: width / 2
            color: "transparent"
            border.width: 4 * nav.u
            border.color: "white"
            opacity: nav.onAvatar ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 140 } }
        }
        // the mouse only points at it; a click opens the profiles
        Pointer {
            id: avatarPt
            readonly property bool hovered: containsMouse && Input.pointing === true
            okKey: false
            onTapped: nav.profileRequested()
        }
    }

    Glass {
        id: pill
        kind: "panel"
        anchors.horizontalCenter: parent.horizontalCenter
        y: 44 * nav.u
        // the capsule sits 7 in on every side: the end ones follow the pill's own curve
        width: tabRow.width + 2 * tabRow.x
        height: 78 * nav.u
        radius: height / 2
        opacity: nav.activeFocus ? 1 : 0.86
        Behavior on opacity { NumberAnimation { duration: 200 } }

        // the focus capsule glides between tabs
        Rectangle {
            id: capsule
            // rep.built: itemAt() isn't a binding source, re-read once the tabs exist
            readonly property Item target: (tabRow.rep.built, tabRow.rep.itemAt(Math.max(0, nav.index)))
            // glides only between tabs, never in from the edge at start
            property bool placed: false
            onTargetChanged: if (target && !placed) Qt.callLater(function () { capsule.placed = true })
            x: target ? tabRow.x + target.x : 0
            y: (pill.height - height) / 2
            width: target ? target.width : 0
            height: pill.height - 14 * nav.u
            radius: height / 2
            opacity: nav.index < 0 ? 0 : 1
            Behavior on opacity { NumberAnimation { duration: 140 } }
            color: nav.activeFocus ? "white" : Qt.rgba(1, 1, 1, 0.16)
            // a small bounce as it lands on the tab (~6 % past it)
            Behavior on x { enabled: capsule.placed; SpringAnimation { spring: 4.2; damping: 0.32; epsilon: 0.25 } }
            Behavior on width { enabled: capsule.placed; SpringAnimation { spring: 4.2; damping: 0.32; epsilon: 0.25 } }
            Behavior on color { ColorAnimation { duration: 160 } }
        }
        Tabs { id: tabRow; x: 7 * nav.u }
        // a black copy of the tabs seen only through the capsule, so letters ink as it passes
        Item {
            x: capsule.x; y: capsule.y
            width: capsule.width; height: capsule.height
            clip: true
            opacity: nav.activeFocus && nav.index >= 0 ? 1 : 0
            visible: opacity > 0
            Behavior on opacity { NumberAnimation { duration: 160 } }
            Tabs { x: tabRow.x - parent.x; y: -parent.y; ink: true }
        }
    }

    component Tabs: Row {
        property bool ink: false
        height: pill.height
        Repeater {
            id: rep
            property int built: 0
            onItemAdded: built++
            model: nav.tabs
            Item {
                required property var modelData
                required property int index
                readonly property bool on: nav.index === index
                readonly property bool hovered: !ink && tabPt.containsMouse && Input.pointing === true
                readonly property color tint: ink ? Theme.focusFg : on || hovered ? Theme.fg : Theme.fg2
                // the mouse lights a tab up; only a click switches to it
                Rectangle {
                    anchors.centerIn: parent
                    width: parent.width; height: 64 * nav.u
                    radius: height / 2
                    color: "white"
                    opacity: parent.hovered && !parent.on ? 0.1 : 0
                    Behavior on opacity { NumberAnimation { duration: 140 } }
                }
                Pointer {
                    id: tabPt
                    enabled: !ink
                    okKey: false
                    onTapped: {
                        nav.forceActiveFocus()
                        if (nav.index !== index) { nav.index = index; nav.chosen(nav.tabs[index].id) }
                    }
                }
                height: parent.height
                width: modelData.icon ? 76 * nav.u : label.implicitWidth + 56 * nav.u
                Text {
                    id: label
                    anchors.centerIn: parent
                    visible: !modelData.icon
                    text: modelData.label
                    color: parent.tint
                    font { family: Theme.display; pixelSize: 28 * nav.u; weight: parent.on ? Font.DemiBold : Font.Medium }
                }
                Symbol {
                    anchors.centerIn: parent
                    visible: !!modelData.icon
                    width: 34 * nav.u; height: width
                    name: modelData.icon || ""
                    weight: 2.2
                    color: parent.tint
                }
            }
        }
        readonly property alias rep: rep
    }

    Text {
        anchors { right: parent.right; rightMargin: Theme.margin; verticalCenter: pill.verticalCenter }
        text: Clock.hhmm
        color: Theme.fg
        font { family: Theme.rounded; pixelSize: 40 * nav.u; weight: Font.Bold }
    }
}
