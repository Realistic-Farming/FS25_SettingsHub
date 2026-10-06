# FS25_SettingsHub Roadmap

Implementation roadmap for the settings bedrock. Newest entries at the bottom. Created 2026-10-05 under the office rule that every fix carries its ROADMAP.md and TODO.md lines in the same PR; earlier work is in the git history and the tracking repo's implementation roadmap.

## 2026-10-05 (Fred): enum options survive the float32 network paths (MAINTENANCE row 217)

- [x] A number that is not whole crosses the network as float32: the admin event (`SettingsHubAdminEvent`) and NetworkSync's sync frames both write it with `streamWriteFloat32`. A declared enum option such as 0.8, 0.15 or 0.08 therefore arrived as 0.800000011920929 and the exact enum check refused it with no log: in multiplayer a client admin's change never applied on the server, and a host admin's change never reached the clients. `SettingsHub:_snapNetworkValue` now gives such a value back as the declared option it stands for, only within float32 rounding of that option (2^-23 of its size), on the two network paths: `applyAdminChangeFromNetwork` (server) and `onReadState` (client). A value no option explains is still refused. Float, int and bool settings are unchanged, and StateLedger's save path was already exact (it writes numbers with `%.17g`).
