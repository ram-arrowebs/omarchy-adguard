import QtQuick
import Quickshell
import Quickshell.Io

// Polls the adguard-cli user unit through a small helper script and runs
// systemctl actions. The panel only renders what lives here.
//
// Both child processes use fixed executable paths, argv arrays, a byte budget
// on what they may print, and a TERM-then-KILL stop if they outlive their
// deadline. Nothing here needs more than the user's own session.
Item {
  id: root

  property var settings: ({})

  property bool unitFound: false
  property string activeState: "unknown"     // active | inactive | failed | activating | ...
  property string enabledState: "unknown"    // enabled | disabled | ...
  property bool proxyRunning: false
  property string httpAddress: ""
  property string socksAddress: ""
  property string autoFiltering: ""
  property string dnsFiltering: ""
  property bool checked: false               // first poll completed
  property string lastError: ""
  property string actionStatus: ""

  // Optimistic state so the switches throw the instant you click them;
  // -1 means "follow the real state", 0/1 while an action is in flight.
  property int _desiredActive: -1
  property int _desiredEnabled: -1

  readonly property bool running: activeState === "active" || activeState === "activating"
  readonly property bool failed: activeState === "failed"
  readonly property bool active: _desiredActive === -1 ? running : (_desiredActive === 1)
  readonly property bool startsAtBoot: _desiredEnabled === -1 ? (enabledState === "enabled") : (_desiredEnabled === 1)
  readonly property bool busy: statusProcess.running || actionProcess.running

  // A unit name is letters, digits and a few separators ending in .service,
  // never option-shaped. Anything else falls back to the default.
  readonly property string unit: {
    var value = String(setting("unit", "adguard-cli.service"))
    return /^[A-Za-z0-9][A-Za-z0-9_.@:-]{0,63}\.service$/.test(value) ? value : "adguard-cli.service"
  }
  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 10, 3, 600)
  readonly property string helperPath: Qt.resolvedUrl("bin/adguard-state").toString().replace(/^file:\/\//, "")

  // Byte budgets for what the children may print. The helper caps its own
  // output; these are defense in depth for the QML side.
  readonly property int maxStatusBytes: 4096
  readonly property int maxErrorBytes: 1024
  property string _statusBuffer: ""
  property string _errorBuffer: ""

  readonly property string statusText: {
    if (!checked) return "Checking…"
    if (!unitFound) return "Service not installed"
    if (failed) return "Service failed"
    if (active && proxyRunning) return "Blocking ads"
    if (active) return "Starting proxy…"
    return "Proxy stopped"
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

  // Strips markup and control characters and caps the length, for strings
  // that end up in a Text the panel renders.
  function plain(text, max) {
    var s = String(text || "").replace(/[<>&\u0000-\u001f\u007f-\u009f‎‏‪-‮⁦-⁩]/g, "")
    return s.length > max ? s.slice(0, max) : s
  }

  function refresh() {
    if (statusProcess.running) return
    _statusBuffer = ""
    statusProcess.command = ["/usr/bin/bash", helperPath, unit]
    statusProcess.running = true
  }

  function runAction(args, label) {
    if (actionProcess.running) return
    actionStatus = label
    lastError = ""
    _errorBuffer = ""
    actionProcess.command = ["/usr/bin/systemctl", "--user"].concat(args).concat(["--", unit])
    actionProcess.running = true
  }

  function start() { _desiredActive = 1; runAction(["start"], "Starting…") }
  function stop() { _desiredActive = 0; runAction(["stop"], "Stopping…") }
  function restart() { _desiredActive = 1; runAction(["restart"], "Restarting…") }
  function toggleService() { active ? stop() : start() }

  // `disable` without --now: the proxy keeps running for this session and
  // simply does not come back on the next boot. `enable` is the inverse.
  function enableAtBoot() { _desiredEnabled = 1; runAction(["enable"], "Enabling at boot…") }
  function disableAtBoot() { _desiredEnabled = 0; runAction(["disable"], "Disabling at boot…") }
  function toggleBoot() { startsAtBoot ? disableAtBoot() : enableAtBoot() }

  // One flat object of short strings and booleans; anything else is rejected
  // whole rather than partially applied.
  function word(value, allowed) {
    var s = String(value)
    return allowed.indexOf(s) >= 0 ? s : "unknown"
  }
  function address(value) {
    var s = String(value || "")
    return /^[\[\]0-9A-Fa-f.:]{1,45}:[0-9]{1,5}$/.test(s) ? s : ""
  }
  function onOff(value) {
    var s = String(value || "")
    return (s === "enabled" || s === "disabled") ? s : ""
  }

  function applyState(text) {
    var data
    try { data = JSON.parse(text) } catch (e) { checked = true; lastError = "Could not read service state"; return }
    if (!data || typeof data !== "object" || Array.isArray(data)) { checked = true; lastError = "Could not read service state"; return }
    unitFound = data.unitFound === true
    activeState = word(data.active, ["active", "inactive", "failed", "activating", "deactivating", "reloading"])
    enabledState = word(data.enabled, ["enabled", "disabled", "static", "masked", "linked", "not-found", "alias", "indirect", "generated", "transient", "enabled-runtime"])
    proxyRunning = data.proxyRunning === true
    httpAddress = address(data.http)
    socksAddress = address(data.socks)
    autoFiltering = onOff(data.autoFiltering)
    dnsFiltering = onOff(data.dnsFiltering)
    checked = true
    // Once reality matches what we asked for, go back to following it.
    if (_desiredActive !== -1 && running === (_desiredActive === 1)) _desiredActive = -1
    if (_desiredEnabled !== -1 && (enabledState === "enabled") === (_desiredEnabled === 1)) _desiredEnabled = -1
  }

  function overflow(proc, timer) {
    proc.signal(15)
    timer.restart()
  }

  Process {
    id: statusProcess
    running: false
    command: []
    stdout: SplitParser {
      splitMarker: ""
      onRead: function(chunk) {
        root._statusBuffer += chunk
        if (root._statusBuffer.length > root.maxStatusBytes) {
          root._statusBuffer = ""
          root.overflow(statusProcess, statusKill)
        }
      }
    }
    onStarted: statusDeadline.restart()
    onExited: function(exitCode) {
      statusDeadline.stop(); statusKill.stop()
      if (exitCode === 0 && root._statusBuffer !== "") root.applyState(root._statusBuffer)
      else { root.checked = true; root.lastError = "State helper failed" }
      root._statusBuffer = ""
    }
  }
  // The helper has its own 10s deadline per child; this is the outer bound.
  Timer { id: statusDeadline; interval: 30000; onTriggered: root.overflow(statusProcess, statusKill) }
  Timer { id: statusKill; interval: 2000; onTriggered: statusProcess.signal(9) }

  Process {
    id: actionProcess
    running: false
    command: []
    stderr: SplitParser {
      splitMarker: ""
      onRead: function(chunk) {
        root._errorBuffer += chunk
        if (root._errorBuffer.length > root.maxErrorBytes) {
          root._errorBuffer = root._errorBuffer.slice(0, root.maxErrorBytes)
          root.overflow(actionProcess, actionKill)
        }
      }
    }
    onStarted: actionDeadline.restart()
    onExited: function(exitCode) {
      actionDeadline.stop(); actionKill.stop()
      root.actionStatus = ""
      if (exitCode !== 0) {
        root._desiredActive = -1
        root._desiredEnabled = -1
        var firstLine = String(root._errorBuffer).trim().split("\n")[0]
        root.lastError = firstLine !== "" ? root.plain(firstLine, 160) : "systemctl failed"
      }
      root._errorBuffer = ""
      // Give systemd a beat to settle before reading the state back.
      settleTimer.restart()
    }
  }
  Timer { id: actionDeadline; interval: 30000; onTriggered: root.overflow(actionProcess, actionKill) }
  Timer { id: actionKill; interval: 2000; onTriggered: actionProcess.signal(9) }

  Timer {
    id: settleTimer
    interval: 700
    repeat: false
    onTriggered: root.refresh()
  }

  Timer {
    interval: root.refreshIntervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Component.onDestruction: {
    if (statusProcess.running) statusProcess.signal(15)
    if (actionProcess.running) actionProcess.signal(15)
  }
}
