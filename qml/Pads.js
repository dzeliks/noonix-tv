.pragma library
// what a pad button is called on each family. buttons by position (input.cpp): south east west north,
// lb rb lt rt, back start guide, ls rs, touchpad, misc1

var face = { south: true, east: true, west: true, north: true }

// face buttons: a playstation shape (a Symbol name) or the letter printed on it
var faces = {
    playstation: { south: "pscross", east: "pscircle", west: "pssquare", north: "pstriangle" },
    xbox: { south: "A", east: "B", west: "X", north: "Y" },
    nintendo: { south: "B", east: "A", west: "Y", north: "X" }
}

var names = {
    playstation: { lb: "L1", rb: "R1", lt: "L2", rt: "R2", back: "Create", start: "Options", guide: "PS", ls: "L3", rs: "R3", touchpad: "Touchpad", misc1: "Mute" },
    xbox: { lb: "LB", rb: "RB", lt: "LT", rt: "RT", back: "View", start: "Menu", guide: "Xbox", ls: "LS", rs: "RS", misc1: "Share" },
    nintendo: { lb: "L", rb: "R", lt: "ZL", rt: "ZR", back: "−", start: "+", guide: "Home", ls: "L3", rs: "R3", misc1: "Capture" },
    generic: { lb: "LB", rb: "RB", lt: "LT", rt: "RT", back: "Select", start: "Start", guide: "Home", ls: "L3", rs: "R3", touchpad: "Touchpad", misc1: "Misc" }
}

var shapeWords = { pscross: "Cross", pscircle: "Circle", pssquare: "Square", pstriangle: "Triangle" }

// "symbol" (a shape), "letter", "dots" (generic face: which of the four) or "pill" (a named button)
function look(kind, button) {
    if (face[button]) {
        if (kind === "playstation") return { type: "symbol", value: faces.playstation[button] }
        if (faces[kind]) return { type: "letter", value: faces[kind][button] }
        return { type: "dots", value: button }
    }
    var n = (names[kind] || names.generic)[button] || names.generic[button] || button
    return { type: "pill", value: n }
}

// one line of text for a button (settings lists); positions = the generic face words, translated by the caller
function text(kind, button, positions) {
    var l = look(kind, button)
    if (l.type === "symbol") return shapeWords[l.value]
    if (l.type === "dots") return positions[button]
    return l.value
}

// keyboard key names as qt spells them (QKeySequence portable text) -> as the keycap says
function keyText(k) {
    return k === "Return" ? "Enter" : k === "PgUp" ? "Page Up" : k === "PgDown" ? "Page Down" : k
}
