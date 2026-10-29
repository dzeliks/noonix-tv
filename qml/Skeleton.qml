import QtQuick

// a card's placeholder while its row or grid loads
Column {
    id: sk
    property string style: "poster"
    property real cardW: 214 * Theme.u
    readonly property real u: Theme.u
    spacing: 16 * u
    Rectangle {
        width: sk.cardW
        height: sk.style === "poster" ? sk.cardW * 1.5 : sk.cardW * 9 / 16
        radius: 18 * sk.u
        color: Theme.skeleton
    }
    Rectangle { visible: sk.style !== "poster"; width: sk.cardW * 0.6; height: 20 * sk.u; radius: height / 2; color: Theme.skeleton }
    Rectangle { visible: sk.style !== "poster"; width: sk.cardW * 0.4; height: 16 * sk.u; radius: height / 2; color: Theme.skeleton }
}
