# Battery

Per-source power profiles, per-profile Hz, charge cap, and drain history — in the bar.

![Battery panel](preview.png)

Needs: Omarchy · laptop with UPower battery · no network, no sudo.

## What you get

- **Per-source power profiles** — one pill per profile, remembered separately for AC and battery. Auto-switch built in.
- **Per-profile refresh rate** — each profile keeps its own 60/120Hz. Desired vs live in one line.
- **Charge-threshold toggle** — hold at the firmware limit to protect battery health.
- **Drain sparkline** — last 10 minutes of watts, no database.
- **No daemon** — the panel owns profile restore and Hz apply. Nothing runs in the background.

## Install

```
omarchy plugin add https://github.com/tymurbogach/battery.git --enable
omarchy bar move cyberdyne.battery --section right --index 99
omarchy restart shell
```

## Use

| Click | Action |
|---|---|
| Left click pill | Open / close the panel |
| Right click pill | Toggle percentage |
| Click profile pill | Set profile for the current source |
| Refresh rate toggle | Set rate for the active profile |
| Charge threshold toggle | Hold charge below the firmware limit |

- The header shows the active source (`POWER · ON AC` / `ON BATTERY`).
- Refresh reads `Balanced → 120Hz · now 120Hz`: desired left, live right, `applying…` while a change lands.
- Threshold shows only when the hardware reports one. Its state reads on every open.
- The graph records only while discharging.
- `STALE` means two failed refreshes in a row. `SYSFS ▸ …` means UPower disagrees and sysfs won.

## Settings

Inline on the bar entry:

| Key | Default |
|---|---|
| `showPercentage` | `false` |
| `hz_power-saver` | `60` |
| `hz_balanced` | `120` |
| `hz_performance` | `120` |

## How it works

- Cable change restores the remembered profile via `omarchy-powerprofiles-set` on a sysfs signal. No UPower, no daemon.
- Hz intent lives in `~/.local/state/omarchy/toggles/hypr/refresh-override-hz` plus the `hz_*` keys (shared contract with the future display plugin). The panel applies it with `hyprctl eval`.
- The live rate is re-read in a short burst after open, event, or apply. No permanent poll.
- Threshold uses UPower D-Bus (`EnableChargeThreshold`). A 10s watchdog kills hung queries.

## Update

```
omarchy plugin update cyberdyne.battery --yes
omarchy restart shell
```

## Remove

```
omarchy plugin remove cyberdyne.battery
```

Native profile files stay untouched. Delete `refresh-override-hz` by hand if you want the rates gone too.

## Changelog

See [CHANGELOG.md](CHANGELOG.md).

## License

MIT — see [LICENSE](LICENSE).
