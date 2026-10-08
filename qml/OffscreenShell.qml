import QtQuick
import Quickshell
import Quickshell.Io
import ".." as Gmail
import "../Model.mjs" as Model

// Offscreen fixture lifecycle test. QT_QPA_PLATFORM=offscreen is mandatory;
// no native surface is shown and no compositor input is requested.
ShellRoot {
  id: root
  readonly property bool offscreen: Quickshell.env("QT_QPA_PLATFORM") === "offscreen"
  readonly property real fontBase: Number(Quickshell.env("OMAGMA_TEST_FONT_BASE")) || 9
  readonly property real uiScale: fontBase / 12
  property bool opened: false
  property int completedCycles: 0
  property int targetCycles: 0
  property int popupCreations: 0
  property int popupDestructions: 0
  property int maxRows: 0
  property int maxPending: 0
  property int fixtureLoads: 0
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
      selectedMessageId: content.item ? content.item.selectedMessageId : "",
      layout: content.item ? content.item.layoutBounds() : null,
      maxRows: maxRows, maxPending: maxPending, fixtureLoads: fixtureLoads, error: mailService.lastError })
  }
  Gmail.Service {
    id: mailService
    onRetainedRowsChanged: root.maxRows = Math.max(root.maxRows, retainedRows)
    onPendingCountChanged: root.maxPending = Math.max(root.maxPending, pendingCount)
    Component.onCompleted: configure(Quickshell.env("OMAGMA_TEST_BINARY"), Quickshell.env("OMAGMA_TEST_CONFIG"), true, true)
  }
  // Large synthetic snapshots are loaded locally rather than passed through
  // the test IPC socket. This is not part of the installed plugin.
  FileView {
    id: fixtureInput
    printErrors: true
    onLoaded: { mailService.handleLine(text()); root.fixtureLoads += 1 }
  }
  FloatingWindow {
    id: testWindow
    title: "omagma offscreen fixture lifecycle test"
    implicitWidth: Math.round(740 * root.uiScale)
    implicitHeight: Math.round(440 * root.uiScale)
    color: "#151c26"
    visible: root.offscreen
    Loader {
      id: content
      anchors.fill: parent
      active: root.opened && root.offscreen
      sourceComponent: Component {
        MailView {
          service: mailService
          fontFamily: Quickshell.env("OMAGMA_TEST_FONT") || "monospace"
          bodyFontSize: Math.round(root.fontBase * 0.917)
          captionFontSize: Math.round(root.fontBase * 0.833)
          headingFontSize: root.fontBase
          layoutScale: root.uiScale
          onCloseRequested: root.setOpen(false)
          onLaunched: root.setOpen(false)
          Component.onCompleted: root.popupCreations += 1
          Component.onDestruction: root.popupDestructions += 1
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
    function tui(): void { if (content.item) content.item.tuiButton.clicked() }
    function message(): void { if (mailService.currentAccount.messages.length) mailService.openMessage(mailService.currentAccount.messages[0].id) }
    function selectMessage(id: string): void { if (content.item) content.item.selectedMessageId = id }
    function moveSelection(delta: int): void { if (content.item) content.item.moveSelection(delta) }
    function inject(line: string): void { mailService.handleLine(line) }
    function injectFile(path: string): void {
      if (fixtureInput.path === path) fixtureInput.reload()
      else fixtureInput.path = path
    }
    function capture(path: string): void {
      content.grabToImage(function(result) { result.saveToFile(path) })
    }
    function soak(count: int): void {
      root.setOpen(false)
      root.completedCycles = 0
      root.targetCycles = Math.max(1, Math.min(count, 10000))
      soakTimer.start()
    }
  }
}
