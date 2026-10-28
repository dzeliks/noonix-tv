// a live picture of one kwin window (zkde_screencast -> pipewire -> dma-buf),
// streams while `uuid` is set
import QtQuick
import org.kde.taskmanager as TM
import org.kde.pipewire as PW

Item {
    id: st
    property string uuid: ""
    readonly property bool ready: uuid !== "" && req.nodeId > 0 && pw.ready

    TM.ScreencastingRequest {
        id: req; uuid: st.uuid
        onNodeIdChanged: if (Desktop.debug) console.log("screencast node", nodeId)
    }
    PW.PipeWireSourceItem {
        id: pw
        anchors.fill: parent
        nodeId: st.uuid !== "" ? req.nodeId : 0
        visible: st.uuid !== ""      // it only turns ready after drawing (the backdrop is hidden anyway)
        onReadyChanged: if (Desktop.debug) console.log("pipewire ready", ready)
    }
}
