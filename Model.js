function clampIndex(index, length) {
  if (length <= 0) return 0
  return Math.max(0, Math.min(length - 1, index))
}

function selectProfileIndex(index, delta, profiles) {
  var values = Array.isArray(profiles) ? profiles : []
  if (values.length === 0) return 0
  return clampIndex(index + delta, values.length)
}

function parseKeyValue(raw) {
  var next = {}
  var lines = String(raw == null ? "" : raw).split("\n")
  for (var i = 0; i < lines.length; i++) {
    var idx = lines[i].indexOf("\t")
    if (idx <= 0) continue
    var key = lines[i].substring(0, idx).trim()
    if (!key) continue
    next[key] = lines[i].substring(idx + 1).trim()
  }
  return next
}

function parseProfiles(raw, previousIndex) {
  var lines = String(raw == null ? "" : raw).split("\n")
  var list = []
  var active = ""
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (!line) continue
    var parts = line.split("\t")
    var name = (parts[0] || "").trim()
    if (!name) continue
    if (list.indexOf(name) < 0) list.push(name)
    if (parts.length > 1 && parts[1].trim() === "1" && !active) active = name
  }
  return {
    profiles: list,
    activeProfile: active,
    profileIndex: clampIndex(previousIndex || 0, list.length)
  }
}

function profileIcon(name) {
  if (name === "power-saver") return "󰌪"
  if (name === "balanced") return "󰊚"
  if (name === "performance") return "󰓅"
  return "󰂄"
}

function finiteFraction(value) {
  var n = Number(value)
  if (!isFinite(n)) return null
  if (n > 1 && n <= 100) n = n / 100
  if (n < 0 || n > 1) return null
  return n
}

function batteryFraction(device) {
  if (!(device && device.isPresent)) return 0
  var f = finiteFraction(device.percentage)
  return f === null ? 0 : Math.max(0, Math.min(1, f))
}

function chargeThresholdActive(device, onBattery, states) {
  var d = device || {}
  var s = states || {}
  if (!(d && d.isPresent && !onBattery)) return false
  if (d.state === s.Discharging) return false

  var fraction = finiteFraction(d.percentage)
  if (fraction === null) return false
  if (d.state === s.PendingCharge) return true
  if (d.state === s.FullyCharged && fraction < 0.99) return true
  if (d.state !== s.Charging || fraction >= 0.99) return false

  var rate = Number(d.changeRate)
  var ttf = Number(d.timeToFull)
  if (!isFinite(rate)) return false
  if (rate > 0.2 && !(isFinite(ttf) && ttf >= 8 * 60 * 60)) return false
  return true
}

function batteryIcon(device, onBattery, states) {
  var d = device || {}
  if (!d.isPresent) return ""

  var chargingIcons = ["󰢜", "󰂆", "󰂇", "󰂈", "󰢝", "󰂉", "󰢞", "󰂊", "󰂋", "󰂅"]
  var defaultIcons = ["󰁺", "󰁻", "󰁼", "󰁽", "󰁾", "󰁿", "󰂀", "󰂁", "󰂂", "󰁹"]
  var fraction = finiteFraction(d.percentage)
  if (fraction === null) return "󰂄"
  var index = Math.max(0, Math.min(9, Math.floor(fraction * 10)))
  var threshold = chargeThresholdActive(d, onBattery, states)

  if (threshold) return defaultIcons[index]
  if (d.state === states.FullyCharged) return "󰂅"
  if (!onBattery) return chargingIcons[index]
  return defaultIcons[index]
}

function modeLabel(device, onBattery, states) {
  var d = device || {}
  if (!d.isPresent) return ""

  if (chargeThresholdActive(d, onBattery, states)) return "Threshold"
  if (onBattery) return "On battery"
  var fraction = finiteFraction(d.percentage)
  if (fraction === null) return "Unknown"
  if (!onBattery && fraction >= 1) return "Fully charged"
  return "Charging"
}

// ---- Charge-threshold toggle. `gdbus call` prints a boolean property
// read as "(<true>,)" / "(<false>,)".
function parseGdbusBoolean(raw) {
  var text = String(raw == null ? "" : raw)
  var m = text.match(/\(\s*<\s*(true|false)\s*>\s*,?\s*\)/)
  if (m) return m[1] === "true"
  return null
}

// Resolves the UPower battery object path from `upower -e` output.
// Prefers battery_BAT0, then any battery_BAT*, then first battery_*.
// Skips HID++ and line_power devices. Returns "" when none matches.
function parseBatteryDbusPath(raw) {
  var lines = String(raw == null ? "" : raw).split("\n")
  var fallback = ""
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (!line) continue
    if (line.indexOf("/org/freedesktop/UPower/devices/battery_BAT0") >= 0) return line
    if (!fallback && /battery_BAT/i.test(line)) fallback = line
  }
  if (fallback) return fallback
  for (var j = 0; j < lines.length; j++) {
    var other = lines[j].trim()
    if (/\/battery_[A-Za-z0-9_]+$/.test(other) && other.indexOf("hidpp") === -1) return other
  }
  return ""
}

