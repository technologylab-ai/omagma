import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.mjs" as Model

BarWidget {
  id: root
  moduleName: Model.PLUGIN_ID
  readonly property var service: bar && bar.shell ? bar.shell.firstPartyServiceFor(Model.PLUGIN_ID) : null
  function pushSettings() {
    if (service) service.configure(String(setting("daemonPath", "") || ""), String(setting("configPath", "") || ""),
      setting("fixtures", false) === true, false)
  }
  onServiceChanged: pushSettings()
  onSettingsChanged: Qt.callLater(root.pushSettings)
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false
  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function togglePanel() { if (opened) close(); else open() }
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight
  readonly property real openPanelIndicatorWidth: Math.max(icon.tightWidth, Style.space(10), Math.round(Style.bar.iconSlot * 0.55))

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("qml/QuickPanel.qml")
    visible: false
    onLoaded: {
      item.bar = Qt.binding(function() { return root.bar })
      item.settings = Qt.binding(function() { return root.settings })
      item.service = Qt.binding(function() { return root.service })
      item.anchorItem = button
      item.hostWidget = root
    }
  }
  IpcHandler {
    target: "io.github.technologylab_ai.omagma"
    function toggle(): void { root.togglePanel() }
    function open(): void { root.open() }
    function close(): void { root.close() }
    function refresh(): void { if (root.service) root.service.refresh() }
    function state(): string {
      return JSON.stringify({ daemon: root.service ? root.service.daemonState : "missing", opened: root.opened,
        selected: root.service ? root.service.selected : "", rows: root.service ? root.service.retainedRows : 0,
        layout: panelLoader.item ? panelLoader.item.layoutBounds() : null })
    }
  }
  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    labelVisible: false
    hasVisualContent: true
    dimmed: !root.service || root.service.daemonState !== "ready"
    fixedWidth: !vertical ? Style.bar.iconSlot : -1
    fixedHeight: vertical ? Style.bar.iconSlot : -1
    horizontalMargin: 8.75
    verticalPadding: 8.75
    tooltipText: "omagma · " + (root.service && root.service.fixtures ? "Demo mail" : "Separate account Inboxes") + "\nClick to check recent mail"
    Image {
      id: icon
      anchors.centerIn: parent
      width: Style.bar.iconCanvas
      height: Style.bar.iconCanvas
      readonly property real tightWidth: width
      source: Qt.resolvedUrl("assets/omagma-logo.png")
      sourceSize.width: 48
      sourceSize.height: 48
      fillMode: Image.PreserveAspectFit
      smooth: true
    }
    onPressed: root.togglePanel()
  }
  Component.onCompleted: Qt.callLater(root.pushSettings)
}
