# Changelog

Format loosely follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## v0.1.0 — Initial release

### Added

- Clone of built-in `omarchy.power` (hero, progress bar, stats, profile picker, phrases) under independent id `cyberdyne.battery`.
- powerON/powerOFF: independent AC/battery profile memory with auto-restore on plug/unplug.
- Display refresh per source (60/120Hz) with focused-monitor discovery, no hardcoded output name.
- Charge-threshold on/off toggle via UPower, gated on reported threshold.
- Power-draw sparkline (10 min) plus health line (cycles, limit, size).
- Low-battery notify-send at 25% and 15% per discharge cycle.
- Improved bar tooltip (source, percentage, time).
