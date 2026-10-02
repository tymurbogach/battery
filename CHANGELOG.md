# Changelog

Format loosely follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

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
