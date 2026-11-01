---
tags: [design, engine, phase-0]
created: 2026-11-01
---
# Phase 0 Plan: prove players can sync

Phase 0 answers one question before anything else is built: **can we put a second player into Hogwarts Legacy and keep them in sync?** It ends with the go/no-go gate from [[Launch Plan]]: 128 players stay in sync in Hogwarts.

What is already done (2026-11-01): the sync server and a 128-player bot swarm are built and passing (see Results). Everything left needs the game, so it runs on Stephen's PC. Step-by-step: [[Phase 0 Runbook]].

## Toolchain

| Piece | Tool | Why |
| --- | --- | --- |
| Injection and scripting inside the game | **UE4SS** (RE-UE4SS, open source) | Loads into UE4 games, gives a Lua scripting layer, a live object viewer and C++ mod support. Already used by the Hogwarts Legacy modding scene. |
| SDK / class layouts | UE4SS dumpers (CXX header dump, object dump) | Gives us the game's real class, property and function names instead of guessing. |
| Native client code | UE4SS C++ mod (Visual Studio 2022, CMake) | Networking needs sockets, which Lua in UE4SS does not have. |
| Netcode | **ENet** (UDP, reliable + unreliable channels) | Small, proven, cross-platform. Same idea as FiveM's transport. |
| Server | C++20, single binary, Linux or Windows | Shares `protocol.hpp` with the client so the wire format never drifts. |
| Load testing | `botswarm` tool | 128+ fake players without 128 copies of the game. |

Code layout: `server/`, `shared/protocol.hpp`, `tools/botswarm/`, `client/lua/UnwrittenDiscovery`, `client/lua/UnwrittenClient` (Lua half), `client/cpp/UnwrittenClient` (native network bridge).

## How sync works

- **Client mod** reads the local player 30 times a second (position, yaw, ground speed, a few animation flags, current spell/emote montage id) and sends it.
- **Server** checks each update (no teleporting faster than 30 m/s, no NaNs), and sends back a correction if it fails. Movement is client-predicted with server validation, the FiveM/RedM model, because the server has no copy of the game's collision. Money, damage, inventory and spells become fully server-authoritative in Phase 1.
- **Interest management** from day one: a 100 m grid; players within 80 m get updates 20 times a second (nearest 64 only), players within 300 m get 5 a second, everyone further away gets nothing.
- **Remote players** are puppet actors spawned by the client mod and moved along interpolated snapshots rendered 100 ms in the past, which hides network jitter.
- **Animation** is synced as the inputs the animation blueprint reads (speed, in air, wand out, montage id), never as bone data. Each client animates its own puppets.

## Milestones

| # | Milestone | Done when | Where |
| --- | --- | --- | --- |
| M0 | Server and load test | 128 bots connected and in sync | Done, in the cloud |
| M1 | Injection | UE4SS console opens in Hogwarts Legacy; headers and objects dumped | Stephen's PC |
| M2 | Read the player, spawn a body | Discovery mod prints the player; the F6 ghost follows your path 2 s behind | Stephen's PC |
| M3 | Animated puppet | Ghost walks, runs and jumps instead of sliding or T-posing | Stephen's PC + code |
| M4 | Two real players | Two PCs (or two game installs) see each other walk round Hogwarts for 30 minutes without a crash | Stephen + a friend |
| M5 | Looks and one spell | Puppet wears the remote player's appearance; one wand cast plays on both screens (visual only) | Code + test |
| M6 | Scale | 2 real clients + 126 bots; frame time cost of 64 visible puppets measured | Test |

## Puppet strategy (the M3 question)

The riskiest unknown is whether the game's animation blueprint will run on a body that is not the player. We try, in order:

1. **The game's own NPC class**: spawn the character class the game uses for students and townsfolk, turn off its AI, and drive its movement component. Its own animation blueprint then animates it naturally. Most likely to look right.
2. **Plain skeletal mesh + player animation blueprint**: what the ghost test does first. Cheap, but the blueprint may expect a real player and T-pose.
3. **Pose copying**: copy bone poses from a hidden local animator. Last resort, costs frame time.

## Go/no-go criteria

Go to Phase 1 only when all hold: two real players see each other move and animate correctly; puppets do not crash the game across loading screens, fast travel and save loads; 128 players (bots + real) stay connected with under 150 ms visual delay; the client keeps 60 fps with 64 puppets on screen on Stephen's PC. If M3 fails all three strategies, stop and rethink before writing any gameplay.

## Known risks

| Risk | What we do |
| --- | --- |
| Single-player pause: menus, the map and cutscenes pause the world | Network runs on its own thread so the connection survives; puppets freeze while paused. Later: block pausing menus while online. |
| Level streaming: remote players in an area your game has not loaded | Hide puppets whose ground is not loaded; interest radius already limits this. |
| Game patches move classes | Launcher pins the game version; class names come from dumps, not hard-coded addresses. |
| The game's own save system and story state | Online mode will load a fixed "Unwritten" save state; story quests off. Phase 1 work. |

## Legal hygiene

Players must own the game. We never ship or upload game files, assets or dumped headers; our mod contains only our own code. Header dumps stay private and out of the public repo.

## Results so far (2026-11-01)

Bot swarm on the cloud test machine, server and bots on one host:

| Test | Connected | Download per player | Position error before smoothing | Server tick cost |
| --- | --- | --- | --- | --- |
| 128 bots, all inside 200 m (worst case: everyone in one courtyard) | 128 / 128 | 31 KB/s | p50 11 cm, p99 21 cm | 1.2 ms avg of 33 ms budget |
| 256 bots across 600 m | 256 / 256 | 19 KB/s | p50 14 cm, p99 26 cm | 2.4 ms avg |

Server upload at 128 players in one spot is about 4 MB/s (33 Mbit/s), fine for a normal host; delta compression can cut it later. Caveat: this is a local network with no packet loss, so it proves the server scales, not real internet conditions. M4 and M6 test that.

Back to [[Unwritten Design Doc]] · [[Engine vs Scripting]] · [[Risks and Open Questions]]
