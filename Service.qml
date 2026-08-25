import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Model.js" as Model

// Process orchestration and state for the Proton VPN widget.
//
// Two tiers, because the two sources of truth cost 18x different amounts:
//
//   Fast (bin/protonvpn-probe, ~85ms)  NetworkManager + /sys + Proton's cache
//     file. Tunnel up/down, server name, addressing, DNS, routing, counters.
//     Cheap enough to poll continuously, which is what keeps the bar icon
//     honest between panel opens.
//
//   Slow (`protonvpn ...`, ~1.5s and occasionally much worse when it decides
//     to refresh its 24MB server list) Server load, city, settings, country
//     list. Only run when the panel is open or an action just finished.
//
// The bar icon never waits on the slow tier.
Item {
  id: root

  property var settings: ({})
  property bool panelOpen: false

  // --- Fast tier -------------------------------------------------------------
  property var info: ({})
  // Not named `state`: QQuickItem already has one, and shadowing it breaks
  // the QML state machine. The first-party panels sidestep this the same way
  // (the Network panel calls its equivalent `kind`).
  readonly property string tunnelState: Model.connectionState(info)
  readonly property bool connected: tunnelState === "protected" || tunnelState === "leaking"
  readonly property bool leaking: tunnelState === "leaking"
  readonly property string leakReason: Model.leakReason(info)
  readonly property string server: String(info.server || "")
  readonly property string iface: String(info.iface || "")

  // Optimistic state so the switch throws the instant it is clicked instead of
  // a second and a half later. -1 means "just follow the probe"; 0/1 mean a
  // toggle is still catching up. Same shape as the Tailscale service.
  property int _desired: -1
  readonly property bool active: _desired === -1 ? connected : (_desired === 1)

  // --- Slow tier -------------------------------------------------------------
  property string city: ""
  property string country: ""
  property int load: -1
  property string protocol: ""
  // The probe reads the protocol out of Proton's own session file, which is
  // instant, so the hero can name it on the first frame instead of waiting a
  // second and a half for `protonvpn status` to say the same thing.
  readonly property string protocolEffective: protocol !== "" ? protocol : String(info.protocol || "")
  property var config: ({})
  property var countries: []
  property bool installed: true
  property bool needsSignIn: false
  // True while the Proton VPN desktop app holds the CLI hostage. Polling keeps
  // running so the panel recovers on its own once the app is closed.
  property bool guiRunning: false

  // --- Action state ----------------------------------------------------------
  property string actionStatus: ""
  property string lastError: ""
  property string pendingSetting: ""
  property string pendingCountry: ""
  property string pendingQuick: ""

  readonly property bool connecting: connectProc.running || tunnelState === "connecting"
  readonly property bool busy: connectProc.running || disconnectProc.running
  readonly property bool settingBusy: settingProc.running

  // --- Throughput ------------------------------------------------------------
  property real prevRxBytes: 0
  property real prevTxBytes: 0
  property real prevSampleTime: 0
  property string prevIface: ""
  property real downloadRate: 0
  property real uploadRate: 0
  readonly property bool hasTransferStats: info.rx_bytes !== undefined

  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 5, 1, 60)
  readonly property int detailIntervalSec: intSetting("detailIntervalSec", 60, 15, 3600)

  // Absolute paths derived from this file's own location, so the plugin keeps
  // working if it is renamed or moved.
  readonly property string probePath: String(Qt.resolvedUrl("bin/protonvpn-probe")).replace(/^file:\/\//, "")
  readonly property string runPath: String(Qt.resolvedUrl("bin/protonvpn-run")).replace(/^file:\/\//, "")

  // Every process this file starts goes through bin/protonvpn-run, which caps
  // how many bytes of stdout and stderr can come back. StdioCollector has no
  // size limit of its own: it collects a process's output to completion and
  // then hands QML the lot, so an unbounded response would grow the shell
  // process for as long as the writer kept writing. The CLI's country list is
  // built from data Proton serves, which puts a remote party on the far end of
  // that. Capping in the wrapper drops the bytes before they are ever
  // collected here. An over-limit call comes back non-zero and is discarded,
  // which is what every reader below already does with a failed call.
  function capped(argv) {
    return ["bash", runPath].concat(argv)
  }

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    return Math.max(min, Math.min(max, n))
  }

  // --- Refresh ---------------------------------------------------------------

  function refresh() {
    if (probeProc.running) return
    probeProc.command = capped(["bash", probePath])
    probeProc.running = true
    if (!probeWatchdog.running) probeWatchdog.start()
  }

  // The slow tier, gated on the panel being open. `force` runs it anyway,
  // which is what an action's completion needs.
  function refreshDetails(force) {
    if (!panelOpen && force !== true) return

    if (!statusProc.running) {
      statusProc.command = capped(["protonvpn", "status"])
      statusProc.running = true
    }
    if (!configProc.running) {
      configProc.command = capped(["protonvpn", "config", "list"])
      configProc.running = true
    }
    // The country list does not change between releases, so fetch it once per
    // shell session rather than on every open.
    if (countries.length === 0 && !countriesProc.running) {
      countriesProc.command = capped(["protonvpn", "countries", "list"])
      countriesProc.running = true
    }
    if (!detailWatchdog.running) detailWatchdog.start()
  }

  function applyProbe(raw) {
    var next = Model.parseKeyValue(raw)
    info = next
    updateThroughput(next)

    // Once the probe agrees with what was asked for, stop overriding it.
    if (_desired === 1 && connected) _desired = -1
    else if (_desired === 0 && !connected) _desired = -1
  }

  function updateThroughput(next) {
    var s = Model.throughputState({
      prevIface: prevIface,
      prevRxBytes: prevRxBytes,
      prevTxBytes: prevTxBytes,
      prevSampleTime: prevSampleTime,
      downloadRate: downloadRate,
      uploadRate: uploadRate
    }, next, Date.now() / 1000)

    prevIface = s.prevIface
    prevRxBytes = s.prevRxBytes
    prevTxBytes = s.prevTxBytes
    prevSampleTime = s.prevSampleTime
    downloadRate = s.downloadRate
    uploadRate = s.uploadRate
  }

  function resetThroughput() {
    prevSampleTime = 0
    downloadRate = 0
    uploadRate = 0
  }

  // --- Actions ---------------------------------------------------------------

  function toggle() {
    if (busy) return
    if (active) disconnect()
    else quickConnect("fastest")
  }

  function quickConnect(id) {
    if (busy) return

    var options = Model.quickConnectOptions()
    var chosen = null
    for (var i = 0; i < options.length; i++) {
      if (options[i].id === id) { chosen = options[i]; break }
    }
    if (!chosen) return

    pendingQuick = id
    pendingCountry = ""
    startConnect(["protonvpn", "connect"].concat(chosen.args), "Connecting to " + chosen.label.toLowerCase() + "…")
  }

  function connectCountry(code, name) {
    if (busy || !code) return
    pendingCountry = code
    pendingQuick = ""
    startConnect(["protonvpn", "connect", "--country", code], "Connecting to " + (name || code) + "…")
  }

  function connectServer(name) {
    if (busy || !name) return
    pendingCountry = ""
    pendingQuick = ""
    startConnect(["protonvpn", "connect", name], "Connecting to " + name + "…")
  }

  function startConnect(command, message) {
    _desired = 1
    lastError = ""
    needsSignIn = false
    actionStatus = message
    connectProc.command = capped(command)
    connectProc.running = true
    connectWatchdog.restart()
  }

  function disconnect() {
    if (busy) return
    _desired = 0
    lastError = ""
    actionStatus = "Disconnecting…"
    disconnectProc.command = capped(["protonvpn", "disconnect"])
    disconnectProc.running = true
    connectWatchdog.restart()
  }

  function applySetting(key, value) {
    if (settingProc.running || !key || !value) return
    pendingSetting = key
    lastError = ""
    settingProc.command = capped(["protonvpn", "config", "set", key, value])
    settingProc.running = true
    settingWatchdog.restart()
  }

  // Signing in is an interactive credential prompt, so it belongs in a real
  // terminal rather than behind a bar popup. Omarchy already has a wrapper
  // that puts one on screen with the right window rules.
  function signIn() {
    Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation", "protonvpn", "signin"])
    actionStatus = "Sign in from the terminal window"
    actionStatusTimer.restart()
  }

  function openAccount() {
    Quickshell.execDetached(["omarchy-launch-browser", "https://account.protonvpn.com"])
  }

  // Returns true when the output was a GUI conflict, so callers can stop
  // treating it as their own specific failure.
  function noteGuiConflict(stdout, stderr) {
    var combined = String(stdout || "") + "\n" + String(stderr || "")
    if (!Model.guiConflict(combined)) return false
    guiRunning = true
    lastError = ""
    actionStatus = ""
    return true
  }

  function noteFailure(stdout, stderr, fallback) {
    var combined = String(stderr || "") + "\n" + String(stdout || "")
    if (noteGuiConflict(stdout, stderr)) return
    if (Model.needsSignIn(combined)) {
      needsSignIn = true
      lastError = "Not signed in to Proton VPN"
    } else {
      lastError = Model.failureMessage(stdout, stderr, fallback)
    }
    actionStatus = ""
  }

  // --- Timers ----------------------------------------------------------------

  Timer {
    // The bar icon polls whether or not anyone is looking at the panel: it is
    // the thing claiming you are protected, so it has to keep earning that.
    // The probe is cheap enough (~85ms of nmcli) to run at this rate.
    id: probeTimer
    interval: root.refreshIntervalSec * 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    id: detailTimer
    interval: root.detailIntervalSec * 1000
    repeat: true
    running: root.panelOpen
    onTriggered: root.refreshDetails()
  }

  Timer {
    // Re-probe promptly after an action, before the periodic tick would.
    id: settleTimer
    interval: 700
    repeat: false
    onTriggered: { root.refresh(); root.refreshDetails(true) }
  }

  Timer {
    id: actionStatusTimer
    interval: 3000
    repeat: false
    onTriggered: root.actionStatus = ""
  }

  Timer {
    // A poll is skipped while its own process is still running, so one that
    // never exits stops the panel refreshing at all, permanently. Reap
    // anything still alive well inside the next tick.
    id: probeWatchdog
    interval: 4000
    repeat: false
    onTriggered: if (probeProc.running) probeProc.running = false
  }

  Timer {
    // The CLI can sit for a long time refreshing its server list. Give it far
    // longer than the probe, but not forever.
    id: detailWatchdog
    interval: 30000
    repeat: false
    onTriggered: {
      if (statusProc.running) statusProc.running = false
      if (configProc.running) configProc.running = false
      if (countriesProc.running) countriesProc.running = false
    }
  }

  Timer {
    // Connecting genuinely takes seconds. If it takes a minute something is
    // wrong, and leaving the switch spinning forever is worse than saying so.
    id: connectWatchdog
    interval: 60000
    repeat: false
    onTriggered: {
      if (connectProc.running) connectProc.running = false
      if (disconnectProc.running) disconnectProc.running = false
      root._desired = -1
      root.actionStatus = ""
      root.lastError = "Proton VPN did not respond"
    }
  }

  Timer {
    id: settingWatchdog
    interval: 20000
    repeat: false
    onTriggered: {
      if (settingProc.running) settingProc.running = false
      root.pendingSetting = ""
    }
  }

  onPanelOpenChanged: {
    if (panelOpen) {
      refresh()
      refreshDetails(true)
    } else {
      resetThroughput()
    }
  }

  // --- Processes -------------------------------------------------------------

  Process {
    id: probeProc
    running: false
    command: []
    stdout: StdioCollector { id: probeOut; waitForEnd: true }
    onExited: function(exitCode) {
      probeWatchdog.stop()
      if (exitCode === 0) root.applyProbe(String(probeOut.text || ""))
    }
  }

  Process {
    id: statusProc
    running: false
    command: []
    stdout: StdioCollector { id: statusOut; waitForEnd: true }
    stderr: StdioCollector { id: statusErr; waitForEnd: true }
    onExited: function(exitCode) {
      var out = String(statusOut.text || "")
      var err = String(statusErr.text || "")

      // Exit code 127 is the shell saying the binary is not there. Anything
      // else non-zero is the CLI itself complaining, which is a different
      // problem and must not blank the panel into "not installed".
      if (exitCode === 127) { root.installed = false; return }
      root.installed = true

      if (root.noteGuiConflict(out, err)) return
      root.guiRunning = false

      if (Model.needsSignIn(out + "\n" + err)) {
        root.needsSignIn = true
        return
      }
      root.needsSignIn = false

      var parsed = Model.parseStatus(out)
      root.city = parsed.city
      root.country = parsed.country
      root.load = parsed.load
      root.protocol = parsed.protocol
    }
  }

  Process {
    id: configProc
    running: false
    command: []
    stdout: StdioCollector { id: configOut; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) return
      var parsed = Model.parseConfig(String(configOut.text || ""))
      // An empty parse means the output shape changed. Keeping the last good
      // config beats rendering every toggle as off, which would invite the
      // user to "fix" settings that were never wrong.
      if (Object.keys(parsed).length > 0) root.config = parsed
    }
  }

  Process {
    id: countriesProc
    running: false
    command: []
    stdout: StdioCollector { id: countriesOut; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) return
      var parsed = Model.parseCountries(String(countriesOut.text || ""))
      if (parsed.length > 0) root.countries = parsed
    }
  }

  Process {
    id: connectProc
    running: false
    command: []
    stdout: StdioCollector { id: connectOut; waitForEnd: true }
    stderr: StdioCollector { id: connectErr; waitForEnd: true }
    onExited: function(exitCode) {
      connectWatchdog.stop()
      root.pendingQuick = ""
      root.pendingCountry = ""

      if (exitCode !== 0) {
        root._desired = -1
        root.noteFailure(String(connectOut.text || ""), String(connectErr.text || ""), "Could not connect")
      } else {
        root.actionStatus = ""
        root.lastError = ""
      }
      settleTimer.restart()
    }
  }

  Process {
    id: disconnectProc
    running: false
    command: []
    stdout: StdioCollector { id: disconnectOut; waitForEnd: true }
    stderr: StdioCollector { id: disconnectErr; waitForEnd: true }
    onExited: function(exitCode) {
      connectWatchdog.stop()
      if (exitCode !== 0) {
        root._desired = -1
        root.noteFailure(String(disconnectOut.text || ""), String(disconnectErr.text || ""), "Could not disconnect")
      } else {
        root.actionStatus = ""
        root.lastError = ""
      }
      settleTimer.restart()
    }
  }

  Process {
    id: settingProc
    running: false
    command: []
    stdout: StdioCollector { id: settingOut; waitForEnd: true }
    stderr: StdioCollector { id: settingErr; waitForEnd: true }
    onExited: function(exitCode) {
      settingWatchdog.stop()
      root.pendingSetting = ""

      if (exitCode !== 0) {
        root.noteFailure(String(settingOut.text || ""), String(settingErr.text || ""), "Could not change setting")
        actionStatusTimer.restart()
      }
      // Re-read rather than assuming the write took: some settings only apply
      // on the next connection, and the CLI is the authority on what stuck.
      if (!configProc.running) {
        configProc.command = root.capped(["protonvpn", "config", "list"])
        configProc.running = true
      }
    }
  }
}
