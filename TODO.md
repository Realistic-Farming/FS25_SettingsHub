# FS25_SettingsHub TODO

Open and recently closed implementation items. Newest at the bottom. Created 2026-10-05 (see ROADMAP.md).

## MAINTENANCE row 217: enum options over the network (2026-10-05)

- [x] `src/SettingsHub.lua`: `_snapNetworkValue`, used before `_validate` in `applyAdminChangeFromNetwork` and `onReadState`.
- [x] Bar: `tools/test/lua/maint217_enum_float32_snap_test.lua` drives the real admin event through a float32 stream into the server hub, and the hub's own NetworkSync registration with NetworkSync's tagged encoding into the client hub. `tools/test/lua/prelude.lua` gains the `Event` and `InitEventClass` stubs the event file needs to load.
- [~] In game (owed): on a multiplayer server, a client admin sets a percentage-style enum option (one whose value is a fraction such as 0.8) and the host and every client show it; the host changes it back and every client follows.
