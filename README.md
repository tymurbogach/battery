# Battery (cyberdyne.battery)

Independent battery bar widget for [Omarchy](https://omarchy.org/), cloned from the built-in `omarchy.power` and extended with a charge-threshold toggle and a power-draw history.

One writer per subsystem: profile auto-switch belongs to the first-party `omarchy.battery` service, display refresh belongs to `hypr-refresh-auto`. This widget only adds a sysfs AC watch as a fallback switch path, because UPower's `OnBattery` signal goes stale on some hardware (see Known issues).

## Features

Base from `omarchy.power`, unchanged:

- Battery percentage with animated charge bar and status icon.
- Battery size, charge cycles, time to full/empty, charge rate.
- Charge-threshold *detection* (shows Holding when firmware protection is active).
- Power-profile picker (power-saver / balanced / performance).
- Right-click toggles percentage, tooltip shows source plus time.

New in this plugin:

- **Manual profile picker per source** — click a pill to set the profile for the current source (powerON = AC, powerOFF = battery) via `omarchy-powerprofiles-set`. The choice persists in the native per-source state file and the `omarchy.battery` service restores it automatically on plug/unplug.
- **Sysfs AC watch (fallback auto-switch)** — polls `omarchy-power-present` every 10s and runs the same native restore command the system service runs when the cable state changes. Same target profile, idempotent, no settings mirror. The panel shows the cable state as seen by sysfs.
- **Refresh status (read-only)** — shows the focused monitor and its current refresh rate. Switching (120Hz AC, 60Hz battery) is owned by `hypr-refresh-auto`, not by this widget.
- **Charge-threshold toggle** — on/off through UPower's own `EnableChargeThreshold` DBus method. Only shown when the battery reports a configured threshold (e.g. 75-80%). Percentages stay as firmware reports them.
- **Power draw plus health** — 10-minute in-memory sparkline with live watts, plus a health line (cycles, limit, size). No database, gone on shell restart.

No Quick Dim, no Travel Mode, no GPU status, no low-battery notifier (the system service already warns at 10%). Those are deliberate omissions.

## Install

```
omarchy plugin add ~/Projects/battery --enable
```

Or from a git remote once published:

```
omarchy plugin add https://github.com/<you>/battery.git --enable
```

Then put it on the bar (replaces `omarchy.power` or `io.github.aryan-techie.battery`):

```
omarchy bar move cyberdyne.battery --section right
```

## Usage

- Click the bar pill to open the panel, click a profile pill to set it for the current source.
- The header shows which source is active (`POWER · ON AC` or `POWER · ON BATTERY`).
- The refresh line is informational only; `hypr-refresh-auto` owns switching.
- Flip Charge threshold only when the row is visible (hardware must report a threshold).
- The bottom graph needs the panel open for a few samples before it draws.

## How it works

- **Profiles**: `omarchy-powerprofiles-set <ac|battery> <profile>` on manual pick (writes the native state file). The first-party `omarchy.battery` service restores the remembered profile on `UPower.onBattery` change; this widget repeats the same native restore on sysfs cable change as a fallback.
- **Refresh**: read-only via `hyprctl monitors -j` (focused monitor first). Never written by this widget.
- **Threshold**: `gdbus call` against `org.freedesktop.UPower` for `ChargeThresholdEnabled` read and `EnableChargeThreshold` write, targeting `upower -e | grep BAT`.
- **Draw history**: reuses the `rate` field from every `omarchy-battery-status --shell` sample in a rolling 600s window.
- **Settings**: only `showPercentage`. Stored inline on the bar entry via `updateEntryInline`.

## External dependencies

`omarchy-battery-status`, `omarchy-powerprofiles-list`, `omarchy-powerprofiles-set`, `omarchy-system-stats`, `omarchy-power-present`, `hyprctl`, `gdbus`, `upower`. All standard on Omarchy. No network, no elevated privileges beyond UPower polkit for the threshold toggle.

## Known issues

- **Stale UPower AC record**: on some hardware UPower's `line_power_AC` stops updating (`online: yes`, tens of minutes old) while sysfs already reports the unplug, so `OnBattery` never flips and UPower-based icons/mode labels can claim "Charging" while draining. The profile fallback in this widget deliberately uses sysfs instead. A one-time `sudo systemctl restart upower` re-reads sysfs; if it recurs, it is an upstream UPower/udev event-delivery issue.

## Uninstalling

```
omarchy plugin remove cyberdyne.battery
```

Re-add `omarchy.power` to the bar if you want the stock widget back. Removal leaves the native `~/.local/state/omarchy/powerprofiles/` files untouched (they belong to Omarchy, not to this plugin).

## Changelog

See [CHANGELOG.md](CHANGELOG.md).

## License

MIT — see [LICENSE](LICENSE).
