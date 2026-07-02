# FS25_SettingsHub

**Version:** 1.0.0.0
**Author:** TisonK

The settings bedrock of the Realistic Farming mod ecosystem. SettingsHub is mod 4 in the load order. Companion mods hand it their settings and one callback; SettingsHub owns a throttled async queue so heavy setting changes (rebuilding a large array on a slider tick) apply smoothly in the background instead of freezing the Lua thread, and it routes admin-only changes through the server so multiplayer stays consistent.

There are no settings of its own to configure. Install it, keep it loaded, and let the companion mods use it.

## How companion mods use it

Register once, at init, guarding against SettingsHub being absent:

```lua
if g_settingsHub then
    g_settingsHub:registerModule("MyMod", {
        adminSettings = {
            { id = "difficulty", type = "int",  min = 1, max = 3, default = 2, adminOnly = true  },
            { id = "mode",       type = "enum", values = {"a","b"},  default = "a", adminOnly = true  },
            { id = "showHud",    type = "bool",                      default = true, adminOnly = false },
        },
        onChange = function(key, value, playerId)
            -- apply the change; runs deferred, max 2 per frame, inside pcall
        end,
    })
end

local v = g_settingsHub:getValue("MyMod", "difficulty")     -- read
g_settingsHub:setValue("MyMod", "difficulty", 3, playerId)  -- write (from the UI)
```

- Setting types: `bool`, `int` (min/max), `float` (min/max/step), `enum` (values list).
- **onChange** fires deferred (max 2 per frame, inside `pcall`), once per change and once per setting on load to apply restored values, so it must be safe to call on mission start and idempotent.
- **adminOnly = true**: server-shared. On a client, `setValue` sends a request to the server, which validates the master user, applies, persists, and broadcasts to all clients. Only a server-approved value ever fires the callback on a client.
- **adminOnly = false**: player-local. Applies immediately on this client and persists to SettingsHub's own local file. Per-player values stay local (there is no per-playerId server storage in this version).

## Persistence

- Admin (server-shared) values persist through StateLedger, inside the one atomic ecosystem save.
- Player-local values persist to `FS25_SettingsHub_local.xml` in the savegame.

## FarmTablet

SettingsHub exposes its model via `getModules()`. The FarmTablet System Settings app reads `g_currentMission.settingsHub` through its own AppRegistry auto-detect; SettingsHub does not call into FarmTablet directly.

## Console

- `shStatus` - list registered modules and the pending callback queue depth.
