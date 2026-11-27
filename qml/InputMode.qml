pragma Singleton
import QtQuick

// how text is typed (KeyEntry, ProfileAdd, Search): picked as a sheet or page opens, not while typing
QtObject {
    // a remote or a pad is in charge: its keys came last, no mouse, no finger
    readonly property bool remote: !Theme.pointing && !Theme.mouse && (Remote.inputKind === "remote" || Remote.inputKind === "pad")
    // a finger on a pc's touch screen: ours is its only keyboard (no real field takes a tap, so the
    // system's touch keyboard never comes up beside it)
    readonly property bool pcFinger: Theme.pointing && !Theme.mouse && !Theme.android
    // "ime" the phone's keyboard (a finger on android), "osk" the glass keyboard (a remote, a pad, a
    // finger on a pc), "keys" a real keyboard and the mouse
    function pick() {
        if (Theme.touch) return "ime"
        if (remote || pcFinger) return "osk"
        return "keys"
    }
}
