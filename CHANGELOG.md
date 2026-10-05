# Changelog

Format loosely follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## Unreleased

### Added

- Single owner for power and Hz: sysfs-driven profile restore plus direct `hyprctl eval` apply with live geometry. No `~/.local/bin` daemon needed.
- Shared Hz contract for the future display plugin: single-rate override file plus per-profile keys, watched instantly on both sides.
- Catch-up burst for the live `now` rate (immediate plus 2.5s plus 8s) after open, cable event, file change, or apply. Coalesced reads instead of silent drops.

### Removed

- Dependency on `hypr-profile-auto` and `hypr-refresh-auto`. Delete them plus their `autostart.lua` lines on upgrade. The 30s monitor poll is gone.

### Fixed

- Queue refresh-rate writes so rapid changes persist only the newest value.
- Apply a selected profile's refresh rate only after its profile command succeeds.
- Preserve the last valid power source when `omarchy-power-present` exits unexpectedly.
- Track battery and profile refresh failures independently before showing `STALE`.

### Changed

- Use the sysfs-arbitrated source for source-dependent icon, status, and panel text.
- Show whether the optional profile and refresh daemons are available.

## v0.7.0 — Instant AC/battery reaction

### Added

- Instant source reaction in three layers: UPower `onBatteryChanged` signal, kernel uevents via `udevadm monitor --subsystem-match=power_supply` (panel-open only, 500ms debounce), and the 15s poll as safety net.
- Sysfs arbitration: every trigger runs one-shot `omarchy-power-present`. The probe wins disagreements, profile writes use the effective source, and the banner shows `SYSFS ▸ … (UPower stale)` on conflict.
- Drain sparkline records on the effective (sysfs-arbitrated) source, so a stale UPower record cannot poison the graph.
- Marketplace README: hook, click table, screenshots (`preview.png` plus `docs/images/`), per-key configure table, update instructions.
- Install defaults to the far right end (`--section right --index 99`) with reposition anchors documented.

### Fixed

- `fg` / `ff` self-reference binding (bar null guard pointed at itself). All themed colors now resolve correctly.

## v0.6.0 — Silent-failure hardening

### Fixed

- `NaN` guards on fraction, icon, tooltip, button text, and sparkline. Unknown state renders `—` or `Unknown`, never `NaN%`.
- Charge-threshold false positive without telemetry. Missing `changeRate` no longer reports `Threshold`.
- Threshold D-Bus calls use plain argv in two steps (`upower -e` resolve, then `gdbus`). No shell interpolation. Polkit denials and read failures show in the panel.
- `bar` null guards via `fg` / `ff` helpers (startup and recreation window).
- Every `Process` reports `stderr` and non-zero exit. `STALE` banner after 2 consecutive failures. 10s watchdog kills hung queries.
- `hzAppliedFor` marks only on successful override write. Profile buttons disable while a switch runs.
- `0W` samples count. Drain records discharge only. Window capped at 200 samples. Clock jumps reset instead of growing.
- Polling: CLI fields every 15s, monitor rate every 30s (was 5s triple poll).

### Changed

- Left/middle click split: left toggles the panel, right toggles percentage. Middle click no longer opens the panel.
- Placeholders unified to `—`. `InfoPair` no longer uses positional child indexes.
- Phrase animation stops on panel close. Charge pulse no longer uses `alwaysRunToEnd`.
- README gains `Configure`, `Requirements`, and `Remove` sections. Daemons documented as optional and not bundled. Legacy `refreshAc` / `refreshBatt` documented as ignored.

## v0.5.0 — Per-profile 120Hz toggle

### Added

- Single 120Hz on/off toggle saved independently per power profile (defaults saver 60, balanced/performance 120). Writes the override file `refresh-override-hz` that `hypr-refresh-auto` enforces; picking a profile, flipping the toggle, or opening the panel with a changed active profile applies that profile's rate.
- `hypr-refresh-auto` honors the override (60/120 win over source logic; missing or invalid file falls back to 120Hz AC / 60Hz battery). Verified live: 60, 120, garbage, and removal all behave.

### Removed

- Display-refresh read-only section (replaced by the toggle, whose subtitle shows the live rate).

## v0.4.0 — Daemon owns auto-switch

### Added

- `hypr-profile-auto` (`~/.local/bin`, sysfs poll every 5s, switch log): verified end-to-end against a fake power supply (AC/battery flips switch profiles correctly).

### Removed

- QML AC watch and cable status line (a QML Timer/Process poll proved unobservable and unreliable in this shell; the daemon replaces it with the same pattern as the proven `hypr-refresh-auto`).

## v0.3.0 — Sysfs AC watch

### Added

- Fallback auto-switch: 10s sysfs poll (`omarchy-power-present`) running the native per-source restore on cable change. Same command the system service runs, idempotent, no mirror. Works around stale UPower `OnBattery` (observed: `line_power_AC` 70min stale, `online:yes`, while sysfs said unplugged).
- Cable status line in the panel (`Cable: plugged/unplugged (sysfs)`).

## v0.2.0 — One writer per subsystem

### Removed

- Display-refresh writer (`hyprctl keyword monitor` does not work with the Lua parser, and `hypr-refresh-auto` already owns refresh). The panel now shows refresh read-only.
- Profile auto-switch and AC/battery settings mirror (the first-party `omarchy.battery` service owns it; the mirror risked applying stale profiles).
- Low-battery notifier (the system service already warns at 10% through the official channel).
- Debug logging.

## v0.1.0 — Initial release

### Added

- Clone of built-in `omarchy.power` (hero, progress bar, stats, profile picker, phrases) under independent id `cyberdyne.battery`.
- powerON/powerOFF: independent AC/battery profile memory with auto-restore on plug/unplug.
- Display refresh per source (60/120Hz) with focused-monitor discovery, no hardcoded output name.
- Charge-threshold on/off toggle via UPower, gated on reported threshold.
- Power-draw sparkline (10 min) plus health line (cycles, limit, size).
- Low-battery notify-send at 25% and 15% per discharge cycle.
- Improved bar tooltip (source, percentage, time).