// ---- Watts drain history: a short in-memory sparkline, not a database.
// Accepts "15W", "15.5 W", 0. Rejects NaN and infinities.
function parseWattsRate(rateText) {
  if (rateText === null || rateText === undefined) return null
  var value = parseFloat(String(rateText).trim())
  return isFinite(value) ? value : null
}

// Appends one sample and drops anything older than maxAgeSeconds -- a
// bounded rolling window instead of an ever-growing array. Resets on
// backward clock jumps so x stays monotonic. Caps count to bound memory.
function appendDrainSample(samples, watts, now, maxAgeSeconds) {
  var next = Array.isArray(samples) ? samples.slice() : []
  if (!isFinite(now)) return next
  if (next.length > 0 && now < next[next.length - 1].t) next = []
  if (watts !== null && watts !== undefined && isFinite(watts)) {
    next.push({ t: now, w: Number(watts) })
  }
  var cutoff = now - maxAgeSeconds
  while (next.length > 0 && next[0].t < cutoff) next.shift()
  var maxSamples = 200
  if (next.length > maxSamples) next = next.slice(next.length - maxSamples)
  return next
}

// Shared Hz contract with the future display plugin. The override file
// holds a single desired rate ("60" or "120"). Both UIs write the file
// plus the hz_<active profile> setting and watch the file for the other
// side. Permissive like the old daemon's `tr -cd '0-9'`: "120Hz" counts
// as 120. Anything else is null and must be ignored.
function parseOverrideHz(raw) {
  var text = String(raw == null ? "" : raw)
  var digits = text.replace(/[^0-9]/g, "")
  if (digits === "60") return 60
  if (digits === "120") return 120
  return null
}

// ---- Per-profile 120Hz toggle. Each power profile remembers its own
// refresh rate (60 or 120); the panel applies the override file directly.
function defaultHzForProfile(profile) {
  if (profile === "power-saver") return 60
  return 120
}

function hzSettingKey(profile) {
  if (profile === "power-saver") return "hz_power-saver"
  if (profile === "balanced") return "hz_balanced"
  if (profile === "performance") return "hz_performance"
  return ""
}

function normalizeHz(value, fallback) {
  var n = Number(value)
  if (n === 60 || n === 120) return n
  return fallback
}

function hzForProfile(profile, storedValue) {
  return normalizeHz(storedValue, defaultHzForProfile(profile))
}

function prettyProfile(profile) {
  var name = String(profile || "")
  return name === "" ? "…" : (name.charAt(0).toUpperCase() + name.slice(1))
}

// ---- AC/battery source arbitration. UPower OnBattery can freeze on stale
// line_power_AC records; omarchy-power-present (sysfs) is the tiebreaker.
// Probe maps its documented exit codes: 0 = AC, 1 = battery. Any other
// code is an operational error and must not overwrite the last known source.
function probeSourceFromExit(code) {
  var value = Number(code)
  if (value === 0) return "ac"
  if (value === 1) return "battery"
  return ""
}

// Prefers the sysfs probe when known, falls back to the UPower derivation.
function effectiveSource(probed, fallback) {
  if (probed === "ac" || probed === "battery") return probed
  return fallback
}

// True when the probe disagrees with UPower: sysfs wins, show it.
function sourceConflict(probed, discharging) {
  if (probed !== "ac" && probed !== "battery") return false
  return (probed === "battery") !== !!discharging
}

if (typeof module !== "undefined") {
  module.exports = {
    clampIndex: clampIndex,
    selectProfileIndex: selectProfileIndex,
    parseKeyValue: parseKeyValue,
    parseProfiles: parseProfiles,
    profileIcon: profileIcon,
    finiteFraction: finiteFraction,
    batteryFraction: batteryFraction,
    chargeThresholdActive: chargeThresholdActive,
    batteryIcon: batteryIcon,
    modeLabel: modeLabel,
    parseGdbusBoolean: parseGdbusBoolean,
    parseBatteryDbusPath: parseBatteryDbusPath,
    parseWattsRate: parseWattsRate,
    appendDrainSample: appendDrainSample,
    defaultHzForProfile: defaultHzForProfile,
    hzSettingKey: hzSettingKey,
    normalizeHz: normalizeHz,
    hzForProfile: hzForProfile,
    parseOverrideHz: parseOverrideHz,
    prettyProfile: prettyProfile,
    probeSourceFromExit: probeSourceFromExit,
    effectiveSource: effectiveSource,
    sourceConflict: sourceConflict
  }
}
