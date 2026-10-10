# SmartRepli — Roblox player-data replication

SmartRepli is a Roblox Luau client/server replication prototype that synchronizes named player-data folders through a `RemoteEvent`, supports server-side middleware and changed-value listeners, and optionally exposes explicitly approved gameplay actions. This is the older SmartRepli repository, distinct from **SmartReplicate**.

## Installation

Place `VirtualData.lua` into a server-accessible `ModuleScript` named `VirtualData`. It expects sibling `Modules` folder containing your gameplay modules and DataStore components. Place `ClientHandler.lua` in a client-accessible `ModuleScript` named `ClientHandler` under ReplicatedStorage. The server creates `ReplicatedStorage.FolderSyncEvent` if needed.

Server-side example:

```luau
local VirtualData = require(game.ServerScriptService.VirtualData)
local folder = VirtualData.new(player, {
    Settings = {MusicEnabled = true, __sync = "Private"},
    Stats = {Wins = 0, __sync = "Public"},
})

folder:AllowClientUpdate("Settings.MusicEnabled", function(newValue)
    return type(newValue) == "boolean"
end)

folder:Update("Stats", "Wins", 1)
```

Client-side example:

```luau
local ClientHandler = require(game.ReplicatedStorage.ClientHandler)
local own = ClientHandler.get(game.Players.LocalPlayer.UserId)
print(own:GetData("Stats.Wins"))
own:RequestUpdate("Settings", "MusicEnabled", false)
```

### Server-authoritative security

Prior to this fix, a client could directly update any field through `RequestUpdate` or call any exported method on server modules through `RequestModule`. The server **now denies both by default**. The server may allow safe primitive field updates using `:AllowClientUpdate("Folder.Key", validator?)`.

Modules must explicitly expose remote actions:

```luau
local Module = {}
Module.ClientActions = {UseAbility = true}
function Module.UseAbility(player, folder, abilityName)
    -- Validate server-authoritative cooldowns, ownership, and costs.
end
return Module
```

Both incoming action types are rate-limited to a minimum interval of 0.1 seconds per player. Do not authorize client-written currencies or ownership flags. Trust the server to calculate and persist rewards.

### Public and private replication

Only folders marked `__sync = "Public"` are sent to other players. Full data is sent to its owner via `RemoteEvent:FireClient`. The client merges the public and private initial packets instead of dropping whichever arrives second. Changing a public folder to private also sends deletion updates to revoke its old values elsewhere. Previously replicated public information cannot be made secret retroactively.

### Public API

| Module | Operations |
| --- | --- |
| `VirtualData` | `new`, `EnsureFolder`, `Define`, `Update`, `GetData`, `SetSyncMode`, `TogglePublic`, `AllowClientUpdate`, `DisallowClientUpdate`, `OnChanged`, `Destroy` |
| `ClientHandler` | `get`, `RequestUpdate`, `RequestModule`, `GetData`, `OnChanged` |

## Test and migration requirements

The security default intentionally changes behavior. Existing unapproved client-side write calls and module actions will stop working until server approval is added. Test with **two players** in Roblox Studio and inspect both replicated folder stores: no private values should appear to the other player; unauthorized updates should not change server data; validators should reject bad inputs; authorized actions should still work. Check with Script Analysis and the Studio Script Profiler before publishing.

This repository does not contain a full DataStore session-lock regression suite. It is not a substitute for a production-secure data persistence system. The code is not yet fully analyzed under Luau `--!strict`; that remains a separate requirement.

Official language references: https://luau.org/typecheck/ and https://luau.org/performance/.

## Original project references

- [SmartReplica Editor Roblox Studio asset](https://create.roblox.com/store/asset/107314367553673/SmartReplica-Editor)
- [Video tutorial](https://youtu.be/bF9iR7r-KmY)

![SmartReplica Editor preview](https://github.com/user-attachments/assets/9c9b61db-2b83-49a9-988e-0dccf8432a32)
