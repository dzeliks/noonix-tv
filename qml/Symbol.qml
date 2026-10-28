// line icons like sf symbols: 24x24 round-capped strokes, `name` picks one
import QtQuick
import QtQuick.Shapes

Item {
    id: sym
    property string name: ""
    property color color: "white"
    property real weight: 2.0          // stroke width in the 24-unit grid
    implicitWidth: 48; implicitHeight: 48

    readonly property var paths: ({
        "xmark": "M6.5 6.5 L17.5 17.5 M17.5 6.5 L6.5 17.5",
        "warning": "M12 4 L21 19.5 H3 Z M12 10 V13.8 M12 16.8 V16.9",
        "tv": "M3.5 5.5 H20.5 V16.5 H3.5 Z M8.5 20 H15.5",
        "bluetooth": "M7 7.5 L17 16.5 L12 21 V3 L17 7.5 L7 16.5",
        "closeall": "M8.5 4.5 H17.5 A2 2 0 0 1 19.5 6.5 V15.5 M4.5 10.5 A2 2 0 0 1 6.5 8.5 H13.5 A2 2 0 0 1 15.5 10.5 V17.5 A2 2 0 0 1 13.5 19.5 H6.5 A2 2 0 0 1 4.5 17.5 Z M8 12 L12 16 M12 12 L8 16",
        "timer": "M4.5 13.5 A7.5 7.5 0 1 0 19.5 13.5 A7.5 7.5 0 1 0 4.5 13.5 M12 13.5 V9.5 M9.5 3 H14.5 M12 3 V6 M18.2 6.8 L19.4 5.6",
        "moon": "M19.5 14.6 A8 8 0 1 1 9.4 4.5 A6.4 6.4 0 0 0 19.5 14.6 Z",
        "sun": "M8 12 A4 4 0 1 0 16 12 A4 4 0 1 0 8 12 M12 2.5 V4.5 M12 19.5 V21.5 M2.5 12 H4.5 M19.5 12 H21.5 M5.3 5.3 L6.7 6.7 M17.3 17.3 L18.7 18.7 M5.3 18.7 L6.7 17.3 M17.3 6.7 L18.7 5.3",
        "power": "M7.4 6.6 A7.5 7.5 0 1 0 16.6 6.6 M12 3.5 V11.5",
        "stop": "M7.5 7.5 H16.5 V16.5 H7.5 Z",
        "menu": "M9.5 7 H19.5 M9.5 12 H19.5 M9.5 17 H19.5 M4.5 7 H4.6 M4.5 12 H4.6 M4.5 17 H4.6",
        "terminal": "M5 4.5 H19 A2.5 2.5 0 0 1 21.5 7 V17 A2.5 2.5 0 0 1 19 19.5 H5 A2.5 2.5 0 0 1 2.5 17 V7 A2.5 2.5 0 0 1 5 4.5 Z M7 9.5 L10 12 L7 14.5 M12.5 15 H17",
        "chevronleft": "M14.5 5 L7.5 12 L14.5 19",
        "chevronright": "M9.5 5 L16.5 12 L9.5 19",
        "speaker": "M3.5 9.5 H7 L11.5 5.5 V18.5 L7 14.5 H3.5 Z",
        "wave1": "M15 9.5 A3.6 3.6 0 0 1 15 14.5",
        "wave2": "M17.5 7.2 A6.8 6.8 0 0 1 17.5 16.8",
        "wave3": "M20 5 A10 10 0 0 1 20 19",
        "mute": "M15.5 9.5 L20.5 14.5 M20.5 9.5 L15.5 14.5",
        "info": "M3 12 A9 9 0 1 0 21 12 A9 9 0 1 0 3 12 M12 11 V16.5 M12 7.5 H12.05",
        "check": "M5.5 12.5 L10 17 L18.5 7.5",
        "backspace": "M9 5.5 H19 A2 2 0 0 1 21 7.5 V16.5 A2 2 0 0 1 19 18.5 H9 L3 12 Z M11.5 9.5 L16.5 14.5 M16.5 9.5 L11.5 14.5",
        "return": "M19.5 5 V12.5 A2 2 0 0 1 17.5 14.5 H5 M9 10.5 L5 14.5 L9 18.5",
        "shift": "M12 3.5 L20.5 12.5 H15.5 V20 H8.5 V12.5 H3.5 Z",
        "shiftfill": "M12 3.5 L20.5 12.5 H15.5 V20 H8.5 V12.5 H3.5 Z",
        "capslock": "M12 3.5 L20.5 11.5 H15.5 V16 H8.5 V11.5 H3.5 Z M8.5 20 H15.5",
        "arrowup": "M12 19 V5.5 M6 11.5 L12 5.5 L18 11.5",
        "arrowdown": "M12 5 V18.5 M6 12.5 L12 18.5 L18 12.5",
        "arrowleft": "M19 12 H5.5 M11.5 6 L5.5 12 L11.5 18",
        "arrowright": "M5 12 H18.5 M12.5 6 L18.5 12 L12.5 18",
        "tab": "M3.5 12 H16.5 M11.5 7 L16.5 12 L11.5 17 M20.5 6 V18",
        "pscross": "M7 7 L17 17 M17 7 L7 17",
        "pscircle": "M6.5 12 A5.5 5.5 0 1 0 17.5 12 A5.5 5.5 0 1 0 6.5 12",
        "pssquare": "M7 7 H17 V17 H7 Z",
        "pstriangle": "M12 6 L18 16.5 H6 Z",
        "dpad": "M9.5 3.5 H14.5 V9.5 H20.5 V14.5 H14.5 V20.5 H9.5 V14.5 H3.5 V9.5 H9.5 Z",
        "play": "M8 5.5 V18.5 L18.5 12 Z",
        "pause": "M8 5.5 V18.5 M16 5.5 V18.5",
        "back10": "M4.5 12 A7.5 7.5 0 1 0 7 6.4 M7 2.8 V6.6 H10.8",
        "fwd10": "M19.5 12 A7.5 7.5 0 1 1 17 6.4 M17 2.8 V6.6 H13.2",
        "subtitles": "M3.5 5.5 H20.5 V18.5 H3.5 Z M6.5 14.5 H11 M13 14.5 H17.5 M6.5 11 H9 M11 11 H17.5",
        "search": "M4 10.5 A6.5 6.5 0 1 0 17 10.5 A6.5 6.5 0 1 0 4 10.5 M15.3 15.3 L20.5 20.5",
        "gear": "M19.07 9.81 L21.41 10.09 L21.41 13.91 L19.07 14.19 A7.4 7.4 0 0 1 18.55 15.45 L20.00 17.30 L17.30 20.00 L15.45 18.55 A7.4 7.4 0 0 1 14.19 19.07 L13.91 21.41 L10.09 21.41 L9.81 19.07 A7.4 7.4 0 0 1 8.55 18.55 L6.70 20.00 L4.00 17.30 L5.45 15.45 A7.4 7.4 0 0 1 4.93 14.19 L2.59 13.91 L2.59 10.09 L4.93 9.81 A7.4 7.4 0 0 1 5.45 8.55 L4.00 6.70 L6.70 4.00 L8.55 5.45 A7.4 7.4 0 0 1 9.81 4.93 L10.09 2.59 L13.91 2.59 L14.19 4.93 A7.4 7.4 0 0 1 15.45 5.45 L17.30 4.00 L20.00 6.70 L18.55 8.55 A7.4 7.4 0 0 1 19.07 9.81 Z M9 12 A3 3 0 1 0 15 12 A3 3 0 1 0 9 12",
        "plus": "M12 5 V19 M5 12 H19",
        "minus": "M5 12 H19",
        "list": "M8.5 7 H19.5 M8.5 12 H19.5 M8.5 17 H19.5 M4.5 7 H4.6 M4.5 12 H4.6 M4.5 17 H4.6",
        "bolt": "M13 3 L5.5 13.5 H11.5 L10.5 21 L18.5 10.5 H12.5 Z",
        "hourglass": "M7 3.5 H17 M7 20.5 H17 M8 3.5 C8 9 16 9 16 12 C16 15 8 15 8 20.5 M16 3.5 C16 9 8 9 8 12",
        "trash": "M4.5 6.5 H19.5 M9.5 6.5 V4.5 H14.5 V6.5 M6.5 6.5 L7.5 20 H16.5 L17.5 6.5",
        "eye": "M2.5 12 C5 7 9 5 12 5 C15 5 19 7 21.5 12 C19 17 15 19 12 19 C9 19 5 17 2.5 12 Z M9.5 12 A2.5 2.5 0 1 0 14.5 12 A2.5 2.5 0 1 0 9.5 12",
        "copy": "M8.5 8.5 H18.5 V19.5 H8.5 Z M5.5 15.5 V4.5 H15.5",
        "person": "M8 8 A4 4 0 1 0 16 8 A4 4 0 1 0 8 8 M4.5 20.5 C5.5 16 8.5 14 12 14 C15.5 14 18.5 16 19.5 20.5",
        "forward": "M4.5 6 L12 12 L4.5 18 Z M12 6 L19.5 12 L12 18 Z",
        "rewind": "M19.5 6 L12 12 L19.5 18 Z M12 6 L4.5 12 L12 18 Z",
        "next": "M5.5 6 L14.5 12 L5.5 18 Z M18.5 6 V18",
        "audio": "M3.5 9.5 H7 L11.5 5.5 V18.5 L7 14.5 H3.5 Z M15 9.5 A3.6 3.6 0 0 1 15 14.5 M17.5 7.2 A6.8 6.8 0 0 1 17.5 16.8",
        "feedback": "M4.5 6.5 A2 2 0 0 1 6.5 4.5 H17.5 A2 2 0 0 1 19.5 6.5 V14.5 A2 2 0 0 1 17.5 16.5 H10.5 L6.5 20 V16.5 A2 2 0 0 1 4.5 14.5 Z M8.5 10.6 L11 13 L15.5 8.4",
        "checkcircle": "M3 12 A9 9 0 1 0 21 12 A9 9 0 1 0 3 12 M8 12.2 L10.8 15 L16 9.4",
        "film": "M4 5.5 H20 V18.5 H4 Z M8 5.5 V18.5 M16 5.5 V18.5 M4 9.8 H8 M4 14.2 H8 M16 9.8 H20 M16 14.2 H20",
        "sliders": "M5 4.5 V19.5 M12 4.5 V19.5 M19 4.5 V19.5 M3 14.5 H7 M10 8.5 H14 M17 15.5 H21",
        "sync": "M19.5 9.5 A7.6 7.6 0 0 0 5.5 7.6 M4.5 14.5 A7.6 7.6 0 0 0 18.5 16.4 M5 3.5 V7.8 H9.3 M19 20.5 V16.2 H14.7",
        "spark": ""
    })
    // a spark: rays of uneven length around a point
    function spark() {
        var out = "", lens = [8.6, 6.4, 8.9, 7.0, 8.2, 6.2, 8.8, 6.8, 8.0, 7.2, 8.7, 6.6]
        for (var i = 0; i < lens.length; ++i) {
            var a = i / lens.length * Math.PI * 2 - Math.PI / 2 + 0.13
            out += "M" + (12 + Math.cos(a) * 2.2).toFixed(2) + " " + (12 + Math.sin(a) * 2.2).toFixed(2) +
                   " L" + (12 + Math.cos(a) * lens[i]).toFixed(2) + " " + (12 + Math.sin(a) * lens[i]).toFixed(2) + " "
        }
        return out
    }
    readonly property string d: name === "spark" ? spark() : (paths[name] || "")
    readonly property bool filled: name === "speaker" || name === "forward" || name === "rewind" || name === "stop" || name === "moon" || name === "shiftfill" || name === "capslock"
                                  || name === "play" || name === "bolt" || name === "forward" || name === "rewind" || name === "next"

    Shape {
        anchors.centerIn: parent
        width: 24; height: 24
        scale: Math.min(sym.width, sym.height) / 24
        preferredRendererType: Shape.CurveRenderer
        ShapePath {
            strokeColor: sym.color
            strokeWidth: sym.name === "spark" ? 2.3 : sym.weight
            fillColor: sym.filled ? sym.color : "transparent"
            capStyle: ShapePath.RoundCap
            joinStyle: ShapePath.RoundJoin
            PathSvg { path: sym.d }
        }
    }
}
