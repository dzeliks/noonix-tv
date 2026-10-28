pragma Singleton
import QtQuick
import Noonix.Core

// callback-style access to the rust core: Api.call(method, args, function (ok, data) {})
QtObject {
    id: api
    property var pending: ({})
    signal pushed(string name, var data)

    function call(method, args, done) {
        var id = Core.call(method, JSON.stringify(args || {}))
        if (done) pending[id] = done
        return id
    }

    readonly property Connections link: Connections {
        target: Core
        function onResult(id, ok, json) {
            var done = api.pending[id]
            if (!done) return
            delete api.pending[id]
            var data = null
            try { data = JSON.parse(json) } catch (e) {}
            done(ok, data)
        }
        function onPush(name, json) {
            var data = null
            try { data = JSON.parse(json) } catch (e) {}
            api.pushed(name, data)
        }
    }
}
