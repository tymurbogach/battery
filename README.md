# Battery (cyberdyne.battery)

Independent battery bar widget for [Omarchy](https://omarchy.org/), cloned from the built-in `omarchy.power` and extended with per-source memory.

## Features

Base from `omarchy.power`, unchanged:

- Battery percentage with animated charge bar and status icon.
- Battery size, charge cycles, time to full/empty, charge rate.
- Charge-threshold *detection* (shows Holding when firmware protection is active).
- Power-profile picker (power-saver / balanced / performance).
- Right-click toggles percentage, tooltip shows source plus time.

New in this plugin:

- **powerON / powerOFF memory** — AC and battery each remember their own profile. Picking a profile saves it into that source slot (plugin settings mirror plus the native `omarchy-powerprofiles-set ac|battery` state file). Unplugging restores the battery slot automatically, plugging in restores the AC slot.
- **Refresh rate per source** — 60Hz or 120Hz for AC and for battery independently. Applies via `hyprctl keyword monitor` with resolution, position, and scale untouched. The monitor is discovered from `hyprctl monitors -j` (focused first), never hardcoded.
- **Charge-threshold toggle** — on/off through UPower's own `EnableChargeThreshold` DBus method. Only shown when the battery reports a configured threshold (e.g. 75-80%). Percentages stay as firmware reports them.
- **Power draw plus health** — 10-minute in-memory sparkline with live watts, plus a health line (cycles, limit, size). No database, gone on shell restart.
- **Low-battery nudge** — one `notify-send` at 25% and one critical at 15% per discharge cycle.

No Quick Dim, no Travel Mode, no GPU status. Those were deliberate omissions.

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
- The `AC remembers X · Batt remembers Y` line shows both slots.
- Under Display Refresh, pick 60/120 per source. The choice for the inactive source applies on the next plug/unplug switch.
- Flip Charge threshold only when the row is visible (hardware must report a threshold).
- The bottom graph needs the panel open for a few samples before it draws.

## How it works

- **Profiles**: `omarchy-powerprofiles-set <ac|battery> <profile>` on manual pick (writes the native state file and the plugin setting). On `UPower.onBattery` change, the plugin restores the remembered profile for the new source, falling back to `omarchy-powerprofiles-set <source>` (native restore) when no mirror exists.
- **Refresh**: `hyprctl monitors -j` to find the focused monitor, then `hyprctl keyword monitor <name>,<WxH>@<Hz>,<XxY>,<scale>` with only Hz changed.
- **Threshold**: `gdbus call` against `org.freedesktop.UPower` for `ChargeThresholdEnabled` read and `EnableChargeThreshold` write, targeting `upower -e | grep BAT`.
- **Draw history**: reuses the `rate` field from every `omarchy-battery-status --shell` sample in a rolling 600s window.
- **Settings**: `showPercentage`, `profileAc`, `profileBatt`, `refreshAc` (default 120), `refreshBatt` (default 60). Stored inline on the bar entry via `updateEntryInline`.

## External dependencies

`omarchy-battery-status`, `omarchy-powerprofiles-list`, `omarchy-powerprofiles-set`, `omarchy-system-stats`, `hyprctl`, `gdbus`, `upower`, `notify-send`. All standard on Omarchy. No network, no elevated privileges beyond UPower polkit for the threshold toggle.

## Uninstalling

```
omarchy plugin remove cyberdyne.battery
```

Re-add `omarchy.power` to the bar if you want the stock widget back. Removal leaves the native `~/.local/state/omarchy/powerprofiles/` files untouched (they belong to Omarchy, not to this plugin).

## Changelog

See [CHANGELOG.md](CHANGELOG.md).

## License

MIT — see [LICENSE](LICENSE).
