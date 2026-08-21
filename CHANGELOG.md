# Changelog

## 1.0.0 — 2026-08-21

First release. Extracted from a personal dotfiles repo into something
installable by someone else.

- `simmer <duration>` takes a lease on `pmset disablesleep` so the machine stays
  awake with the lid closed, and a LaunchAgent hands it back on the deadline, on
  a low battery, on `simmer down`, or when it finds the switch enabled with no
  lease behind it.
- `simmer budget --need 20m` answers *is there room to start this?* in the exit
  code — `0` room, `1` not enough, `3` no lease at all.
- `--owner` plus a refusal to replace another owner's lease without `--force`.
- Front-ends for SwiftBar, Raycast and Alfred, all shelling out to the one
  binary rather than reimplementing anything.
- Notifications post from a small bundled app, so they carry simmer's own name
  and icon instead of arriving as Script Editor.
- `SIMMER_FAKE_PMSET` / `SIMMER_FAKE_BATTERY` make the 43-assertion suite
  hermetic: no sudo, no real power state touched.

The lease file carries `format=1`. If its shape ever changes, that number moves
with it.
