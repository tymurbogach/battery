# Contributing to battery (tymurbogach.battery)

Keep changes small and reversible. One concern per commit.

## Rules

- Write English in commits and docs.
- Use imperative commits (`Fix threshold read`, not `Fixed`).
- Do not commit symlinks, install hooks, or privilege changes.
- Do not reintroduce `~/.local/bin` daemons. Profile restore and Hz apply belong to the panel.
- Keep `manifest.json`, `README.md`, and `CHANGELOG.md` in sync on every version bump.

## Verify before push

Run from the repo root:

```bash
omarchy plugin validate .
qmllint -I "$OMARCHY_PATH/shell" Panel.qml
node --test test/model.test.js
```

From-zero install against the exact ID:

```bash
omarchy plugin disable tymurbogach.battery
omarchy plugin remove tymurbogach.battery --yes
test ! -e "$HOME/.config/omarchy/plugins/tymurbogach.battery"
omarchy plugin add <repo-or-path> --enable --yes
omarchy restart shell
```

Then check the visible feature, `omarchy plugin list --json`, disable, enable, restart, and removal. Compare `~/.local/state/omarchy/toggles/hypr/refresh-override-hz` against its baseline.

## Pure logic

`Model.js` exports through `module.exports` for Node. Run its regression suite with:

```bash
node --test test/model.test.js
```

On a live shell, change the Hz toggle twice before the first write ends. The final override must match the final toggle state. Then fail a profile command and confirm that the override does not change.
