import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "tymurbogach.battery"
  ipcTarget: "tymurbogach.battery"
  // manageIpc: false so this panel can own the single IpcHandler the target
  // permits — needed for the togglePercentage method below.
  manageIpc: false
  property var batteryInfo: ({})
  property var systemInfo: ({})
  property var profiles: []
  property string activeProfile: ""
  property int profileIndex: 0
  property bool cursorActive: false
  readonly property bool showPercentage: setting("showPercentage", false) === true
  // With the percentage shown the button paints a text block wider than an
  // icon, so the open-panel mark takes the painted width instead of the
  // icon-sized fraction of the slot the fallback assumes.
  readonly property real openPanelIndicatorWidth: showPercentage && !button.vertical ? button.glyphPaintedWidth : 0

  // ---- Ownership note. This widget owns per-source profile restore
  // (sysfs signal) and per-profile Hz apply (direct hyprctl, no daemon).
  // The override file is the shared contract with the future display
  // plugin: single desired rate, both sides write file plus hz_<profile>
  // and watch the file. No ~/.local/bin daemon required.
  property bool chargeThresholdEnabled: false
  property string chargeThresholdError: ""
  // False until the first successful D-Bus read lands. The toggle stays
  // disabled meanwhile so it never flashes a wrong off state.
  property bool chargeThresholdKnown: false
  property string batteryDbusPath: ""
  property var drainSamples: []
  property var currentMonitor: null
  // The Hz writer accepts the latest request while a previous write runs.
  // It never claims that a queued value reached disk before it actually did.
  property var requestedHz: null
  property var inFlightHz: null
  property var appliedHz: null
  property int hzRevision: 0
  property string pendingProfile: ""
  // Coalesced monitor read: set when a refresh arrives while hyprctl runs.
  property bool monitorDirty: false
  // Catch-up burst after open/event/apply: 0 idle, 1..2 pending retries.
  property int catchUpStep: 0
  // Rate waiting for monitor geometry before direct apply can run.
  property var pendingHzApply: null
  // Lid-closed flag: never force eDP-1 while set or while eDP-1 is off.
  property bool internalMonitorDisabled: false

  // Keep command health independent. A successful system query must not hide
  // a failed battery or profile query from the user.
  property var refreshAttempts: ({ battery: 0, profiles: 0, system: 0, monitor: 0 })
  property var refreshHealth: ({
    battery: ({ failures: 0, error: "", failedAttempt: 0 }),
    profiles: ({ failures: 0, error: "", failedAttempt: 0 }),
    system: ({ failures: 0, error: "", failedAttempt: 0 }),
    monitor: ({ failures: 0, error: "", failedAttempt: 0 })
  })
  readonly property bool dataStale: refreshHealth.battery.failures >= 2
    || refreshHealth.profiles.failures >= 2
  readonly property string staleError: refreshHealth.battery.failures >= 2
    ? refreshHealth.battery.error : refreshHealth.profiles.error
  property string lastError: ""
  property string sourceError: ""
  property bool profileBusy: false

  // Guarded bar theme access. bar is null during startup/recreation;
  // content must not throw TypeError in that window.
  readonly property color fg: root.bar ? root.bar.foreground : Color.foreground
  readonly property string ff: root.bar ? root.bar.fontFamily : Style.font.family

  // Sysfs truth for the AC/battery source. UPower's OnBattery can freeze
  // (stale line_power_AC); omarchy-power-present reads sysfs directly.
  // "ac" | "battery" | "" (unknown until the first probe lands).
  property string acSource: ""
  readonly property bool sourceConflict: Model.sourceConflict(root.acSource, root.discharging)

  readonly property bool batteryPresent: {
    var device = UPower.displayDevice
    return !!(device && device.isPresent)
  }

  function upowerStates() {
    return {
      Charging: UPowerDeviceState.Charging,
      Discharging: UPowerDeviceState.Discharging,
      FullyCharged: UPowerDeviceState.FullyCharged,
      PendingCharge: UPowerDeviceState.PendingCharge
    }
  }

  function selectProfileByDelta(delta) {
    profileIndex = Model.selectProfileIndex(profileIndex, delta, profiles)
  }

  function activateSelectedProfile() {
    if (profileIndex < 0 || profileIndex >= profiles.length) return
    setProfile(profiles[profileIndex])
  }

  function batteryIcon() {
    var device = UPower.displayDevice
    return Model.batteryIcon(device, root.effectiveOnBattery, upowerStates())
  }

  function modeLabel() {
    var device = UPower.displayDevice
    return Model.modeLabel(device, root.effectiveOnBattery, upowerStates())
  }

  function profileIcon(name) {
    return Model.profileIcon(name)
  }

  readonly property bool fullyCharged: {
    var device = UPower.displayDevice
    return device && device.isPresent && !root.effectiveOnBattery
      && device.state === UPowerDeviceState.FullyCharged && !root.chargeThresholdActive
  }
  readonly property bool discharging: {
    var device = UPower.displayDevice
    return !!(device && device.isPresent && UPower.onBattery)
  }
  readonly property bool effectiveOnBattery: sourceKey() === "battery"
  readonly property bool chargeThresholdActive: {
    var device = UPower.displayDevice
    return Model.chargeThresholdActive(device, root.effectiveOnBattery, upowerStates())
  }
  readonly property bool batteryFull: fullyCharged || (!root.effectiveOnBattery && batteryFraction >= 1)
  readonly property bool batteryFlowIdle: batteryFull || chargeThresholdActive

  // 0..1 charge level, used by the visual progress bar.
  readonly property real batteryFraction: {
    var d = UPower.displayDevice
    return Model.batteryFraction(d)
  }

  readonly property bool charging: {
    var d = UPower.displayDevice
    return d && d.isPresent && !root.effectiveOnBattery && !root.batteryFlowIdle
  }

  readonly property color batteryFillColor: {
    return root.fg
  }

  // Source helpers: "ac" = powerON (plugged), "battery" = powerOFF.
  // Prefer the sysfs probe when known; UPower OnBattery can freeze.
  function sourceKey() {
    return Model.effectiveSource(root.acSource, root.discharging ? "battery" : "ac")
  }

  function sourceLabel() {
    var key = root.sourceKey()
    return key === "battery" ? "ON BATTERY" : "ON AC"
  }

  function updateSettings(patch) {
    root.settings = Object.assign({}, root.settings, patch)
    if (root.bar && root.bar.shell) root.bar.shell.updateEntryInline(root.moduleName, root.settings)
  }

  readonly property string buttonTooltip: {
    if (!batteryPresent) return ""
    var pctText = root.batteryInfo.percentage
    if (!pctText) {
      var f = root.batteryFraction
      pctText = isFinite(f) ? Math.round(f * 100) + "%" : "—"
    }
    var src = root.sourceKey() === "battery" ? "Battery" : "AC"
    var extra = root.batteryInfo.time ? " · " + root.batteryInfo.time : ""
    var stale = root.dataStale ? " (stale)" : ""
    return src + " · " + pctText + extra + stale
  }

  // Cute agent-flavored phrases shown in the hero status line, rotated on a
  // timer so the panel feels alive when current is flowing (either direction).
  readonly property var chargingPhrases: [
    "Pumping power",
    "Injecting electrons",
    "Pouring juice",
    "Amassing watts",
    "Hoarding joules",
    "Sucking volts",
    "Topping reserves",
    "Soaking amps",
    "Inhaling kilowatts"
  ]
  readonly property var onBatteryPhrases: [
    "Slurping power",
    "Spending joules",
    "Draining watts",
    "Burning electrons",
    "Sipping juice",
    "Spending coulombs",
    "Bleeding amps",
    "Guzzling volts",
    "Munching reserves"
  ]
  property int phraseIndex: 0

  // Whichever list is "active" given the current power state.
  readonly property var activePhrases: {
    if (fullyCharged) return []
    if (charging) return chargingPhrases
    if (effectiveOnBattery) return onBatteryPhrases
    return []
  }
  readonly property bool rotatingPhrases: activePhrases.length > 0

  readonly property string heroStatusText: {
    if (fullyCharged) return "Fully charged"
    if (rotatingPhrases) return activePhrases[phraseIndex % activePhrases.length]
    return modeLabel()
  }

  function refresh() {
    if (!batteryPresent) return
    stallTimer.restart()
    startRefresh("battery", batteryProc)
    startRefresh("profiles", profilesProc)
    startRefresh("system", systemProc)
  }

  function startRefresh(name, process) {
    if (process.running) {
      // Coalesce instead of dropping: a monitor request that lands while
      // hyprctl runs relaunches once on exit. Other subsystems keep the
      // old drop behavior through their own guards.
      if (name === "monitor") root.monitorDirty = true
      return
    }
    var next = Object.assign({}, refreshAttempts)
    next[name] = (next[name] || 0) + 1
    refreshAttempts = next
    process.running = true
  }

  function noteRefreshSuccess(name) {
    var state = refreshHealth[name] || ({ failures: 0, error: "", failedAttempt: 0 })
    var next = Object.assign({}, refreshHealth)
    next[name] = ({ failures: 0, error: "", failedAttempt: state.failedAttempt })
    refreshHealth = next
  }

  function noteRefreshFailure(name, msg) {
    var attempt = refreshAttempts[name] || 0
    var state = refreshHealth[name] || ({ failures: 0, error: "", failedAttempt: 0 })
    if (state.failedAttempt === attempt) return
    var next = Object.assign({}, refreshHealth)
    next[name] = ({
      failures: Math.min(99, state.failures + 1),
      error: msg || state.error || "refresh failed",
      failedAttempt: attempt
    })
    refreshHealth = next
  }

  function updateKeyValue(raw, targetName) {
    var next = Model.parseKeyValue(raw)
    // Keep last known good data if a refresh briefly returns nothing — happens
    // around AC plug/unplug events. Avoids the section collapsing mid-transition.
    // After consecutive failures mark stale instead of trusting old data forever.
    if (Object.keys(next).length === 0) {
      root.noteRefreshFailure(targetName, targetName + " empty")
      return
    }
    root.noteRefreshSuccess(targetName)
    if (targetName === "battery") {
      batteryInfo = next
      root.recordDrainSample()
      root.refreshChargeThreshold()
    } else {
      systemInfo = next
    }
  }

  function updateProfiles(raw) {
    var parsed = Model.parseProfiles(raw, profileIndex)
    // Same guard as battery: preserve the last known profile list across
    // transient empty payloads so the buttons don't blink out.
    if (parsed.profiles.length === 0) {
      root.noteRefreshFailure("profiles", "profiles empty")
      return
    }
    root.noteRefreshSuccess("profiles")
    profiles = parsed.profiles
    activeProfile = parsed.activeProfile
    profileIndex = parsed.profileIndex
    if (opened && !cursorActive) {
      var idx = profiles.indexOf(activeProfile)
      if (idx >= 0) profileIndex = idx
    }
    // Enforce the per-profile Hz invariant when the active profile changed
    // somewhere else (menu, CLI, plug/unplug, future display plugin).
    // Runs even when closed so the override file never goes stale.
    // Mark applied only on successful write; queue pending otherwise.
    var desiredHz = root.hzForProfile(root.activeProfile)
    if (root.activeProfile !== "" && root.profiles.indexOf(root.activeProfile) >= 0
        && (!root.appliedHz || root.appliedHz.profile !== root.activeProfile
          || root.appliedHz.rate !== desiredHz)) {
      root.requestHzOverride(root.activeProfile, desiredHz)
    }
  }

  // Manual pick for the current source (powerON = AC, powerOFF = battery).
  // omarchy-powerprofiles-set persists it in the native per-source state
  // file; restoreProfileForSource restores it automatically on plug/unplug.
  // The Hz override follows only after this command succeeds.
  function setProfile(profile) {
    if (!profile || root.profileBusy) return
    root.profileBusy = true
    root.pendingProfile = profile
    actionProc.command = ["omarchy-powerprofiles-set", root.sourceKey(), profile]
    actionProc.running = true
  }

  // ---- Per-profile 120Hz toggle. The value is stored in settings under
  // the profile's key and in the shared override file (60 or 120 only)
  // that the future display plugin also reads and writes. This widget
  // applies it directly with hyprctl within milliseconds; the monitor
  // line underneath shows the live rate.
  function hzForProfile(profile) {
    var key = Model.hzSettingKey(profile)
    if (key === "") return 120
    return Model.hzForProfile(profile, setting(key, Model.defaultHzForProfile(profile)))
  }

  function hzOverrideDir() {
    return (Quickshell.env("HOME") || "") + "/.local/state/omarchy/toggles/hypr"
  }

  function requestHzOverride(profile, rate) {
    if (!profile) return
    if (inFlightHz && inFlightHz.profile === profile && inFlightHz.rate === rate) {
      // A rapid toggle can return to the value that is already on disk. Drop
      // a different queued request instead of applying it after this write.
      requestedHz = inFlightHz
      return
    }
    if (requestedHz && requestedHz.profile === profile && requestedHz.rate === rate) return
    if (!hzWriteProc.running && appliedHz && appliedHz.profile === profile && appliedHz.rate === rate) return
    hzRevision += 1
    requestedHz = ({ profile: profile, rate: rate, revision: hzRevision })
    flushHzOverride()
  }

  function flushHzOverride() {
    if (hzWriteProc.running || !requestedHz) return
    var dir = root.hzOverrideDir()
    if (!dir || dir === "/.local/state/omarchy/toggles/hypr") {
      root.lastError = "HOME unset, cannot write Hz override"
      requestedHz = null
      return
    }
    inFlightHz = requestedHz
    hzWriteProc.command = ["bash", "-c",
      'mkdir -p "$2" && printf "%s" "$1" > "$2/refresh-override-hz"',
      "_", String(inFlightHz.rate), dir]
    hzWriteProc.running = true
  }

  function scheduleMonitorCatchUp() {
    // Burst after open/event/apply: Hyprland settles async, so one
    // immediate read always races. Two delayed retries catch the real mode
    // without a permanent poll. Keeps running even if closed: it only
    // stores currentMonitor for the next open.
    root.catchUpStep = 0
    monitorCatchUp.interval = 2500
    monitorCatchUp.restart()
  }

  function monitorModeParams(rate) {
    var m = root.currentMonitor
    if (!m || m.disabled === true) return null
    var w = Math.round(Number(m.width || 0))
    var h = Math.round(Number(m.height || 0))
    if (!(w > 0 && h > 0)) return null
    var x = Math.round(Number(m.x || 0))
    var y = Math.round(Number(m.y || 0))
    var scale = Number(m.scale || 1.6)
    if (!isFinite(scale) || scale <= 0) scale = 1.6
    var output = String(m.name || "eDP-1")
    if (output === "") output = "eDP-1"
    return {
      output: output,
      mode: w + "x" + h + "@" + rate,
      position: x + "x" + y,
      scale: scale
    }
  }

  function applyHzNow(rate) {
    // Direct apply, no daemon. Skips while the lid flag is set or the
    // monitor is off so we never fight a closed lid or an external-only
    // setup. Queues for later when geometry is still unknown.
    if (root.internalMonitorDisabled) return false
    var live = Math.round(Number(root.currentMonitor ? root.currentMonitor.refreshRate : 0))
    if (live === rate) return true
    var p = root.monitorModeParams(rate)
    if (!p) {
      root.pendingHzApply = rate
      startRefresh("monitor", monitorReadProc)
      return false
    }
    if (hzApplyProc.running) {
      root.pendingHzApply = rate
      return false
    }
    var lua = 'hl.monitor({ output = "' + p.output + '", mode = "' + p.mode
      + '", position = "' + p.position + '", scale = ' + p.scale + ' })'
    hzApplyProc.command = ["hyprctl", "eval", lua]
    hzApplyProc.running = true
    return true
  }

  // External write to the shared file (future display plugin, echo test).
  // Adopts it into the active profile so toggle and file never diverge.
  // Own writes already match, so they fall through as no-ops.
  // The file always wins: it is applied even when the profile list is
  // still unknown (panel closed since boot), the settings adopt follows
  // once profiles load.
  function handleOverrideFile(text) {
    var rate = Model.parseOverrideHz(text)
    if (rate !== 60 && rate !== 120) return
    if (root.inFlightHz && root.inFlightHz.rate === rate) return
    var profile = root.activeProfile
    if (root.appliedHz && root.appliedHz.profile === profile && root.appliedHz.rate === rate) return
    if (!profile || root.profiles.indexOf(profile) < 0) {
      root.appliedHz = ({ profile: profile, rate: rate })
      root.applyHzNow(rate)
      root.scheduleMonitorCatchUp()
      return
    }
    if (root.hzForProfile(profile) !== rate) {
      var key = Model.hzSettingKey(profile)
      if (key !== "") {
        var patch = {}
        patch[key] = rate
        root.updateSettings(patch)
      }
    }
    root.appliedHz = ({ profile: profile, rate: rate })
    root.pendingHzApply = null
    root.applyHzNow(rate)
    root.scheduleMonitorCatchUp()
  }

  function toggleHz() {
    var profile = root.activeProfile
    if (!profile || root.profiles.indexOf(profile) < 0) return
    var key = Model.hzSettingKey(profile)
    if (key === "") return
    var next = root.hzForProfile(profile) === 120 ? 60 : 120
    var patch = {}
    patch[key] = next
    root.updateSettings(patch)
    root.requestHzOverride(profile, next)
    startRefresh("monitor", monitorReadProc)
    root.scheduleMonitorCatchUp()
  }

  // One-line status for the refresh toggle: desired rate for the active
  // profile on the left of the arrow, live monitor rate on the right.
  // The "(applying…)" tail only shows while a write or apply is queued
  // or running, never from a stale live value alone.
  function hzRefreshDescription() {
    var desired = root.hzForProfile(root.activeProfile)
    var live = Math.round(Number(root.currentMonitor ? root.currentMonitor.refreshRate : 0))
    var s = Model.prettyProfile(root.activeProfile) + " → " + desired + "Hz · now " + (live > 0 ? live + "Hz" : "—")
    if (hzWriteProc.running || hzApplyProc.running || root.pendingHzApply !== null) s += " (applying…)"
    return s
  }

  // Live monitor discovery for the status line. On every read, retry a
  // queued direct apply whose geometry was unknown at request time.
  function handleMonitorsOutput(text) {
    var parsed = null
    try { parsed = JSON.parse(String(text || "")) } catch (e) { parsed = null }
    if (!Array.isArray(parsed) || parsed.length === 0) return false
    for (var i = 0; i < parsed.length; i++) {
      if (parsed[i] && parsed[i].focused) {
        root.currentMonitor = parsed[i]
        break
      }
      if (i === parsed.length - 1) root.currentMonitor = parsed[0]
    }
    if (root.pendingHzApply === 60 || root.pendingHzApply === 120) {
      var rate = root.pendingHzApply
      root.pendingHzApply = null
      root.applyHzNow(rate)
    }
    return true
  }

  function togglePercentage() {
    root.updateSettings({ showPercentage: !root.showPercentage })
  }

  // ---- Charge threshold toggle. Calls UPower's own EnableChargeThreshold
  // DBus method (UPower ships its own polkit policy for it) rather than
  // writing the sysfs threshold file directly, which is root-owned. The
  // percentages themselves (e.g. 75-80%) stay as firmware reports them --
  // this only flips whether the limit is enforced.
  // Two steps with plain argv, no shell interpolation: first resolve the
  // battery object path via `upower -e`, then call gdbus with that path.
  function refreshChargeThreshold() {
    if (!root.batteryInfo.threshold) return
    if (root.batteryDbusPath !== "") {
      chargeThresholdReadProc.command = ["gdbus", "call", "--system",
        "--dest", "org.freedesktop.UPower",
        "--object-path", root.batteryDbusPath,
        "--method", "org.freedesktop.DBus.Properties.Get",
        "org.freedesktop.UPower.Device", "ChargeThresholdEnabled"]
      chargeThresholdReadProc.running = true
      return
    }
    if (!upowerEnumProc.running) upowerEnumProc.running = true
  }

  function handleUpowerEnum(text) {
    var path = Model.parseBatteryDbusPath(text)
    if (!path) {
      root.chargeThresholdError = "No battery device found"
      return
    }
    root.batteryDbusPath = path
    root.refreshChargeThreshold()
  }

  function toggleChargeThreshold() {
    if (chargeThresholdActionProc.running) return
    if (!root.batteryDbusPath) {
      root.chargeThresholdError = "Battery path unknown, retrying"
      root.refreshChargeThreshold()
      return
    }
    var next = !root.chargeThresholdEnabled
    chargeThresholdActionProc.command = ["gdbus", "call", "--system",
      "--dest", "org.freedesktop.UPower",
      "--object-path", root.batteryDbusPath,
      "--method", "org.freedesktop.UPower.Device.EnableChargeThreshold",
      next ? "true" : "false"]
    chargeThresholdActionProc.running = true
  }

  function recordDrainSample() {
    // Record draw only while discharging; while charging the rate field
    // is charge current, not draw. Uses the effective (sysfs-arbitrated)
    // source so a stale UPower record cannot poison the graph.
    // Pass null otherwise so the window still prunes by age instead
    // of freezing.
    var watts = root.sourceKey() === "battery" ? Model.parseWattsRate(root.batteryInfo.rate) : null
    root.drainSamples = Model.appendDrainSample(root.drainSamples, watts, Date.now() / 1000, 600)
  }

  // ---- Instant AC/battery reaction. Three layers, cheapest first:
  // 1. UPower onBatteryChanged signal (instant when UPower is healthy).
  // 2. Kernel uevents via udevadm monitor while open (immune to stale UPower).
  // 3. The 15s poll stays as safety net for missed signals.
  // Every trigger runs the one-shot sysfs probe; sysfs wins disagreements.
  // On flip the panel itself restores the remembered profile for the new
  // source (replaces hypr-profile-auto) and the Hz enforce in
  // updateProfiles applies that profile's rate directly (no daemon).
  function probeAcSource() {
    if (!acProbeProc.running) acProbeProc.running = true
  }

  function restoreProfileForSource(src) {
    if (src !== "ac" && src !== "battery") return
    if (root.profileBusy || actionProc.running) return
    root.profileBusy = true
    root.pendingProfile = ""
    actionProc.command = ["omarchy-powerprofiles-set", src]
    actionProc.running = true
  }

  function handleAcProbe(code) {
    var src = Model.probeSourceFromExit(code)
    if (src === "") {
      root.sourceError = "Power source probe failed (exit " + code + ")"
      return
    }
    root.sourceError = ""
    if (src !== root.acSource) {
      root.acSource = src
      // Source flipped: refresh text fields now instead of next poll tick.
      root.refresh()
      startRefresh("monitor", monitorReadProc)
      root.scheduleMonitorCatchUp()
      root.restoreProfileForSource(src)
    }
  }

  function handleUdevLine(line) {
    if (!line || String(line).trim() === "") return
    udevDebounce.restart()
  }

  IpcHandler {
    target: "tymurbogach.battery"

    function open() { root.open() }
    function close() { root.close() }
    function show() { root.open() }
    function hide() { root.close() }
    function toggle() { root.toggle() }
    function togglePercentage() { root.togglePercentage() }
  }

  onOpenedChanged: {
    if (opened) {
      if (!batteryPresent) {
        close()
        return
      }

      refresh()
      root.probeAcSource()
      root.refreshChargeThreshold()
      startRefresh("monitor", monitorReadProc)
      root.scheduleMonitorCatchUp()
      if (!udevMonProc.running) udevMonProc.running = true
      var idx = profiles.indexOf(activeProfile)
      profileIndex = idx >= 0 ? idx : 0
      cursorActive = false
    } else {
      // Panel closed: stop the uevent watch. The bar pill icon stays
      // reactive through the UPower binding at zero cost.
      udevMonProc.running = false
      udevMonRestart.stop()
      udevDebounce.stop()
    }
  }

  onBatteryPresentChanged: if (!batteryPresent) close()

  // Same signal the first-party omarchy.battery service uses.
  Connections {
    target: UPower
    function onOnBatteryChanged() {
      root.probeAcSource()
      root.refresh()
      startRefresh("monitor", monitorReadProc)
      root.scheduleMonitorCatchUp()
    }
  }

  visible: batteryPresent
  implicitWidth: batteryPresent ? button.implicitWidth : 0
  implicitHeight: batteryPresent ? button.implicitHeight : 0

  Process {
    id: batteryProc
    command: ["omarchy-battery-status", "--shell"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.updateKeyValue(text, "battery") }
    stderr: StdioCollector { waitForEnd: true; id: batteryStderr }
    onExited: function(code) {
      if (code !== 0) root.noteRefreshFailure("battery", "battery exit " + code
        + (batteryStderr.text ? ": " + String(batteryStderr.text).trim().slice(0, 120) : ""))
    }
  }

  Process {
    id: profilesProc
    command: ["omarchy-powerprofiles-list", "--active-state"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.updateProfiles(text) }
    stderr: StdioCollector { waitForEnd: true; id: profilesStderr }
    onExited: function(code) {
      if (code !== 0) root.noteRefreshFailure("profiles", "profiles exit " + code
        + (profilesStderr.text ? ": " + String(profilesStderr.text).trim().slice(0, 120) : ""))
    }
  }

  Process {
    id: systemProc
    command: ["omarchy-system-stats"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.updateKeyValue(text, "system") }
    stderr: StdioCollector { waitForEnd: true; id: systemStderr }
    onExited: function(code) {
      if (code !== 0) root.noteRefreshFailure("system", "system exit " + code
        + (systemStderr.text ? ": " + String(systemStderr.text).trim().slice(0, 120) : ""))
    }
  }

  Process {
    id: actionProc
    stderr: StdioCollector { waitForEnd: true; id: actionStderr }
    onExited: function(code) {
      root.profileBusy = false
      var profile = root.pendingProfile
      root.pendingProfile = ""
      if (code !== 0) {
        root.lastError = "Profile switch failed (exit " + code + ")"
        if (actionStderr.text) root.lastError += ": " + String(actionStderr.text).trim().slice(0, 120)
      } else {
        root.lastError = ""
        root.requestHzOverride(profile, root.hzForProfile(profile))
      }
      root.refresh()
    }
  }

  Process {
    id: upowerEnumProc
    command: ["upower", "-e"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.handleUpowerEnum(text) }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text && String(text).trim() !== "") root.chargeThresholdError = String(text).trim().slice(0, 160)
    }
    onExited: function(code) { if (code !== 0) root.chargeThresholdError = "upower -e failed (exit " + code + ")" }
  }

  // One-shot sysfs truth. omarchy-power-present exits 0 on AC, 1 on
  // battery. No output to parse, no shell involved.
  Process {
    id: acProbeProc
    command: ["omarchy-power-present"]
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(code) { root.handleAcProbe(code) }
  }

  // Kernel uevents for power_supply while the panel is open. A plug or
  // unplug wakes this instantly even when UPower records go stale.
  // Long-running by design: the watchdog must never kill it.
  Process {
    id: udevMonProc
    command: ["udevadm", "monitor", "--udev", "--subsystem-match=power_supply"]
    stdout: SplitParser { onRead: function(line) { root.handleUdevLine(line) } }
    stderr: StdioCollector { waitForEnd: true }
    onExited: udevMonRestart.restart()
  }

  Timer {
    id: udevMonRestart
    interval: 2000
    onTriggered: if (root.opened && !udevMonProc.running) udevMonProc.running = true
  }

  // Uevents arrive in bursts (one per supply plus properties). Probe once
  // the burst settles instead of once per line.
  Timer {
    id: udevDebounce
    interval: 500
    onTriggered: root.probeAcSource()
  }

  Process {
    id: chargeThresholdReadProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var value = Model.parseGdbusBoolean(text)
        if (value !== null) {
          root.chargeThresholdEnabled = value
          root.chargeThresholdKnown = true
          root.chargeThresholdError = ""
        } else {
          root.chargeThresholdError = "Threshold read failed"
        }
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text && String(text).trim() !== "") root.chargeThresholdError = String(text).trim().slice(0, 160)
    }
    onExited: function(code) { if (code !== 0 && !root.chargeThresholdError) root.chargeThresholdError = "Threshold read exit " + code }
  }

  Process {
    id: chargeThresholdActionProc
    stderr: StdioCollector { waitForEnd: true; id: thresholdActionStderr }
    onExited: function(code) {
      if (code !== 0) {
        root.chargeThresholdError = "Threshold toggle denied (exit " + code + "). Check polkit agent."
        if (thresholdActionStderr.text) root.chargeThresholdError += ": " + String(thresholdActionStderr.text).trim().slice(0, 120)
      } else {
        root.chargeThresholdError = ""
      }
      root.refreshChargeThreshold()
    }
  }

  // Live rate for the status line. Coalesced: a request that lands while
  // hyprctl runs relaunches once here instead of being dropped.
  Process {
    id: monitorReadProc
    command: ["hyprctl", "monitors", "-j"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (!root.handleMonitorsOutput(text)) root.noteRefreshFailure("monitor", "monitor output invalid")
    }
    stderr: StdioCollector { waitForEnd: true; id: monitorStderr }
    onExited: function(code) {
      if (code !== 0) root.noteRefreshFailure("monitor", "hyprctl monitors exit " + code
        + (monitorStderr.text ? ": " + String(monitorStderr.text).trim().slice(0, 120) : ""))
      else root.noteRefreshSuccess("monitor")
      if (root.monitorDirty) {
        root.monitorDirty = false
        root.startRefresh("monitor", monitorReadProc)
        stallTimer.restart()
      }
    }
  }

  // Writes the shared Hz override file, then applies it directly.
  Process {
    id: hzWriteProc
    stderr: StdioCollector { waitForEnd: true; id: hzWriteStderr }
    onExited: function(code) {
      var completed = root.inFlightHz
      root.inFlightHz = null
      if (code === 0 && completed) {
        root.appliedHz = completed
        if (root.requestedHz && root.requestedHz.revision === completed.revision) root.requestedHz = null
        root.lastError = ""
        root.applyHzNow(completed.rate)
        root.scheduleMonitorCatchUp()
      } else {
        root.lastError = "Hz override write failed (exit " + code + ")"
        if (hzWriteStderr.text) root.lastError += ": " + String(hzWriteStderr.text).trim().slice(0, 120)
        if (root.requestedHz && completed && root.requestedHz.revision === completed.revision) root.requestedHz = null
      }
      root.flushHzOverride()
    }
  }

  // Direct Hz apply. No daemon: hyprctl eval with the current geometry.
  Process {
    id: hzApplyProc
    stderr: StdioCollector { waitForEnd: true; id: hzApplyStderr }
    onExited: function(code) {
      if (code !== 0) {
        root.lastError = "Hz apply failed (exit " + code + ")"
        if (hzApplyStderr.text) root.lastError += ": " + String(hzApplyStderr.text).trim().slice(0, 120)
      } else if (root.pendingHzApply === 60 || root.pendingHzApply === 120) {
        var rate = root.pendingHzApply
        root.pendingHzApply = null
        root.applyHzNow(rate)
      }
      root.scheduleMonitorCatchUp()
    }
  }

  // Shared override file with the future display plugin. Watched so a
  // change on either side lands instantly without polling. The directory
  // watch covers first creation (FileView cannot watch a missing file).
  FileView {
    id: hzOverrideFile
    path: root.hzOverrideDir() + "/refresh-override-hz"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.handleOverrideFile(text())
  }
  FileView {
    path: root.hzOverrideDir()
    watchChanges: true
    printErrors: false
    onFileChanged: hzOverrideFile.reload()
  }
  // Lid-closed flag: while present never force the internal panel.
  FileView {
    path: root.hzOverrideDir() + "/internal-monitor-disable.conf"
    watchChanges: true
    printErrors: false
    onLoaded: root.internalMonitorDisabled = true
    onLoadFailed: root.internalMonitorDisabled = false
    onFileChanged: reload()
  }

  Component.onCompleted: {
    if (root.batteryPresent) {
      startRefresh("monitor", monitorReadProc)
      root.probeAcSource()
      root.scheduleMonitorCatchUp()
    }
  }

  // Main poll: 15s while open. UPower displayDevice already pushes
  // presence/state reactively; this only refreshes CLI text fields.
  Timer { interval: 15000; running: root.opened; repeat: true; onTriggered: root.refresh() }

  // Catch-up burst, not a poll: immediate read already fired at the
  // event, these two delayed retries catch Hyprland after it settles.
  // Runs to completion even if closed; it only stores currentMonitor.
  Timer {
    id: monitorCatchUp
    interval: 2500
    repeat: false
    onTriggered: {
      root.startRefresh("monitor", monitorReadProc)
      stallTimer.restart()
      if (root.catchUpStep === 0) {
        root.catchUpStep = 1
        monitorCatchUp.interval = 6000
        monitorCatchUp.restart()
      } else {
        root.catchUpStep = 0
      }
    }
  }

  // A hung CLI would freeze refresh forever since a running Process
  // cannot restart. Kill stragglers so the next tick recovers.
  // udevMonProc is long-running by design and stays out of this list.
  Timer {
    id: stallTimer
    interval: 10000
    onTriggered: {
      var batteryStalled = batteryProc.running
      var profilesStalled = profilesProc.running
      var systemStalled = systemProc.running
      var monitorStalled = monitorReadProc.running
      var probeStalled = acProbeProc.running
      var hzWriteStalled = hzWriteProc.running
      var hzApplyStalled = hzApplyProc.running
      if (batteryStalled) batteryProc.running = false
      if (profilesStalled) profilesProc.running = false
      if (systemStalled) systemProc.running = false
      if (monitorStalled) monitorReadProc.running = false
      if (probeStalled) acProbeProc.running = false
      if (hzWriteStalled) hzWriteProc.running = false
      if (hzApplyStalled) hzApplyProc.running = false
      if (batteryStalled) root.noteRefreshFailure("battery", "battery timeout, retrying")
      if (profilesStalled) root.noteRefreshFailure("profiles", "profiles timeout, retrying")
      if (systemStalled) root.noteRefreshFailure("system", "system timeout, retrying")
      if (monitorStalled) root.noteRefreshFailure("monitor", "monitor timeout, retrying")
      if (probeStalled) root.sourceError = "Power source probe timed out"
      if (hzWriteStalled || hzApplyStalled) root.lastError = "Hz apply timed out, retrying"
      if (root.monitorDirty) {
        root.monitorDirty = false
        root.startRefresh("monitor", monitorReadProc)
      }
      root.flushHzOverride()
    }
  }

  // Rotate the status phrase while the panel is open and we're in a
  // rotating state (charging or on battery). The text swap is wrapped in a
  // fade so the changeover reads as one organism rather than a hard cut.
  Timer {
    id: phraseTimer
    interval: 2800
    running: root.opened && root.rotatingPhrases
    repeat: true
    triggeredOnStart: false
    onTriggered: phraseSwap.restart()
  }

  SequentialAnimation {
    id: phraseSwap
    PropertyAnimation {
      target: heroStatus; property: "opacity"
      to: 0.0; duration: 180; easing.type: Easing.OutQuad
    }
    ScriptAction {
      script: {
        var n = root.activePhrases.length
        if (n > 0) root.phraseIndex = (root.phraseIndex + 1) % n
      }
    }
    PropertyAnimation {
      target: heroStatus; property: "opacity"
      to: 1.0; duration: 260; easing.type: Easing.InQuad
    }
  }

  // If we leave a rotating state mid-swap, halt the animation and snap back
  // to full opacity so "FULLY CHARGED" is legible immediately rather than
  // appearing dimmed.
  Connections {
    target: root
    function onRotatingPhrasesChanged() {
      if (!root.rotatingPhrases) {
        phraseSwap.stop()
        heroStatus.opacity = 1.0
      }
    }
    function onOpenedChanged() {
      if (!root.opened) {
        phraseSwap.stop()
        if (heroStatus) heroStatus.opacity = 1.0
      }
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    Accessible.name: "Battery " + root.buttonTooltip
    text: {
      var icon = root.batteryIcon()
      if (!(root.showPercentage && !vertical)) return icon
      var f = root.batteryFraction
      return (isFinite(f) ? Math.round(f * 100) + "% " : "— ") + icon
    }
    slotSize: Style.bar.iconSlot * (root.showPercentage && !vertical ? 2 : 1)
    tooltipText: root.buttonTooltip
    onPressed: function(b) {
      if (!root.batteryPresent) return
      if (b === Qt.RightButton) root.togglePercentage()
      else if (b === Qt.LeftButton) root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened && root.batteryPresent
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dx !== 0) root.selectProfileByDelta(dx)
        else if (dy !== 0) root.selectProfileByDelta(dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateSelectedProfile()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(14)

        // ---------- Hero: battery icon · title/status · percentage ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, heroPercent.implicitHeight)

          Text {
            id: heroIcon
            textFormat: Text.PlainText
            text: root.batteryIcon()
            color: root.fg
            font.family: root.ff
            font.pixelSize: Style.font.display
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter

            Behavior on color { ColorAnimation { duration: 200 } }
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: heroPercent.left
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              text: "Battery"
              color: root.fg
              font.family: root.ff
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }

            Text {
              id: heroStatus
              textFormat: Text.PlainText
              text: root.heroStatusText.toUpperCase()
              color: Qt.darker(root.fg, 1.4)
              font.family: root.ff
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
              elide: Text.ElideRight
              width: parent.width
            }
          }

          Text {
            id: heroPercent
            textFormat: Text.PlainText
            text: root.batteryInfo.percentage || "—"
            color: root.fg
            font.family: root.ff
            font.pixelSize: Style.font.displayLarge
            font.bold: true
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter

            Behavior on color { ColorAnimation { duration: 200 } }
          }
        }

        // ---------- Battery progress bar ----------
        Item {
          width: parent.width
          implicitHeight: Style.space(8)

          Rectangle {
            id: barTrack
            anchors.fill: parent
            radius: height / 2
            color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.12)
          }

          Rectangle {
            id: barFill
            anchors.left: barTrack.left
            anchors.verticalCenter: barTrack.verticalCenter
            height: barTrack.height
            radius: barTrack.radius
            color: root.batteryFillColor
            width: Math.max(barTrack.height, barTrack.width * root.batteryFraction)

            Behavior on width { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
            Behavior on color { ColorAnimation { duration: 220 } }

            // Subtle pulse while charging — visible signal that energy is flowing in.
            SequentialAnimation on opacity {
              running: root.charging && !root.fullyCharged && root.opened
              loops: Animation.Infinite
              NumberAnimation { from: 1.0; to: 0.55; duration: 950; easing.type: Easing.InOutSine }
              NumberAnimation { from: 0.55; to: 1.0; duration: 950; easing.type: Easing.InOutSine }
            }
          }
        }

        // ---------- Status banner: stale data or visible errors ----------
        Text {
          visible: root.dataStale || root.lastError !== "" || root.sourceError !== "" || root.sourceConflict
          width: parent.width
          textFormat: Text.PlainText
          text: {
            if (root.sourceConflict) return "SYSFS ▸ " + root.sourceLabel() + " (UPower stale)"
            if (root.sourceError !== "") return root.sourceError
            return root.dataStale ? ("STALE · " + (root.staleError || "retrying")) : root.lastError
          }
          color: root.fg
          opacity: 0.7
          font.family: root.ff
          font.pixelSize: Style.font.bodySmall
          font.bold: true
          elide: Text.ElideRight
        }

        // ---------- Stats ----------
        // Visibility is intentionally only gated by "we've ever loaded data" so
        // the section never collapses mid-transition. fullyCharged is *not* part
        // of the condition: UPower briefly reports FullyCharged on plug-in when
        // the battery sits above the charge-control start threshold, and we
        // refuse to flicker the whole panel for that ~1s window.
        Row {
          visible: !!root.batteryInfo.percentage
          width: parent.width
          spacing: Style.space(20)

          Column {
            width: (parent.width - parent.spacing) / 2
            spacing: Style.spacing.labelGap
            InfoPair { label: "Battery size"; value: root.batteryInfo.size || "—" }
            InfoPair { label: "Charge cycles"; value: root.batteryInfo.cycles || "—" }
          }

          Column {
            width: (parent.width - parent.spacing) / 2
            spacing: Style.spacing.labelGap
            InfoPair {
              label: root.chargeThresholdActive ? "Charge limit" : (root.effectiveOnBattery ? "Time left" : "Time to full")
              value: root.chargeThresholdActive ? (root.batteryInfo.threshold || "—") : (root.batteryFlowIdle ? "—" : (root.batteryInfo.time || "—"))
            }
            InfoPair {
              label: root.chargeThresholdActive ? "Battery state" : (root.effectiveOnBattery ? "Discharging" : "Charging")
              value: root.chargeThresholdActive ? "Holding" : (root.batteryFull ? "—" : (root.batteryInfo.rate || "—"))
            }
          }
        }

        // ---------- Power profile per source, plus its refresh rate.
        // The toggle below always follows the active pill, so no
        // "in <profile>" is needed: the pill already says the profile.
        PanelSeparator {
          foreground: root.fg
        }

        Column {
          width: parent.width
          spacing: Style.space(10)

          PanelSectionHeader {
            text: "POWER · " + root.sourceLabel()
            foreground: root.fg
            fontFamily: root.ff
          }

          Row {
            id: profileRow
            width: parent.width
            spacing: Style.space(6)

            readonly property real cellWidth: root.profiles.length > 0
              ? Math.max(0, (width - spacing * (root.profiles.length - 1)) / root.profiles.length)
              : 0

            Repeater {
              model: root.profiles
              Button {
                required property var modelData
                required property int index
                width: profileRow.cellWidth
                enabled: !root.profileBusy
                Accessible.name: "Profile " + String(modelData || "")
                iconText: root.profileIcon(String(modelData || ""))
                iconSize: Style.font.title
                text: {
                  var s = String(modelData || "")
                  return s ? s.charAt(0).toUpperCase() + s.slice(1) : "—"
                }
                fontSize: Style.font.bodySmall
                foreground: root.fg
                fontFamily: root.ff
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
                bordered: true
                active: root.activeProfile === modelData
                hasCursor: root.cursorActive && root.profileIndex === index
                onClicked: root.setProfile(modelData)
                onHovered: function(h) {
                  if (h) {
                    root.cursorActive = true
                    root.profileIndex = index
                  }
                }
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            text: "Auto-switch: built-in (sysfs, per source)"
            color: root.fg
            opacity: 0.6
            font.family: root.ff
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideRight
            width: parent.width
          }

          Toggle {
            width: parent.width
            label: "Refresh rate"
            description: root.hzRefreshDescription()
            checked: root.hzForProfile(root.activeProfile) === 120
            enabled: root.profiles.indexOf(root.activeProfile) >= 0 && !root.profileBusy
            foreground: root.fg
            accent: Color.accent
            fontFamily: root.ff
            onClicked: root.toggleHz()
          }
        }

        // ---------- Charge threshold toggle. Only shown once the battery
        // actually reports a configured threshold -- the same gate
        // omarchy-battery-status already applies before printing it. ----------
        Item {
          visible: !!root.batteryInfo.threshold
          width: parent.width
          height: visible ? chargeThresholdColumn.implicitHeight : 0

          Column {
            id: chargeThresholdColumn
            width: parent.width
            spacing: Style.space(10)

            PanelSeparator { foreground: root.fg }

            Toggle {
              width: parent.width
              label: "Charge threshold"
              description: root.chargeThresholdError !== "" ? root.chargeThresholdError
                : !root.chargeThresholdKnown ? "Reading state…"
                : root.batteryInfo.threshold
                ? ("Hold at " + root.batteryInfo.threshold + " to protect battery health")
                : "Hold charge below the firmware limit"
              checked: root.chargeThresholdEnabled
              enabled: root.chargeThresholdKnown && !chargeThresholdActionProc.running
              foreground: root.fg
              accent: Color.accent
              fontFamily: root.ff
              onClicked: root.toggleChargeThreshold()
            }
          }
        }

        // ---------- Power draw + health: short sparkline, no persistence. ----
        Item {
          visible: root.drainSamples.length > 1
          width: parent.width
          height: visible ? drainColumn.implicitHeight : 0

          Column {
            id: drainColumn
            width: parent.width
            spacing: Style.space(6)

            PanelSeparator { foreground: root.fg }

            Item {
              width: parent.width
              implicitHeight: Math.max(drainHeader.implicitHeight, drainNow.implicitHeight)

              PanelSectionHeader {
                id: drainHeader
                text: "POWER DRAW (LAST 10 MIN)"
                foreground: root.fg
                fontFamily: root.ff
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              // A flat near-zero line reads as "broken" without this --
              // the number makes a quiet graph legible on its own.
              InfoValue {
                id: drainNow
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: {
                  if (root.drainSamples.length === 0) return ""
                  var w = root.drainSamples[root.drainSamples.length - 1].w
                  return isFinite(w) ? Number(w).toFixed(1) + "W" : ""
                }
              }
            }

            Canvas {
              id: sparkline
              width: parent.width
              height: Style.space(40)
              // Vertical inset so a flat (near-zero draw) line sits a few
              // pixels off the bottom edge instead of hugging it.
              readonly property real topInset: Style.space(4)
              readonly property real bottomInset: Style.space(6)
              onPaint: {
                var ctx = getContext("2d")
                ctx.clearRect(0, 0, width, height)
                var samples = root.drainSamples
                if (!samples || samples.length < 2 || width <= 0 || height <= 0) return
                var maxW = 0
                for (var i = 0; i < samples.length; i++) {
                  var sw = samples[i] ? samples[i].w : NaN
                  if (isFinite(sw) && sw > 0) maxW = Math.max(maxW, sw)
                }
                if (!(maxW > 0)) maxW = 1
                var minT = samples[0].t
                var maxT = samples[samples.length - 1].t
                if (!isFinite(minT) || !isFinite(maxT)) return
                var spanT = Math.max(1, maxT - minT)
                var plotHeight = height - topInset - bottomInset
                if (plotHeight <= 0) return

                ctx.strokeStyle = Style.selectedStateColor(root.fg, Color.accent)
                ctx.lineWidth = 1.5
                ctx.beginPath()
                var started = false
                for (var j = 0; j < samples.length; j++) {
                  var t = samples[j] ? samples[j].t : NaN
                  var w = samples[j] ? samples[j].w : NaN
                  if (!isFinite(t) || !isFinite(w)) continue
                  var x = ((t - minT) / spanT) * width
                  var cw = Math.max(0, w)
                  var y = topInset + plotHeight - (Math.min(cw, maxW) / maxW) * plotHeight
                  if (!isFinite(x) || !isFinite(y)) continue
                  if (!started) { ctx.moveTo(x, y); started = true }
                  else ctx.lineTo(x, y)
                }
                if (started) ctx.stroke()
              }

              Connections {
                target: root
                function onDrainSamplesChanged() { sparkline.requestPaint() }
              }
            }

            Text {
              textFormat: Text.PlainText
              text: {
                var parts = []
                if (root.batteryInfo.cycles) parts.push(root.batteryInfo.cycles + " cycles")
                if (root.batteryInfo.threshold) parts.push("limit " + root.batteryInfo.threshold)
                if (root.batteryInfo.size) parts.push(root.batteryInfo.size)
                return parts.join(" · ")
              }
              visible: text !== ""
              color: root.fg
              opacity: 0.6
              font.family: root.ff
              font.pixelSize: Style.font.bodySmall
              elide: Text.ElideRight
              width: parent.width
            }
          }
        }
      }
    }
  }

  component InfoPair: Row {
    property string label: ""
    property string value: ""

    width: parent.width
    spacing: Style.space(8)

    InfoLabel { id: pairLabel; text: label }
    Item { width: Math.max(0, parent.width - pairLabel.implicitWidth - pairValue.implicitWidth - parent.spacing * 2); height: 1 }
    InfoValue { id: pairValue; text: value }
  }

  component InfoLabel: Text {
    textFormat: Text.PlainText
    color: root.fg
    opacity: 0.6
    font.family: root.ff
    font.pixelSize: Style.font.bodySmall
  }

  component InfoValue: Text {
    textFormat: Text.PlainText
    color: root.fg
    font.family: root.ff
    font.pixelSize: Style.font.bodySmall
  }
}
