import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// Whale glyph and the running container count.
BarWidget {
  id: root
  moduleName: "nixfred.dockyard"
  property var anchorItem: button

  readonly property var svc: bar && bar.shell ? bar.shell.serviceFor(moduleName) : null
  readonly property bool up: svc ? svc.daemon : false
  readonly property int running: svc ? svc.running : 0
  readonly property bool alarm: svc ? (svc.unhealthy > 0 || svc.cdiStale) : false
  readonly property color foreground: bar ? bar.foreground : Color.foreground

  readonly property string label: String.fromCodePoint(0xF0868) + " " + (up ? String(running) : "off")

  implicitWidth: vertical ? barSize : Math.max(Style.space(40), txt.implicitWidth + Style.space(16))
  implicitHeight: vertical ? Style.space(40) : barSize

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: ""
    labelVisible: false
    hasVisualContent: true
    active: false
    useActiveColor: false
    tooltipText: !svc ? "Dockyard"
      : !svc.daemon ? "Dockyard: " + (svc.error || "docker not running")
      : "Dockyard: " + svc.running + " running of " + svc.total
        + (svc.unhealthy ? ", " + svc.unhealthy + " unhealthy" : "")
        + (svc.cdiStale ? ", CDI spec STALE" : "")

    Text {
      id: txt
      anchors.centerIn: parent
      text: root.label
      color: root.alarm ? "#ff4d5e" : (root.up && root.running > 0 ? root.foreground : Util.alpha(root.foreground, 0.45))
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.bodySmall
    }

    onPressed: function(code) {
      if (root.bar) root.bar.hideTooltip(root)
      root.toggle()
    }
  }

  readonly property bool opened: panel.opened
  function open() { panel.controller.show(); if (svc) svc.refresh() }
  function close() { panel.controller.hide() }
  function toggle() { opened ? close() : open() }
  function closeForPopoutSwitch() { close() }
  readonly property bool popoutSwitchClosing: false

  DockPanel {
    id: panel
    widget: root
  }
}
