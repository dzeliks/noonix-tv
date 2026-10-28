import QtQuick
import QtQuick.Effects

// a profile's circle: its colour with a little depth and the initial on it, or its own picture
// (a png from the avatars folder; gone from disk -> the colour again)
Rectangle {
    id: av
    property real size: 200 * Theme.u
    property string colour: "green"
    property string letter: ""
    property string image: ""
    readonly property bool pictured: image !== "" && pic.status === Image.Ready
    readonly property color base: ({ green: "#30D158", pink: "#FF5FA2", blue: "#3D8BFF", orange: "#FF9F0A", purple: "#A56BFF" })[colour] || "#30D158"
    width: size; height: size; radius: size / 2
    gradient: Gradient {
        GradientStop { position: 0.0; color: Qt.lighter(av.base, 1.18) }
        GradientStop { position: 1.0; color: Qt.darker(av.base, 1.22) }
    }
    Text {
        anchors.centerIn: parent
        visible: !av.pictured
        text: av.letter
        color: "white"
        font { family: Theme.rounded; pixelSize: av.size * 0.45; weight: Font.Bold }
    }
    Image {
        id: pic
        anchors.fill: parent
        visible: false
        source: av.image ? (av.image.indexOf("/") === 0 ? "file://" + av.image : av.image) : ""
        sourceSize: Qt.size(Math.ceil(av.size * 1.2), Math.ceil(av.size * 1.2))
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: false
    }
    Rectangle {
        id: round
        anchors.fill: parent
        radius: width / 2
        visible: false
        layer.enabled: true
    }
    MultiEffect {
        anchors.fill: parent
        visible: av.pictured
        source: pic
        maskEnabled: true
        maskSource: round
        maskThresholdMin: 0.5
        maskSpreadAtMin: 1.0
    }
}
