import QtQuick
import Quickshell
import Quickshell.Io

// Polls the adguard-cli user unit through a small helper script and runs
// systemctl actions. The panel only renders what lives here.
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

  readonly property string unit: String(setting("unit", "adguard-cli.service"))
  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 10, 3, 600)
  readonly property string helperPath: Qt.resolvedUrl("bin/adguard-state").toString().replace(/^file:\/\//, "")

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

  function refresh() {
    if (statusProcess.running) return
    statusProcess.command = ["bash", helperPath, unit]
    statusProcess.running = true
  }

  function runAction(args, label) {
    if (actionProcess.running) return
    actionStatus = label
    lastError = ""
    actionProcess.command = ["systemctl", "--user"].concat(args).concat([unit])
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

  function applyState(text) {
    var data
    try { data = JSON.parse(text) } catch (e) { lastError = "Could not read service state"; return }
    unitFound = data.unitFound === true
    activeState = String(data.active || "unknown")
    enabledState = String(data.enabled || "unknown")
    proxyRunning = data.proxyRunning === true
    httpAddress = String(data.http || "")
    socksAddress = String(data.socks || "")
    autoFiltering = String(data.autoFiltering || "")
    dnsFiltering = String(data.dnsFiltering || "")
    checked = true
    // Once reality matches what we asked for, go back to following it.
    if (_desiredActive !== -1 && running === (_desiredActive === 1)) _desiredActive = -1
    if (_desiredEnabled !== -1 && (enabledState === "enabled") === (_desiredEnabled === 1)) _desiredEnabled = -1
  }

  Process {
    id: statusProcess
    running: false
    command: []
    stdout: StdioCollector { id: statusOut; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0) root.applyState(String(statusOut.text || ""))
      else { root.checked = true; root.lastError = "State helper failed" }
    }
  }

  Process {
    id: actionProcess
    running: false
    command: []
    stderr: StdioCollector { id: actionErr; waitForEnd: true }
    onExited: function(exitCode) {
      root.actionStatus = ""
      if (exitCode !== 0) {
        root._desiredActive = -1
        root._desiredEnabled = -1
        var err = String(actionErr.text || "").trim()
        root.lastError = err !== "" ? err.split("\n")[0] : "systemctl failed"
      }
      // Give systemd a beat to settle before reading the state back.
      settleTimer.restart()
    }
  }

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
}
