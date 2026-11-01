# Unwritten

Private multiplayer roleplay platform for Hogwarts Legacy. Players must own the game; this repo never contains game files, assets or dumps.

Phase 0 (current): prove players can sync. See [docs/Phase 0 Plan.md](docs/Phase%200%20Plan.md) and [docs/Phase 0 Runbook.md](docs/Phase%200%20Runbook.md).

| Folder | What |
| --- | --- |
| `shared/protocol.hpp` | Wire protocol shared by server, bots and client |
| `server/` | Sync server (ENet/UDP, 30 Hz, interest management) |
| `tools/botswarm/` | Fake-player load tester |
| `client/lua/UnwrittenDiscovery` | UE4SS Lua mod: inspect the player, ghost puppet test |
| `client/lua/UnwrittenClient` | UE4SS Lua half of the sync client (puppets, interpolation) |
| `client/cpp/UnwrittenClient` | UE4SS C++ half: network bridge exposing `UW_*` to Lua |

## Build server and bots

    cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
    cmake --build build --config Release
    ./build/unwritten-server --port 30120 --max 128
    ./build/botswarm --bots 128 --seconds 30

On Windows (Visual Studio) the programs land in `build\Release\`: run `.\build\Release\unwritten-server.exe` and `.\build\Release\botswarm.exe`.
