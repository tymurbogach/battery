# Battery (cyberdyne.battery)

Independent battery bar widget for [Omarchy](https://omarchy.org/), cloned from the built-in `omarchy.power` and extended with a charge-threshold toggle and a power-draw history.

One writer per subsystem: profile auto-switch belongs to `hypr-profile-auto` (`~/.local/bin`, sysfs signal), display refresh belongs to `hypr-refresh-auto`. This widget picks profiles manually, toggles the threshold, and shows read-only status.

## Features

Base from `omarchy.power`, unchanged:

- Battery percentage with animated charge bar and status icon.
- Battery size, charge cycles, time to full/empty, charge rate.
- Charge-threshold *detection* (shows Holding when firmware protection is active).
- Power-profile picker (power-saver / balanced / performance).
- Right-click toggles percentage, tooltip shows source plus time.

New in this plugin:

- **Manual profile picker per source** — click a pill to set the profile for the current source (powerON = AC, powerOFF = battery) via `omarchy-powerprofiles-set`. The choice persists in the native per-source state file; `hypr-profile-auto` restores it automatically on plug/unplug.
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

- **Profiles**: `omarchy-powerprofiles-set <ac|battery> <profile>` on manual pick (writes the native state file). `hypr-profile-auto` polls `omarchy-power-present` (sysfs) every 5s and restores the remembered profile on cable change, logging to `~/.local/state/omarchy/powerprofiles/ac-watch.log`.
- **Refresh**: the toggle stores 60/120 per profile in settings and writes `~/.local/state/omarchy/toggles/hypr/refresh-override-hz`, which `hypr-refresh-auto` enforces (overriding its AC=120/battery=60 source logic). Live rate shown read-only via `hyprctl monitors -j`.
- **Threshold**: `gdbus call` against `org.freedesktop.UPower` for `ChargeThresholdEnabled` read and `EnableChargeThreshold` write, targeting `upower -e | grep BAT`.
- **Draw history**: reuses the `rate` field from every `omarchy-battery-status --shell` sample in a rolling 600s window.
- **Settings**: `showPercentage`, `hz_power-saver`, `hz_balanced`, `hz_performance`. Stored inline on the bar entry via `updateEntryInline`.

## External dependencies

`omarchy-battery-status`, `omarchy-powerprofiles-list`, `omarchy-powerprofiles-set`, `omarchy-system-stats`, `hyprctl`, `gdbus`, `upower`. All standard on Omarchy. No network, no elevated privileges beyond UPower polkit for the threshold toggle.

## Known issues

- **Stale UPower AC record**: on this hardware UPower's `line_power_AC` stops updating (seen `online: yes` 70min stale while sysfs said unplugged), so `OnBattery` never flips and UPower-based icons/mode labels can claim "Charging" while draining. Profile switching deliberately uses sysfs (`hypr-profile-auto`) instead. A one-time `sudo systemctl restart upower` re-reads sysfs; if it recurs, it is an upstream UPower/udev event-delivery issue.

## Uninstalling

```
omarchy plugin remove cyberdyne.battery
```

Re-add `omarchy.power` to the bar if you want the stock widget back. Removal leaves the native `~/.local/state/omarchy/powerprofiles/` files untouched (they belong to Omarchy, not to this plugin). Also delete the refresh override if you no longer want per-profile rates:

```
rm -f ~/.local/state/omarchy/toggles/hypr/refresh-override-hz
```

(without it, `hypr-refresh-auto` falls back to 120Hz on AC / 60Hz on battery).

## Changelog

See [CHANGELOG.md](CHANGELOG.md).

## License

MIT — see [LICENSE](LICENSE).
