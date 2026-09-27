import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Ui

// The cockpit. Law 17: no page scroller. A stat strip across the top, the
// container list on the left (scrolls in place inside its own box), disk and
// engine health on the right.
Panel {
  id: panel
  moduleName: "nixfred.dockyard"
  manageIpc: true
  ipcTarget: "nixfred.dockyard"

  required property var widget
  readonly property var svc: widget.svc
  readonly property var d: svc ? svc.data : ({})
  readonly property var df: d.df || ({})
  readonly property var cdi: d.cdi || ({ specs: [], stale: [] })
  readonly property bool up: svc ? svc.daemon : false

  readonly property color foreground: widget.bar ? widget.bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.5)
  readonly property color faint: Util.alpha(foreground, 0.10)
  readonly property color accent: Color.accent
  readonly property color bad: "#ff4d5e"
  readonly property color warn: "#f5a623"
  readonly property string fontFamily: widget.bar ? widget.bar.fontFamily : Style.font.family
  readonly property int panelWidth: Style.space(1180)

  function bytes(n) {
    if (n === null || n === undefined) return "--"
    var u = ["B", "K", "M", "G", "T"], i = 0
    while (n >= 1024 && i < u.length - 1) { n /= 1024; i++ }
    return (i >= 3 ? n.toFixed(1) : Math.round(n)) + u[i]
  }
  function stateColor(s, h) {
    if (h === "unhealthy" || s === "restarting" || s === "dead") return bad
    if (s === "running") return h === "starting" ? warn : accent
    if (s === "paused") return dim
    return Util.alpha(foreground, 0.3)
  }

  component Stat: Rectangle {
    property string label: ""
    property string value: ""
    property string tip: ""
    property color valueColor: panel.foreground
    Layout.fillWidth: true
    implicitHeight: Style.space(58)
    radius: Style.space(6)
    color: panel.faint
    border.width: 1
    border.color: Util.alpha(valueColor === panel.bad ? panel.bad : panel.accent, 0.35)
    Column {
      anchors.centerIn: parent
      spacing: Style.space(2)
      Text { anchors.horizontalCenter: parent.horizontalCenter; text: parent.parent.value
             color: parent.parent.valueColor; font.family: panel.fontFamily
             font.pixelSize: Style.font.subtitle * 1.2; font.bold: true }
      Text { anchors.horizontalCenter: parent.horizontalCenter; text: parent.parent.label
             color: panel.dim; font.family: panel.fontFamily; font.pixelSize: Style.font.bodySmall
             font.letterSpacing: 1.5 }
    }
    MouseArea { id: sm; anchors.fill: parent; hoverEnabled: true }
    ToolTip.visible: sm.containsMouse && tip !== ""
    ToolTip.text: tip
  }

  component Caption: Text {
    color: panel.dim
    font.family: panel.fontFamily
    font.pixelSize: Style.font.bodySmall
    font.letterSpacing: 2
  }

  component Chip: Rectangle {
    id: chip
    property string glyph: ""
    property string tip: ""
    property color tint: panel.accent
    property bool enabledChip: true
    signal activated()
    implicitWidth: Style.space(26); implicitHeight: Style.space(22)
    radius: 3
    color: cm.containsMouse && enabledChip ? Util.alpha(tint, 0.30) : Util.alpha(tint, 0.08)
    border.width: 1; border.color: Util.alpha(tint, enabledChip ? 0.45 : 0.15)
    Text { anchors.centerIn: parent; text: chip.glyph; color: chip.enabledChip ? chip.tint : panel.dim
           font.family: panel.fontFamily; font.pixelSize: Style.font.bodySmall }
    MouseArea { id: cm; anchors.fill: parent; hoverEnabled: true
                cursorShape: chip.enabledChip ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: if (chip.enabledChip) chip.activated() }
    ToolTip.visible: cm.containsMouse && tip !== ""
    ToolTip.text: tip
  }

  component Bar: RowLayout {
    property string label: ""
    property real value: 0
    property real maxv: 1
    property string tip: ""
    property color tint: panel.accent
    Layout.fillWidth: true
    spacing: Style.space(8)
    Text { Layout.preferredWidth: Style.space(96); text: parent.label; color: panel.dim
           font.family: panel.fontFamily; font.pixelSize: Style.font.bodySmall }
    Rectangle {
      Layout.fillWidth: true; height: Style.space(8); radius: 2; color: panel.faint; border.width: 0
      Rectangle { height: parent.height; radius: 2; border.width: 0; color: parent.parent.tint
                  width: parent.width * Math.min(1, parent.parent.value / Math.max(1, parent.parent.maxv)) }
      MouseArea { id: bmm; anchors.fill: parent; hoverEnabled: true }
      ToolTip.visible: bmm.containsMouse && parent.tip !== ""
      ToolTip.text: parent.tip
    }
    Text { Layout.preferredWidth: Style.space(58); horizontalAlignment: Text.AlignRight
           text: panel.bytes(parent.value); color: panel.foreground
           font.family: panel.fontFamily; font.pixelSize: Style.font.bodySmall }
  }

  KeyboardPanel {
    id: kpanel
    anchorItem: panel.widget.anchorItem
    owner: panel.widget
    bar: panel.widget.bar
    open: panel.opened
    focusTarget: keyCatcher
    contentWidth: kpanel.fittedContentWidth(panel.panelWidth)
    contentHeight: kpanel.fittedContentHeight(content.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: panel.widget.close()

      ColumnLayout {
        id: content
        width: parent.width
        spacing: Style.space(10)

        // ---------------- header
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(10)
          Text { text: String.fromCodePoint(0xF0868); color: panel.accent
                 font.family: panel.fontFamily; font.pixelSize: Style.font.subtitle }
          Text { text: "DOCKYARD"; color: panel.foreground; font.family: panel.fontFamily
                 font.pixelSize: Style.font.subtitle; font.bold: true; font.letterSpacing: 3 }
          Text {
            Layout.fillWidth: true
            elide: Text.ElideRight
            text: !svc ? "--"
                  : !panel.up ? (svc.error || "docker not running")
                  : "engine " + (d.version || "?") + "  //  api " + (d.api || "?") + "  //  "
                    + ((d.host || {}).driver || "") + " / " + ((d.host || {}).cgroup || "") + " cgroup  //  "
                    + (d.generated || "--") + (svc.lastAction ? "  //  " + svc.lastAction : "")
            color: !panel.up || (svc && svc.lastAction.indexOf("FAILED") === 0) ? panel.bad : panel.dim
            font.family: panel.fontFamily; font.pixelSize: Style.font.bodySmall
          }
          Chip {
            glyph: String.fromCodePoint(0xF0450)
            tip: "Poll the Engine API now. Disk usage is cached for 5 minutes."
            onActivated: if (svc) svc.refresh()
          }
        }

        Rectangle { Layout.fillWidth: true; height: 1; color: panel.faint; border.width: 0 }

        // ---------------- stat strip
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(8)
          Stat { label: "RUNNING"; value: panel.up ? (d.running || 0) + "/" + (d.total || 0) : "OFF"
                 valueColor: panel.up ? panel.accent : panel.bad
                 tip: panel.up ? "Running containers / all containers, including stopped" : (svc ? svc.error : "") }
          Stat { label: "CPU"; value: panel.up ? (d.cpuTotal || 0) + "%" : "--"
                 tip: "Sum of container CPU since the last poll, 100% = one core. "
                      + ((d.host || {}).ncpu || "?") + " cores on host, " + (d.cpuNorm || 0) + "% of all" }
          Stat { label: "MEMORY"; value: panel.up ? panel.bytes(d.memTotal || 0) : "--"
                 tip: "Sum of memory.current over running containers (cgroup v2). Host has " + panel.bytes((d.host || {}).mem || 0) }
          Stat { label: "GPU"; value: panel.up ? String(d.gpuCount || 0) : "--"
                 tip: "Running containers with a GPU device request, CDI device or NVIDIA runtime env" }
          Stat { label: "UNHEALTHY"; value: panel.up ? String(d.unhealthy || 0) : "--"
                 valueColor: (d.unhealthy || 0) > 0 ? panel.bad : panel.foreground
                 tip: "Healthcheck failing, restarting or dead" }
          Stat { label: "IMAGES"; value: df.images !== undefined ? panel.bytes(df.imageSize) : "--"
                 tip: (df.images || 0) + " images. Size counts shared layers once per image; unique on disk is "
                      + panel.bytes(df.layers || 0) }
          Stat { label: "RECLAIM"; value: df.reclaimable !== undefined ? panel.bytes(df.reclaimable) : "--"
                 tip: (df.unusedImages || 0) + " images used by no container. docker image prune -a frees about this (shared layers may keep some)" }
          Stat { label: "DANGLING"; value: d.dangling ? String(d.dangling.count) : "--"
                 valueColor: d.dangling && d.dangling.count > 0 ? (panel.warn) : panel.foreground
                 tip: d.dangling ? "Untagged images: " + panel.bytes(d.dangling.size) + ". docker image prune removes them" : "" }
          Stat { label: "CDI"; value: panel.cdi.stale.length ? "STALE" : (panel.cdi.specs.length ? "OK" : "none")
                 valueColor: panel.cdi.stale.length ? panel.bad : panel.foreground
                 tip: panel.cdi.stale.length
                      ? "Device majors in the CDI spec do not match /dev:\n" + panel.cdi.stale.join("\n")
                        + "\nFix: sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml, then recreate GPU containers"
                      : panel.cdi.specs.length ? "Every device major in " + panel.cdi.specs.map(function(s) { return s.path }).join(", ") + " matches /dev"
                      : "No CDI specs in /etc/cdi or /var/run/cdi" }
        }

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(16)

          // ---------------- left: containers
          ColumnLayout {
            Layout.preferredWidth: panel.panelWidth * 0.68
            Layout.maximumWidth: panel.panelWidth * 0.68
            Layout.alignment: Qt.AlignTop
            spacing: Style.space(6)

            Caption { text: "CONTAINERS  //  click a name to copy its id" }
            RowLayout {
              Layout.fillWidth: true
              Layout.leftMargin: Style.space(10); Layout.rightMargin: Style.space(16)
              spacing: Style.space(8)
              Repeater {
                model: [["", 10], ["NAME", -1], ["CPU", 52], ["MEM", 56], ["PORTS", 120], ["UP", 70], ["", 86]]
                delegate: Text {
                  required property var modelData
                  Layout.preferredWidth: modelData[1] > 0 ? Style.space(modelData[1]) : -1
                  Layout.fillWidth: modelData[1] < 0
                  text: modelData[0]; color: panel.dim; font.family: panel.fontFamily
                  font.pixelSize: Style.font.bodySmall * 0.85; font.letterSpacing: 1.5
                }
              }
            }
            Rectangle {
              Layout.fillWidth: true
              Layout.preferredHeight: Style.space(360)
              radius: Style.space(6); color: panel.faint; border.width: 0
              clip: true
              ListView {
                id: list
                anchors.fill: parent; anchors.margins: Style.space(6)
                model: panel.up ? (d.containers || []) : []
                spacing: Style.space(3)
                boundsBehavior: Flickable.StopAtBounds
                ScrollBar.vertical: ScrollBar {}
                Column {
                  anchors.centerIn: parent
                  visible: list.count === 0
                  spacing: Style.space(6)
                  Text { anchors.horizontalCenter: parent.horizontalCenter
                         text: String.fromCodePoint(0xF0868); color: panel.up ? panel.dim : panel.bad
                         font.family: panel.fontFamily; font.pixelSize: Style.font.subtitle * 2 }
                  Text { anchors.horizontalCenter: parent.horizontalCenter
                         text: !svc || !svc.ready ? "reading the engine..."
                               : panel.up ? "No containers. The yard is empty."
                               : (svc.error || "docker not running").toUpperCase()
                         color: panel.up ? panel.dim : panel.bad
                         font.family: panel.fontFamily; font.pixelSize: Style.font.bodySmall; font.letterSpacing: 1.5 }
                  Text { anchors.horizontalCenter: parent.horizontalCenter; visible: svc && svc.ready && !panel.up
                         text: "sudo systemctl start docker"
                         color: panel.dim; font.family: panel.fontFamily; font.pixelSize: Style.font.bodySmall }
                }
                delegate: Rectangle {
                  id: row
                  required property var modelData
                  readonly property bool isUp: modelData.state === "running"
                  readonly property string busyVerb: svc && svc.busy[modelData.id] ? svc.busy[modelData.id] : ""
                  width: list.width - Style.space(10)
                  height: Style.space(40)
                  radius: 3; border.width: 0
                  color: rm.containsMouse ? Util.alpha(panel.accent, 0.12) : "transparent"
                  MouseArea { id: rm; anchors.fill: parent; hoverEnabled: true; acceptedButtons: Qt.NoButton }
                  RowLayout {
                    anchors.fill: parent; anchors.leftMargin: 4; anchors.rightMargin: 4
                    spacing: Style.space(8)
                    Rectangle { Layout.preferredWidth: Style.space(10); Layout.preferredHeight: Style.space(10)
                                radius: width / 2; border.width: 0
                                color: panel.stateColor(row.modelData.state, row.modelData.health)
                                MouseArea { id: dm; anchors.fill: parent; hoverEnabled: true }
                                ToolTip.visible: dm.containsMouse
                                ToolTip.text: row.modelData.status + (row.modelData.health ? "  health: " + row.modelData.health : "")
                                              + "\nrestart policy: " + (row.modelData.policy || "no") + ", restarts: " + row.modelData.restarts }
                    Column {
                      Layout.fillWidth: true
                      Layout.preferredWidth: 100
                      spacing: 1
                      RowLayout {
                        width: parent.width
                        spacing: Style.space(6)
                        Text { Layout.fillWidth: true; text: row.modelData.name; elide: Text.ElideMiddle
                               color: row.isUp ? panel.foreground : panel.dim; font.family: panel.fontFamily
                               font.pixelSize: Style.font.bodySmall; font.bold: row.isUp
                               MouseArea { id: nm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                           onClicked: if (svc) svc.copy(row.modelData.id) }
                               ToolTip.visible: nm.containsMouse
                               ToolTip.text: row.modelData.name + "\nid " + row.modelData.id + " (click copies)" }
                        Rectangle { visible: row.modelData.gpu; implicitWidth: gt.implicitWidth + 8; implicitHeight: gt.implicitHeight + 2
                                    radius: 2; color: Util.alpha(panel.accent, 0.2); border.width: 1; border.color: panel.accent
                                    Text { id: gt; anchors.centerIn: parent; text: "GPU"; color: panel.accent
                                           font.family: panel.fontFamily; font.pixelSize: Style.font.bodySmall * 0.75; font.bold: true } }
                        Rectangle { visible: row.modelData.compose !== ""; implicitWidth: ct.implicitWidth + 8; implicitHeight: ct.implicitHeight + 2
                                    radius: 2; color: "transparent"; border.width: 1; border.color: Util.alpha(panel.foreground, 0.3)
                                    Text { id: ct; anchors.centerIn: parent; text: row.modelData.compose; color: panel.dim
                                           font.family: panel.fontFamily; font.pixelSize: Style.font.bodySmall * 0.75 } }
                      }
                      Text { width: parent.width; text: row.modelData.image + (row.isUp ? "" : "   exit " + row.modelData.exit)
                             elide: Text.ElideMiddle; color: panel.dim
                             font.family: panel.fontFamily; font.pixelSize: Style.font.bodySmall * 0.8 }
                    }
                    Text { Layout.preferredWidth: Style.space(52); horizontalAlignment: Text.AlignRight
                           text: row.modelData.cpu === null ? "--" : row.modelData.cpu + "%"
                           color: row.modelData.cpu > 50 ? panel.bad : panel.foreground
                           font.family: panel.fontFamily; font.pixelSize: Style.font.bodySmall }
                    Text { Layout.preferredWidth: Style.space(56); horizontalAlignment: Text.AlignRight
                           text: panel.bytes(row.modelData.mem); color: panel.foreground
                           font.family: panel.fontFamily; font.pixelSize: Style.font.bodySmall
                           MouseArea { id: mm; anchors.fill: parent; hoverEnabled: true }
                           ToolTip.visible: mm.containsMouse && row.modelData.mem !== null
                           ToolTip.text: "memory.current " + panel.bytes(row.modelData.mem) + " / limit "
                                         + (row.modelData.memLimit ? panel.bytes(row.modelData.memLimit) : "none") }
                    Text { Layout.preferredWidth: Style.space(120); text: row.modelData.ports.join(" ") || "--"
                           elide: Text.ElideRight; color: panel.dim
                           font.family: panel.fontFamily; font.pixelSize: Style.font.bodySmall * 0.85
                           MouseArea { id: pm; anchors.fill: parent; hoverEnabled: true }
                           ToolTip.visible: pm.containsMouse && row.modelData.ports.length > 0
                           ToolTip.text: row.modelData.ports.join("\n") }
                    Text { Layout.preferredWidth: Style.space(70); text: row.modelData.uptime || "--"; elide: Text.ElideRight
                           color: row.isUp ? panel.accent : panel.dim
                           font.family: panel.fontFamily; font.pixelSize: Style.font.bodySmall * 0.85 }
                    Row {
                      Layout.preferredWidth: Style.space(86)
                      spacing: Style.space(4)
                      Chip { glyph: row.busyVerb ? String.fromCodePoint(0xF0996) : String.fromCodePoint(row.isUp ? 0xF04DB : 0xF040A)
                             tint: row.isUp ? panel.bad : panel.accent; enabledChip: !row.busyVerb
                             tip: row.busyVerb ? row.busyVerb + "ing..." : (row.isUp ? "Stop (SIGTERM, 10 s grace)" : "Start")
                             onActivated: svc.control(row.isUp ? "stop" : "start", row.modelData.id) }
                      Chip { glyph: String.fromCodePoint(0xF0453); enabledChip: !row.busyVerb
                             tip: "Restart. Keeps the old device list; recreate GPU containers after a CDI fix"
                             onActivated: svc.control("restart", row.modelData.id) }
                      Chip { glyph: String.fromCodePoint(0xF0219); tint: panel.foreground
                             tip: "Logs: docker logs -f -n 200 in a terminal"
                             onActivated: svc.logs(row.modelData.name) }
                    }
                  }
                }
              }
            }
          }

          // ---------------- right: disk, images, engine
          ColumnLayout {
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignTop
            spacing: Style.space(6)

            Caption { text: "DISK  //  cached 5 min" }
            Bar { label: "images"; value: df.imageSize || 0; maxv: Math.max(df.imageSize || 0, df.buildCache || 0, df.volumeSize || 0, 1)
                  tip: (df.images || 0) + " images, " + panel.bytes(df.shared || 0) + " in shared layers" }
            Bar { label: "unique layers"; value: df.layers || 0; maxv: Math.max(df.imageSize || 0, 1)
                  tip: "What the image store really occupies once shared layers are counted once" }
            Bar { label: "reclaimable"; value: df.reclaimable || 0; maxv: Math.max(df.imageSize || 0, 1); tint: panel.warn
                  tip: "Images no container uses" }
            Bar { label: "dangling"; value: d.dangling ? d.dangling.size : 0; maxv: Math.max(df.imageSize || 0, 1); tint: panel.bad
                  tip: (d.dangling ? d.dangling.count : 0) + " untagged images" }
            Bar { label: "build cache"; value: df.buildCache || 0; maxv: Math.max(df.imageSize || 0, 1)
                  tip: "docker builder prune frees this" }
            Bar { label: "volumes"; value: df.volumeSize || 0; maxv: Math.max(df.imageSize || 0, 1)
                  tip: (df.volumes || 0) + " volumes" }

            Caption { Layout.topMargin: Style.space(6); text: "LARGEST IMAGES" }
            Repeater {
              model: df.top || []
              delegate: RowLayout {
                required property var modelData
                Layout.fillWidth: true
                spacing: Style.space(8)
                Text { text: modelData.used > 0 ? String.fromCodePoint(0xF0133) : String.fromCodePoint(0xF0130)
                       color: modelData.used > 0 ? panel.accent : panel.dim
                       font.family: panel.fontFamily; font.pixelSize: Style.font.bodySmall }
                Text { Layout.fillWidth: true; Layout.preferredWidth: 100; text: modelData.tag; elide: Text.ElideMiddle
                       color: modelData.used > 0 ? panel.foreground : panel.dim
                       font.family: panel.fontFamily; font.pixelSize: Style.font.bodySmall * 0.9
                       MouseArea { id: im; anchors.fill: parent; hoverEnabled: true }
                       ToolTip.visible: im.containsMouse
                       ToolTip.text: modelData.tag + "\n" + (modelData.used > 0 ? "used by " + modelData.used + " container(s)" : "unused") }
                Text { text: panel.bytes(modelData.size); color: panel.dim
                       font.family: panel.fontFamily; font.pixelSize: Style.font.bodySmall }
              }
            }

            Caption { Layout.topMargin: Style.space(6); text: "ENGINE" }
            Grid {
              Layout.fillWidth: true
              columns: 1
              columnSpacing: Style.space(10); rowSpacing: 2
              Repeater {
                model: [
                  ["runtimes", ((d.host || {}).runtimes || []).join(" ") || "--"],
                  ["root", (d.host || {}).root || "--"],
                  ["cdi", panel.cdi.specs.length ? panel.cdi.specs.map(function(s) { return s.path.split("/").pop() + " " + Qt.formatDate(new Date(s.mtime * 1000), "MMM d") }).join(", ") : "none"],
                  ["cdi check", panel.cdi.stale.length ? panel.cdi.stale.length + " major mismatch" : panel.cdi.specs.length ? "majors match /dev" : "no specs"]
                ]
                delegate: Text {
                  required property var modelData
                  required property int index
                  text: modelData[0] + "  " + modelData[1]; width: parent.width; elide: Text.ElideMiddle
                  color: modelData[0] === "cdi check" && panel.cdi.stale.length ? panel.bad : panel.dim
                  font.family: panel.fontFamily; font.pixelSize: Style.font.bodySmall * 0.85
                }
              }
            }
          }
        }
      }
    }
  }
}
