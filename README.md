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

- **Manual profile picker per source** — click a pill to set the profile for the current source (powerON = AC, powerOFF = battery) via `omarchy-powerprofiles-set`. The choice persists in the native per-source state file. Buttons disable while a switch runs, and failures show in the panel banner.
- **Per-profile 120Hz toggle** — one on/off toggle saved independently per power profile (defaults saver 60, balanced/performance 120). The toggle writes `~/.local/state/omarchy/toggles/hypr/refresh-override-hz`, which the optional `hypr-refresh-auto` daemon enforces. The subtitle shows the live rate read-only via `hyprctl monitors -j`.
- **Charge-threshold toggle** — on/off through UPower's own `EnableChargeThreshold` DBus method. Only shown when the battery reports a configured threshold (e.g. 75-80%). Percentages stay as firmware reports them. Polkit denials show in the row instead of failing silently.
- **Power draw plus health** — 10-minute in-memory sparkline (discharge only, `0W` valid, max 200 samples), plus a health line (cycles, limit, size). No database, gone on shell restart.

No Quick Dim, no Travel Mode, no GPU status, no low-battery notifier (the system service already warns at 10%). Those are deliberate omissions.

## Install

```
omarchy plugin add ~/Projects/battery --enable
```

Or from a git remote once published:

```
omarchy plugin add https://github.com/tymurbogach/battery.git --enable
```

Then put it on the bar (replaces `omarchy.power` or `io.github.aryan-techie.battery`):

```
omarchy bar move cyberdyne.battery --section right
```

## Usage

- Click the bar pill to open the panel, click a profile pill to set it for the current source.
- The header shows which source is active (`POWER · ON AC` or `POWER · ON BATTERY`).
- Flip the 120Hz toggle to set the rate for the active profile. The daemon applies it within seconds.
- Flip Charge threshold only when the row is visible (hardware must report a threshold).
- The bottom graph needs the panel open for a few samples before it draws. It records only while discharging.
- If data goes stale, the panel shows a `STALE` banner with the last error instead of trusting old values.

## Configure

Settings live inline on the bar entry (via `updateEntryInline`):

- `showPercentage` (default `false`) — right-click the bar pill toggles it.
- `hz_power-saver` (default `60`), `hz_balanced` (default `120`), `hz_performance` (default `120`) — per-profile rate.

Legacy keys `refreshAc` / `refreshBatt` (v0.1.0) are ignored since v0.2.0. They stay orphaned in `shell.json` and cause no error. Delete them by hand if you want a clean entry.

## How it works

- **Profiles**: `omarchy-powerprofiles-set <ac|battery> <profile>` on manual pick (writes the native state file). The optional `hypr-profile-auto` daemon (`~/.local/bin`, not bundled) polls `omarchy-power-present` (sysfs) every 5s and restores the remembered profile on cable change, logging to `~/.local/state/omarchy/powerprofiles/ac-watch.log`. Without it, picks still persist per source but nothing auto-switches on plug/unplug.
- **Refresh**: the toggle stores 60/120 per profile in settings and writes `~/.local/state/omarchy/toggles/hypr/refresh-override-hz`, which the optional `hypr-refresh-auto` daemon (not bundled) enforces (overriding its AC=120/battery=60 source logic). Without it, the toggle still saves the setting but nothing applies it. Live rate shown read-only via `hyprctl monitors -j` (30s poll).
- **Threshold**: two plain-argv steps, no shell interpolation. First `upower -e` resolves the battery object path (prefers `battery_BAT0`, skips HID++ and line_power). Then `gdbus call` against `org.freedesktop.UPower` for `ChargeThresholdEnabled` read and `EnableChargeThreshold` write with that path.
- **Draw history**: reuses the `rate` field from every `omarchy-battery-status --shell` sample while discharging, in a rolling 600s window capped at 200 samples.
- **Polling**: CLI text fields refresh every 15s while the panel is open. A 10s watchdog kills hung queries so the next tick recovers. After 2 consecutive failures the panel marks data `STALE`.
- **Settings**: `showPercentage`, `hz_power-saver`, `hz_balanced`, `hz_performance`. Stored inline on the bar entry via `updateEntryInline`.

## Requirements

Required (standard on Omarchy): `omarchy-battery-status`, `omarchy-powerprofiles-list`, `omarchy-powerprofiles-set`, `omarchy-system-stats`, `hyprctl`, `gdbus`, `upower`, `bash` (only for the Hz override writer: `mkdir -p` plus `printf`). No network. No elevated privileges beyond the UPower polkit policy for the threshold toggle. If polkit denies the toggle, the panel shows the denial.

Optional (not bundled, local daemons): `hypr-profile-auto` and `hypr-refresh-auto` in `~/.local/bin`. The widget works without them, but auto-switch on plug/unplug and Hz enforcement stay inert.

## Known issues

- **Stale UPower AC record**: on this hardware UPower's `line_power_AC` stops updating (seen `online: yes` 70min stale while sysfs said unplugged), so `OnBattery` never flips and UPower-based icons/mode labels can claim "Charging" while draining. Profile switching deliberately uses sysfs (`hypr-profile-auto`) instead. A one-time `sudo systemctl restart upower` re-reads sysfs; if it recurs, it is an upstream UPower/udev event-delivery issue.

## Remove

```
omarchy plugin remove cyberdyne.battery
```

Re-add `omarchy.power` to the bar if you want the stock widget back. Removal leaves the native `~/.local/state/omarchy/powerprofiles/` files untouched (they belong to Omarchy, not to this plugin).

Plugin-owned state: `~/.local/state/omarchy/toggles/hypr/refresh-override-hz` (one file, the per-profile Hz override). Retention: kept across reinstalls so your per-profile rates survive. Removal: the plugin never deletes it silently. Confirm, then run once if you no longer want per-profile rates:

```
rm -f ~/.local/state/omarchy/toggles/hypr/refresh-override-hz
```

(without it, `hypr-refresh-auto` falls back to 120Hz on AC / 60Hz on battery).

## Changelog

See [CHANGELOG.md](CHANGELOG.md).

## License

MIT — see [LICENSE](LICENSE).
