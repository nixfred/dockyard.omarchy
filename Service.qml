import QtQuick
import Quickshell
import Quickshell.Io

// One poll of dockyard.py, relayed to the bar and the panel.
// Container actions run only from a click in the panel.
Item {
  id: root

  property var settings: ({})
  readonly property string pluginDir: decodeURIComponent(String(Qt.resolvedUrl(".")).replace(/^file:\/\/(localhost)?/, ""))

  property bool ready: false
  property bool ok: true
  property bool daemon: false
  property string error: ""
  property var data: ({})
  property var busy: ({})          // id -> verb while an action is in flight
  property string lastAction: ""

  readonly property int running: data.running || 0
  readonly property int total: data.total || 0
  readonly property int unhealthy: data.unhealthy || 0
  readonly property bool cdiStale: !!(data.cdi && data.cdi.stale && data.cdi.stale.length)

  readonly property int refreshSec: {
    var n = parseInt(String(settings && settings.refreshSec !== undefined ? settings.refreshSec : 10), 10)
    return isFinite(n) ? Math.max(3, Math.min(300, n)) : 10
  }

  function apply(text) {
    var d
    try { d = JSON.parse(text) } catch (e) { ok = false; error = "bad JSON from dockyard.py"; ready = true; return }
    ok = !!d.ok
    daemon = !!d.daemon
    error = d.error || ""
    data = d
    ready = true
  }

  Process {
    id: poll
    command: ["python3", root.pluginDir + "dockyard.py"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.apply(text)
    }
  }

  Process {
    id: act
    property string cid: ""
    property string verb: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var r
        try { r = JSON.parse(text) } catch (e) { r = { ok: false, error: "no reply" } }
        root.lastAction = (r.ok ? "ok: " : "FAILED: ") + act.verb + " " + act.cid + (r.ok ? "" : "  " + (r.error || ""))
      }
    }
    onRunningChanged: if (!running) {
      var b = Object.assign({}, root.busy); delete b[cid]; root.busy = b
      root.refresh()
      root.drain()
    }
  }

  property var queue: []
  function drain() {
    if (act.running || queue.length === 0) return
    var next = queue[0]
    queue = queue.slice(1)
    act.cid = next[1]; act.verb = next[0]
    act.command = ["python3", root.pluginDir + "dockyard.py", next[0], next[1]]
    act.running = true
  }
  function control(verb, cid) {
    if (busy[cid]) return
    var b = Object.assign({}, busy); b[cid] = verb; busy = b
    queue = queue.concat([[verb, cid]])
    drain()
  }

  Process { id: launcher }
  function logs(name) {
    launcher.command = ["xdg-terminal-exec", "docker", "logs", "-f", "-n", "200", "-t", String(name)]
    launcher.running = true
  }
  Process { id: clip }
  function copy(s) { clip.command = ["wl-copy", String(s)]; clip.running = true }

  function refresh() { if (!poll.running) poll.running = true }

  Timer {
    interval: root.refreshSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }
}
