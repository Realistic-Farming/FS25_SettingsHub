# FS25_SettingsHub TODO

Open and recently closed implementation items. Newest at the bottom. Created 2026-10-05 (see ROADMAP.md).

## MAINTENANCE row 217: enum options over the network (2026-10-05)

- [x] `src/SettingsHub.lua`: `_snapNetworkValue`, used before `_validate` in `applyAdminChangeFromNetwork` and `onReadState`.
- [x] Bar: `tools/test/lua/maint217_enum_float32_snap_test.lua` drives the real admin event through a float32 stream into the server hub, and the hub's own NetworkSync registration with NetworkSync's tagged encoding into the client hub. `tools/test/lua/prelude.lua` gains the `Event` and `InitEventClass` stubs the event file needs to load.
- [~] In game (owed): on a multiplayer server, a client admin sets a percentage-style enum option (one whose value is a fraction such as 0.8) and the host and every client show it; the host changes it back and every client follows.

## MAINTENANCE row 241: the bedrock binding (2026-10-07)

- [x] `src/SettingsHub.lua`: `networkSyncHandle` / `stateLedgerHandle` (mission first), `_bindBedrock` binding each handle on its own, the broadcast in `applyAdminChangeFromNetwork`, `deserializeAdmin` skipping selfPersisted modules, `onReadState` calling `onChange` on a client only for a module that is not selfPersisted, `onWriteState` leaving out a nil value; `src/AdminControlRegistry.lua`: `networkSyncHandle`, `bindNetwork`, `invoke`.
- [x] Bar: `tools/test/lua/maint241_bedrock_binding_test.lua` runs `main.lua` and every file it sources in a mod environment shaped as the engine's, on a server and two clients, with NetworkSync and StateLedger present only on the mission; `tools/test/run-tests.mjs` gains `--!source:`. #23's bench puts its stand-ins on the mission. Battery `tools/test/mutate_maint241.py`.
- [~] In game (owed): on a dedicated server, a client admin steps Fertilizer Depot's Sell Price Ratio in the Tablet and every client follows; a difficulty dial survives a save and reload; `shStatus` prints both handles bound. This also opens row 217's client-admin check above.
