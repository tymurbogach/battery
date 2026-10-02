import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "cyberdyne.battery"
  ipcTarget: "cyberdyne.battery"
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

  // ---- Ownership note. Power-profile auto-switch on plug/unplug belongs
  // to the first-party omarchy.battery service; display refresh belongs to
  // hypr-refresh-auto (~/.local/bin). This widget never writes either one --
  // it only picks profiles manually, toggles the charge threshold, and shows
  // read-only status. That keeps exactly one writer per subsystem.
  property bool chargeThresholdEnabled: false
  property var drainSamples: []
  property var currentMonitor: null

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
    return Model.batteryIcon(device, root.discharging, upowerStates())
  }

  function modeLabel() {
    var device = UPower.displayDevice
    return Model.modeLabel(device, root.discharging, upowerStates())
  }

  function profileIcon(name) {
    return Model.profileIcon(name)
  }

  readonly property bool fullyCharged: {
    var device = UPower.displayDevice
    return device && device.isPresent && device.state === UPowerDeviceState.FullyCharged && !root.chargeThresholdActive
  }
  readonly property bool discharging: {
    var device = UPower.displayDevice
    return !!(device && device.isPresent && UPower.onBattery)
  }
  readonly property bool chargeThresholdActive: {
    var device = UPower.displayDevice
    return Model.chargeThresholdActive(device, root.discharging, upowerStates())
  }
  readonly property bool batteryFull: fullyCharged || (!root.discharging && batteryFraction >= 1)
  readonly property bool batteryFlowIdle: batteryFull || chargeThresholdActive

  // 0..1 charge level, used by the visual progress bar.
  readonly property real batteryFraction: {
    var d = UPower.displayDevice
    return Model.batteryFraction(d)
  }

  readonly property bool charging: {
    var d = UPower.displayDevice
    return d && d.isPresent && !UPower.onBattery && !root.batteryFlowIdle
  }

  readonly property color batteryFillColor: {
    return root.bar ? root.bar.foreground : Color.foreground
  }

  // Source helpers: "ac" = powerON (plugged), "battery" = powerOFF.
  function sourceKey() {
    return root.discharging ? "battery" : "ac"
  }

  function sourceLabel() {
    return root.discharging ? "ON BATTERY" : "ON AC"
  }

  function updateSettings(patch) {
    root.settings = Object.assign({}, root.settings, patch)
    if (root.bar && root.bar.shell) root.bar.shell.updateEntryInline(root.moduleName, root.settings)
  }

  readonly property string buttonTooltip: {
    if (!batteryPresent) return ""
    var pct = root.batteryInfo.percentage || Math.round(root.batteryFraction * 100) + "%"
    var src = root.discharging ? "Battery" : "AC"
    var extra = root.batteryInfo.time ? " · " + root.batteryInfo.time : ""
    return src + " · " + pct + extra
  }

  readonly property string monitorStatusText: {
    if (!root.currentMonitor) return "Detecting display…"
    var hz = Math.round(Number(root.currentMonitor.refreshRate || 0))
    return (root.currentMonitor.name || "Display") + " · now " + (hz > 0 ? hz + "Hz" : "—")
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
    if (discharging) return onBatteryPhrases
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

    if (!batteryProc.running) batteryProc.running = true
    if (!profilesProc.running) profilesProc.running = true
    if (!systemProc.running) systemProc.running = true
  }

  function updateKeyValue(raw, targetName) {
    var next = Model.parseKeyValue(raw)
    // Keep last known good data if a refresh briefly returns nothing — happens
    // around AC plug/unplug events. Avoids the section collapsing mid-transition.
    if (Object.keys(next).length === 0) return
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
    if (parsed.profiles.length === 0) return
    profiles = parsed.profiles
    activeProfile = parsed.activeProfile
    profileIndex = parsed.profileIndex
    if (opened && !cursorActive) {
      var idx = profiles.indexOf(activeProfile)
      if (idx >= 0) profileIndex = idx
    }
  }

  // Manual pick for the current source (powerON = AC, powerOFF = battery).
  // omarchy-powerprofiles-set persists it in the native per-source state
  // file; the omarchy.battery service restores it automatically on the next
  // plug/unplug switch. This widget never auto-applies profiles itself.
  function setProfile(profile) {
    if (!profile || actionProc.running) return
    actionProc.command = ["omarchy-powerprofiles-set", root.sourceKey(), profile]
    actionProc.running = true
  }

  // Read-only monitor discovery for the status line. Refresh rate is owned
  // by hypr-refresh-auto -- this never writes monitor configuration.
  function handleMonitorsOutput(text) {
    var monitors = []
    try { monitors = JSON.parse(String(text || "[]")) } catch (e) { monitors = [] }
    for (var i = 0; i < monitors.length; i++) {
      if (monitors[i] && monitors[i].focused) {
        root.currentMonitor = monitors[i]
        return
      }
    }
    if (monitors.length > 0) root.currentMonitor = monitors[0]
  }

  function togglePercentage() {
    root.updateSettings({ showPercentage: !root.showPercentage })
  }

  // ---- Charge threshold toggle. Calls UPower's own EnableChargeThreshold
  // DBus method (UPower ships its own polkit policy for it) rather than
  // writing the sysfs threshold file directly, which is root-owned. The
  // percentages themselves (e.g. 75-80%) stay as firmware reports them --
  // this only flips whether the limit is enforced.
  function refreshChargeThreshold() {
    if (!root.batteryInfo.threshold) return
    chargeThresholdReadProc.command = ["bash", "-c",
      'gdbus call --system --dest org.freedesktop.UPower --object-path "$(upower -e | grep BAT | head -1)" --method org.freedesktop.DBus.Properties.Get org.freedesktop.UPower.Device ChargeThresholdEnabled']
    chargeThresholdReadProc.running = true
  }

  function toggleChargeThreshold() {
    if (chargeThresholdActionProc.running) return
    var next = !root.chargeThresholdEnabled
    chargeThresholdActionProc.command = ["bash", "-c",
      'gdbus call --system --dest org.freedesktop.UPower --object-path "$(upower -e | grep BAT | head -1)" --method org.freedesktop.UPower.Device.EnableChargeThreshold "$1"',
      "_", next ? "true" : "false"]
    chargeThresholdActionProc.running = true
  }

  function recordDrainSample() {
    var watts = Model.parseWattsRate(root.batteryInfo.rate)
    root.drainSamples = Model.appendDrainSample(root.drainSamples, watts, Date.now() / 1000, 600)
  }

  IpcHandler {
    target: "cyberdyne.battery"

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
      if (!monitorReadProc.running) monitorReadProc.running = true
      var idx = profiles.indexOf(activeProfile)
      profileIndex = idx >= 0 ? idx : 0
      cursorActive = false
    }
  }

  onBatteryPresentChanged: if (!batteryPresent) close()

  visible: batteryPresent
  implicitWidth: batteryPresent ? button.implicitWidth : 0
  implicitHeight: batteryPresent ? button.implicitHeight : 0

  Process {
    id: batteryProc
    command: ["omarchy-battery-status", "--shell"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.updateKeyValue(text, "battery") }
  }

  Process {
    id: profilesProc
    command: ["omarchy-powerprofiles-list", "--active-state"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.updateProfiles(text) }
  }

  Process {
    id: systemProc
    command: ["omarchy-system-stats"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.updateKeyValue(text, "system") }
  }

  Process {
    id: actionProc
    onExited: root.refresh()
  }

  Process {
    id: chargeThresholdReadProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var value = Model.parseGdbusBoolean(text)
        if (value !== null) root.chargeThresholdEnabled = value
      }
    }
  }

  Process { id: chargeThresholdActionProc; onExited: root.refreshChargeThreshold() }

  // Read-only: feeds the refresh status line. Never writes monitors.
  Process {
    id: monitorReadProc
    command: ["hyprctl", "monitors", "-j"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.handleMonitorsOutput(text) }
  }

  Component.onCompleted: {
    if (root.batteryPresent && !monitorReadProc.running) monitorReadProc.running = true
  }

  Timer { interval: 5000; running: root.opened; repeat: true; onTriggered: root.refresh() }

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
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.showPercentage && !vertical
      ? Math.round(root.batteryFraction * 100) + "% " + root.batteryIcon()
      : root.batteryIcon()
    slotSize: Style.bar.iconSlot * (root.showPercentage && !vertical ? 2 : 1)
    tooltipText: root.buttonTooltip
    onPressed: function(b) {
      if (!root.batteryPresent) return
      if (b === Qt.RightButton) root.togglePercentage()
      else root.toggle()
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
            color: root.bar.foreground
            font.family: root.bar.fontFamily
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
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }

            Text {
              id: heroStatus
              textFormat: Text.PlainText
              text: root.heroStatusText.toUpperCase()
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
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
            color: root.bar.foreground
            font.family: root.bar.fontFamily
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
            color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.12)
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
              alwaysRunToEnd: true
              NumberAnimation { from: 1.0; to: 0.55; duration: 950; easing.type: Easing.InOutSine }
              NumberAnimation { from: 0.55; to: 1.0; duration: 950; easing.type: Easing.InOutSine }
            }
          }
        }

        // ---------- Stats ----------
        // Visibility is intentionally only gated by "we've ever loaded data" so
        // the section never collapses mid-transition. fullyCharged is *not* part
        // of the condition: UPower briefly reports FullyCharged on plug-in when
        // the battery sits above the charge-control start threshold, and we
        // refuse to flicker the whole panel for that ~1s window.
        Row {
          visible: root.batteryInfo.percentage !== undefined
          width: parent.width
          spacing: Style.space(20)

          Column {
            width: (parent.width - parent.spacing) / 2
            spacing: Style.spacing.labelGap
            InfoPair { label: "Battery size"; value: root.batteryInfo.size || "" }
            InfoPair { label: "Charge cycles"; value: root.batteryInfo.cycles || "—" }
          }

          Column {
            width: (parent.width - parent.spacing) / 2
            spacing: Style.spacing.labelGap
            InfoPair {
              label: root.chargeThresholdActive ? "Charge limit" : (root.discharging ? "Time left" : "Time to full")
              value: root.chargeThresholdActive ? (root.batteryInfo.threshold || "-") : (root.batteryFlowIdle ? "-" : (root.batteryInfo.time || "—"))
            }
            InfoPair {
              label: root.chargeThresholdActive ? "Battery state" : (root.discharging ? "Discharging" : "Charging")
              value: root.chargeThresholdActive ? "Holding" : (root.batteryFull ? "-" : (root.batteryInfo.rate || ""))
            }
          }
        }

        // ---------- Power profile per source ----------
        PanelSeparator {
          foreground: root.bar.foreground
        }

        Column {
          width: parent.width
          spacing: Style.space(10)

          PanelSectionHeader {
            text: "POWER · " + root.sourceLabel()
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }

          Row {
            id: profileRow
            width: parent.width
            spacing: Style.space(6)

            readonly property real cellWidth: root.profiles.length > 0
              ? (width - spacing * (root.profiles.length - 1)) / root.profiles.length
              : 0

            Repeater {
              model: root.profiles
              Button {
                required property var modelData
                required property int index
                width: profileRow.cellWidth
                iconText: root.profileIcon(String(modelData))
                iconSize: Style.font.title
                text: String(modelData).charAt(0).toUpperCase() + String(modelData).slice(1)
                fontSize: Style.font.bodySmall
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
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
            text: "Auto-switch on plug/unplug is handled by the system service"
            color: root.bar.foreground
            opacity: 0.6
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideRight
            width: parent.width
          }
        }

        // ---------- Refresh rate (read-only). Owned by hypr-refresh-auto. ---
        Column {
          width: parent.width
          spacing: Style.space(10)

          PanelSeparator { foreground: root.bar.foreground }

          PanelSectionHeader {
            text: "DISPLAY REFRESH"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }

          Text {
            textFormat: Text.PlainText
            text: root.monitorStatusText
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideRight
            width: parent.width
          }

          Text {
            textFormat: Text.PlainText
            text: "Managed by hypr-refresh-auto (120Hz AC · 60Hz battery)"
            color: root.bar.foreground
            opacity: 0.6
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideRight
            width: parent.width
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

            PanelSeparator { foreground: root.bar.foreground }

            Toggle {
              width: parent.width
              label: "Charge threshold"
              description: root.batteryInfo.threshold
                ? ("Hold at " + root.batteryInfo.threshold + " to protect battery health")
                : "Hold charge below the firmware limit"
              checked: root.chargeThresholdEnabled
              foreground: root.bar.foreground
              accent: Color.accent
              fontFamily: root.bar.fontFamily
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

            PanelSeparator { foreground: root.bar.foreground }

            Item {
              width: parent.width
              implicitHeight: Math.max(drainHeader.implicitHeight, drainNow.implicitHeight)

              PanelSectionHeader {
                id: drainHeader
                text: "POWER DRAW (LAST 10 MIN)"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              // A flat near-zero line reads as "broken" without this --
              // the number makes a quiet graph legible on its own.
              InfoValue {
                id: drainNow
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: root.drainSamples.length > 0
                  ? root.drainSamples[root.drainSamples.length - 1].w.toFixed(1) + "W"
                  : ""
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
                if (samples.length < 2) return
                var maxW = 0
                for (var i = 0; i < samples.length; i++) maxW = Math.max(maxW, samples[i].w)
                if (maxW <= 0) maxW = 1
                var minT = samples[0].t
                var maxT = samples[samples.length - 1].t
                var spanT = Math.max(1, maxT - minT)
                var plotHeight = height - topInset - bottomInset

                ctx.strokeStyle = Style.selectedStateColor(root.bar.foreground, Color.accent)
                ctx.lineWidth = 1.5
                ctx.beginPath()
                for (var j = 0; j < samples.length; j++) {
                  var x = ((samples[j].t - minT) / spanT) * width
                  var y = topInset + plotHeight - (samples[j].w / maxW) * plotHeight
                  if (j === 0) ctx.moveTo(x, y)
                  else ctx.lineTo(x, y)
                }
                ctx.stroke()
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
              color: root.bar.foreground
              opacity: 0.6
              font.family: root.bar.fontFamily
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

    InfoLabel { text: label }
    Item { width: Math.max(0, parent.width - parent.children[0].implicitWidth - parent.children[2].implicitWidth - parent.spacing * 2); height: 1 }
    InfoValue { text: value }
  }

  component InfoLabel: Text {
    textFormat: Text.PlainText
    color: root.bar.foreground
    opacity: 0.6
    font.family: root.bar.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  component InfoValue: Text {
    textFormat: Text.PlainText
    color: root.bar.foreground
    font.family: root.bar.fontFamily
    font.pixelSize: Style.font.bodySmall
  }
}
