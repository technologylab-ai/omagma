import QtQuick
import Quickshell
import Quickshell.Io
import "Model.mjs" as Model

// One bounded current snapshot per account. Requests carry no mail data and
// never retain view callbacks; the short request ledger expires on timeout.
Item {
  id: root
  property var shell: null
  property var manifest: null
  property string daemonPath: ""
  property string configPath: ""
  property bool fixtures: false
  property bool dryRunOpen: false
  property bool configured: false
  property string daemonState: "stopped"
  property string lastError: ""
  property var accounts: Model.emptyAccounts()
  property string selected: ""
  property bool popupOpen: false
  property var nextId: 1
  // Numeric properties on QV4 objects use indexed backing storage. Keeping
  // request IDs as values in at most 64 stable-shape records prevents that
  // storage from expanding with request history.
  property var pending: []
  readonly property int pendingCount: pending.length
  property bool restarting: false
  readonly property var currentAccount: Model.selectedAccount(accounts, selected)
  readonly property var daemonPid: daemon.processId
  readonly property int retainedRows: accounts.reduce((sum, a) => sum + a.messages.length, 0)
  signal openCompleted(bool success)

  function pluginPath(relative) {
    return decodeURIComponent(String(Qt.resolvedUrl(relative)).replace(/^file:\/\//, ""))
  }

  function configure(binary, config, fixtureMode, dryMode) {
    const changed = !configured || daemonPath !== String(binary || "") || configPath !== String(config || "")
      || fixtures !== (fixtureMode === true) || dryRunOpen !== (dryMode === true)
    daemonPath = String(binary || "")
    configPath = String(config || "")
    fixtures = fixtureMode === true
    dryRunOpen = dryMode === true
    configured = true
    if (changed) restart()
  }

  function clearRequests() { pending = [] }
  function markStopped() {
    accounts = accounts.map(function(a) {
      return Object.assign({}, a, { state: a.messages.length ? "stale" : "unavailable",
        error: "Backend unavailable" })
    })
  }

  function start() {
    if (!configured || daemon.running) return
    clearRequests()
    accounts = Model.emptyAccounts() // restart has no valid cache
    daemonState = "starting"
    lastError = ""
    daemon.command = Model.daemonArgv(daemonPath || pluginPath("zig-out/bin/omagma"),
      configPath, fixtures, dryRunOpen)
    daemon.running = true
    startDeadline.restart()
  }

  function restart() {
    clearRequests()
    if (daemon.running) {
      restarting = true
      daemon.running = false
    } else start()
  }

  function request(cmd, fields) {
    if (!daemon.running || (daemonState !== "ready" && cmd !== "hello")) return false
    if (pendingCount >= Model.MAX_PENDING) { lastError = "Too many outstanding requests"; return false }
    if (nextId >= Number.MAX_SAFE_INTEGER) nextId = 1
    const id = nextId++
    const requests = pending.slice()
    requests.push({ id: id, cmd: cmd, account: fields ? fields.account : "", deadline: Date.now() + 35000 })
    pending = requests
    daemon.write(Model.requestLine(id, cmd, fields))
    return true
  }

  function handleLine(line) {
    const msg = Model.parseLine(line)
    if (!msg) { lastError = "Invalid backend frame"; return }
    if (msg.re !== undefined) {
      const entry = pending.find(entry => entry.id === msg.re)
      if (!entry) return
      pending = pending.filter(entry => entry.id !== msg.re)
      if (msg.ok !== true) {
        lastError = Model.displayText(msg.error || "Request failed", 256)
        if (entry.cmd === "hello") { daemonState = "failed"; daemon.running = false }
        if (entry.cmd === "open") openCompleted(false)
        return
      }
      if (entry.cmd === "hello") {
        const next = msg.version === 1 ? Model.handshakeAccounts(msg.accounts) : null
        if (!next) { lastError = "Unsupported backend handshake"; daemonState = "failed"; daemon.running = false; return }
        accounts = next
        selected = Model.initialAccount(accounts, selected)
        daemonState = "ready"
        startDeadline.stop()
        if (popupOpen) request("visibility", { open: true, account: selected })
      }
      if (entry.cmd === "open") openCompleted(true)
      return
    }
    if (msg.ev === "snapshot") {
      const next = Model.replaceSnapshot(accounts, msg)
      if (next) accounts = next
      else lastError = "Invalid account snapshot"
    }
    if (msg.ev === "error") {
      clearRequests()
      lastError = Model.displayText(msg.error || "Backend request window exceeded", 256)
      if (daemonState === "ready") request("hello", {})
    }
  }

  function setVisible(open) {
    popupOpen = open === true
    if (popupOpen && !daemon.running) { start(); return }
    if (daemonState === "ready") request("visibility", { open: popupOpen, account: selected })
  }

  function selectAccount(address) {
    if (!accounts.some(account => account.account === address)) return
    selected = address
    if (daemonState === "ready") request("select", { account: selected })
  }

  function refresh() {
    if (!popupOpen) return
    if (!daemon.running) { start(); return }
    if (currentAccount.state === "loading") return
    lastError = ""
    request("refresh", { account: selected })
  }

  function openInbox() { request("open", { account: selected, kind: "inbox" }) }
  function openTui() {
    // Terminal access uses its own configured authorization. Keep the bar's
    // read-only daemon and credentials separate from the terminal process.
    if (!dryRunOpen)
      Quickshell.execDetached(Model.tuiArgv(daemonPath || pluginPath("zig-out/bin/omagma"), selected, fixtures))
    openCompleted(true)
  }
  function openMessage(id) {
    if (fixtures && !dryRunOpen) {
      lastError = "Demo messages are synthetic. Open inbox to view this account in Gmail."
      return
    }
    if (currentAccount.messages.some(row => row.id === id))
      request("open", { account: selected, kind: "message", message: id })
  }

  Process {
    id: daemon
    running: false
    stdinEnabled: true
    stdout: SplitParser { onRead: function(line) { root.handleLine(line) } }
    // Diagnostics are deliberately discarded: mail and credentials must not
    // enter UI logs, including after unexpected child failures.
    onStarted: root.request("hello", {})
    onExited: function(exitCode) {
      root.clearRequests()
      startDeadline.stop()
      if (root.restarting) {
        root.restarting = false
        Qt.callLater(root.start)
        return
      }
      root.daemonState = "stopped"
      if (!root.lastError) root.lastError = "Backend stopped (" + exitCode + ")"
      root.markStopped()
    }
  }

  Timer {
    id: startDeadline
    interval: 5000
    onTriggered: {
      if (root.daemonState !== "starting") return
      root.lastError = "Backend did not start. Build omagma or check the configured binary path."
      root.daemonState = "failed"
      daemon.running = false
      root.clearRequests()
      root.markStopped()
    }
  }

  // This only expires request metadata. It never schedules mail work and is
  // stopped whenever there are no requests, including quiet closed popups.
  Timer {
    interval: 1000
    repeat: true
    running: root.pendingCount > 0
    onTriggered: {
      const now = Date.now()
      const requests = root.pending.filter(entry => entry.deadline > now)
      if (requests.length !== root.pendingCount) root.lastError = "Backend request timed out"
      root.pending = requests
    }
  }
  Component.onDestruction: {
    startDeadline.stop()
    clearRequests()
    daemon.running = false
  }
}
