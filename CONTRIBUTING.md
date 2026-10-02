# Contributing to battery (cyberdyne.battery)

Keep changes small and reversible. One concern per commit.

## Rules

- Write English in commits and docs.
- Use imperative commits (`Fix threshold read`, not `Fixed`).
- Do not commit symlinks, install hooks, or privilege changes.
- Do not bundle the optional daemons (`hypr-profile-auto`, `hypr-refresh-auto`). Document them instead.
- Keep `manifest.json`, `README.md`, and `CHANGELOG.md` in sync on every version bump.

## Verify before push

Run from the repo root:

```bash
omarchy plugin validate .
qmllint -I "$OMARCHY_PATH/shell" Panel.qml
```

From-zero install against the exact ID:

```bash
omarchy plugin disable cyberdyne.battery
omarchy plugin remove cyberdyne.battery --yes
test ! -e "$HOME/.config/omarchy/plugins/cyberdyne.battery"
omarchy plugin add <repo-or-path> --enable --yes
omarchy restart shell
```

Then check the visible feature, `omarchy plugin list --json`, disable, enable, restart, and removal. Compare `~/.local/state/omarchy/toggles/hypr/refresh-override-hz` against its baseline.

## Pure logic

`Model.js` exports through `module.exports` for Node. Test it with:

```bash
node -e "const M=require('./Model.js'); console.log(M.batteryFraction({isPresent:true,percentage:0.79}))"
```
