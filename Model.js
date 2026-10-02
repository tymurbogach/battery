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
  var lines = String(raw || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var idx = lines[i].indexOf("\t")
    if (idx <= 0) continue
    next[lines[i].substring(0, idx)] = lines[i].substring(idx + 1).trim()
  }
  return next
}

function parseProfiles(raw, previousIndex) {
  var lines = String(raw || "").split("\n")
  var list = []
  var active = ""
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (!line) continue
    var parts = line.split("\t")
    list.push(parts[0])
    if (parts[1] === "1") active = parts[0]
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

function batteryFraction(device) {
  return device && device.isPresent ? Math.max(0, Math.min(1, device.percentage)) : 0
}

function chargeThresholdActive(device, onBattery, states) {
  var d = device || {}
  var s = states || {}
  if (!(d && d.isPresent && !onBattery)) return false

  var fraction = batteryFraction(d)
  if (d.state === s.Discharging) return false
  if (d.state === s.PendingCharge) return true
  if (d.state === s.FullyCharged && fraction < 0.99) return true
  if (d.state !== s.Charging || fraction >= 0.99) return false

  return Number(d.changeRate || 0) <= 0.2 || Number(d.timeToFull || 0) >= 8 * 60 * 60
}

function batteryIcon(device, onBattery, states) {
  var d = device || {}
  if (!d.isPresent) return ""

  var chargingIcons = ["󰢜", "󰂆", "󰂇", "󰂈", "󰢝", "󰂉", "󰢞", "󰂊", "󰂋", "󰂅"]
  var defaultIcons = ["󰁺", "󰁻", "󰁼", "󰁽", "󰁾", "󰁿", "󰂀", "󰂁", "󰂂", "󰁹"]
  var index = Math.max(0, Math.min(9, Math.floor(d.percentage * 10)))
  var threshold = chargeThresholdActive(d, onBattery, states)

  if (threshold) return defaultIcons[index]
  if (d.state === states.FullyCharged) return "󰂅"
  if (!onBattery) return chargingIcons[index]
  return defaultIcons[index]
}

function modeLabel(device, onBattery, states) {
  var d = device || {}
  if (!d.isPresent) return ""

  var percentage = d.isPresent ? d.percentage : 0
  if (chargeThresholdActive(d, onBattery, states)) return "Threshold"
  if (onBattery) return "On battery"
  if (!onBattery && percentage >= 1) return "Fully charged"
  return "Charging"
}

// ---- Charge-threshold toggle. `gdbus call` prints a boolean property
// read as "(<true>,)" / "(<false>,)".
function parseGdbusBoolean(raw) {
  var text = String(raw || "")
  if (text.indexOf("true") !== -1) return true
  if (text.indexOf("false") !== -1) return false
  return null
}

// ---- Watts drain history: a short in-memory sparkline, not a database.
function parseWattsRate(rateText) {
  var value = parseFloat(String(rateText || ""))
  return isFinite(value) ? value : null
}

// Appends one sample and drops anything older than maxAgeSeconds -- a
// fixed-size rolling window instead of an ever-growing array.
function appendDrainSample(samples, watts, now, maxAgeSeconds) {
  var next = (samples || []).slice()
  if (watts !== null) next.push({ t: now, w: watts })
  var cutoff = now - maxAgeSeconds
  while (next.length > 0 && next[0].t < cutoff) next.shift()
  return next
}

// ---- Per-profile 120Hz toggle. Each power profile remembers its own
// refresh rate (60 or 120); hypr-refresh-auto enforces the override file.
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

if (typeof module !== "undefined") {
  module.exports = {
    clampIndex: clampIndex,
    selectProfileIndex: selectProfileIndex,
    parseKeyValue: parseKeyValue,
    parseProfiles: parseProfiles,
    profileIcon: profileIcon,
    batteryFraction: batteryFraction,
    chargeThresholdActive: chargeThresholdActive,
    batteryIcon: batteryIcon,
    modeLabel: modeLabel,
    parseGdbusBoolean: parseGdbusBoolean,
    parseWattsRate: parseWattsRate,
    appendDrainSample: appendDrainSample,
    defaultHzForProfile: defaultHzForProfile,
    hzSettingKey: hzSettingKey,
    normalizeHz: normalizeHz,
    hzForProfile: hzForProfile,
    prettyProfile: prettyProfile
  }
}
