import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import ".." as Gmail
import "../Model.mjs" as Model

// Independent fixture-only test window. Never installs a plugin, edits the
// desktop configuration, accesses Gmail, or launches Chrome.
ShellRoot {
  id: root
  property bool opened: false
  property int completedCycles: 0
  property int targetCycles: 0
  property int popupCreations: 0
  property int popupDestructions: 0
  property int maxRows: 0
  property int maxPending: 0
  property var savedSelection: ""
  function setOpen(value) {
    opened = value
    mailService.setVisible(value)
  }
  function state() {
    return JSON.stringify({ opened: opened, daemon: mailService.daemonState, selected: mailService.selected,
      accounts: mailService.accounts.map(a => ({ account: a.account, state: a.state, generation: a.generation,
        unread: a.unread, rows: a.messages.length })), retainedRows: mailService.retainedRows,
      pending: mailService.pendingCount, backendPid: mailService.daemonPid,
      cycles: completedCycles, target: targetCycles, creations: popupCreations,
      destructions: popupDestructions, contentAlive: !!content.item,
      maxRows: maxRows, maxPending: maxPending, error: mailService.lastError })
  }
  Gmail.Service {
    id: mailService
    onRetainedRowsChanged: root.maxRows = Math.max(root.maxRows, retainedRows)
    onPendingCountChanged: root.maxPending = Math.max(root.maxPending, pendingCount)
    Component.onCompleted: configure(Quickshell.env("OMAGMA_TEST_BINARY"), Quickshell.env("OMAGMA_TEST_CONFIG"), true, true)
  }
  PanelWindow {
    id: window
    WlrLayershell.namespace: "omagma-test-toolbar"
    WlrLayershell.layer: WlrLayer.Overlay
    anchors.top: true
    anchors.left: true
    margins.top: 50
    margins.left: 100
    exclusionMode: ExclusionMode.Ignore
    implicitWidth: 1030
    implicitHeight: 74
    color: "#151c26"
    visible: true
    Row {
      anchors.centerIn: parent
      spacing: 18
      MailButton {
        id: toggle
        text: root.opened ? "Close synthetic Inbox" : "Open synthetic Inbox"
        onClicked: root.setOpen(!root.opened)
      }
      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: "Fixture mode · no Gmail/keyring · Chrome opening disabled"
        textFormat: Text.PlainText
        color: "#a2adbd"
        font.pixelSize: 13
      }
    }
    PanelWindow {
      id: popup
      screen: window.screen
      WlrLayershell.namespace: "omagma-test-popup"
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: root.opened ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None
      anchors.top: true
      anchors.left: true
      margins.top: 130
      margins.left: 100
      exclusionMode: ExclusionMode.Ignore
      implicitWidth: 740
      implicitHeight: 440
      color: "#151c26"
      visible: root.opened
      // The real integration uses Omarchy KeyboardPanel outside dismissal.
      Loader {
        id: content
        anchors.fill: parent
        active: root.opened
        sourceComponent: Component {
          MailView {
            service: mailService
            onCloseRequested: root.setOpen(false)
            onLaunched: root.setOpen(false)
            Component.onCompleted: root.popupCreations += 1
            Component.onDestruction: root.popupDestructions += 1
          }
        }
      }
    }
  }
  Timer {
    id: soakTimer
    interval: 35
    repeat: true
    onTriggered: {
      if (root.opened) {
        root.setOpen(false)
        root.completedCycles += 1
        if (root.completedCycles >= root.targetCycles) stop()
      } else root.setOpen(true)
    }
  }
  IpcHandler {
    target: "omagma-test"
    function open(): void { root.setOpen(true) }
    function close(): void { root.setOpen(false) }
    function toggle(): void { root.setOpen(!root.opened) }
    function state(): string { return root.state() }
    function select(address: string): void { mailService.selectAccount(address) }
    function refresh(): void { mailService.refresh() }
    function restart(): void { mailService.restart() }
    function inbox(): void { mailService.openInbox() }
    function message(): void { if (mailService.currentAccount.messages.length) mailService.openMessage(mailService.currentAccount.messages[0].id) }
    function inject(line: string): void { mailService.handleLine(line) }
    function soak(count: int): void {
      root.setOpen(false)
      root.completedCycles = 0
      root.targetCycles = Math.max(1, Math.min(count, 10000))
      soakTimer.start()
    }
  }
}
