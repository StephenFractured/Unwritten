---
tags: [design, engine, phase-0, runbook]
created: 2026-11-01
---
# Phase 0 Runbook: what to run on your PC

These are the steps that need Hogwarts Legacy, so they run on Stephen's PC. Each step ends with what to send back. Plan and reasons: [[Phase 0 Plan]].

The game install folder below means `Phoenix\Binaries\Win64` inside the game install (Stephen's Epic install: `E:\HogwartsLegacy\Phoenix\Binaries\Win64`). **Not** the top game folder: it also has a `HogwartsLegacy.exe`, but that is only a small launcher and UE4SS will silently not load there.

## Step 1 (M1): get UE4SS running in the game, about 20 minutes

1. Back up your saves: copy `%LOCALAPPDATA%\Hogwarts Legacy\Saved\SaveGames` somewhere safe.
2. Note the game version shown on the main menu.
3. Download the latest **UE4SS** release zip (not the "zDEV" one) from https://github.com/UE4SS-RE/RE-UE4SS/releases.
4. Extract it straight into the `Win64` folder, so `dwmapi.dll` sits next to `HogwartsLegacy.exe`.
5. Open `UE4SS-settings.ini` (in `Win64` or `Win64\ue4ss`) and set `ConsoleEnabled = 1`, `GuiConsoleEnabled = 1` and `GuiConsoleVisible = 1`.
6. Start the game. A UE4SS console window should open alongside it. Load a save.
7. In the UE4SS window, open the **Dumpers** tab and run **Dump CXX Headers**, then **Dump all objects and properties**. Output lands in the `Win64` (or `Win64\ue4ss`) folder as `CXXHeaderDump` and `UE4SS_ObjectDump.txt`.

**Send back:** `UE4SS.log`, plus `CXXHeaderDump` zipped and `UE4SS_ObjectDump.txt`. These are lists of class names and layouts, not game assets, and they stay private to us.

If the game crashes on start or the log says it could not find objects, send `UE4SS.log` and stop there. That tells us UE4SS needs a Hogwarts Legacy-specific config, which I'll sort out.

## Step 2 (M2): discovery and the ghost test, about 15 minutes

1. Copy the `UnwrittenDiscovery` folder from `client\lua\` into the `Mods` folder UE4SS created (`Win64\ue4ss\Mods` or `Win64\Mods`).
2. Inside `Mods\UnwrittenDiscovery`, create an empty file named `enabled.txt`.
3. Start the game and load a save somewhere outdoors, like the Hogwarts courtyard.
4. Press **F5**. The console prints the player class, position and every body mesh.
5. Press **F7**. It lists the character classes loaded nearby (candidate puppet bodies).
6. Press **F6**, then walk, run, jump and turn for 30 seconds. A copy of your character should follow your exact path 2 seconds behind. Press F6 again to remove it.

**Send back:** `UE4SS.log`, and a short clip or screenshot of the ghost. Tell me if it moved, if it turned, and if it animated or slid along in a T-pose. Any of those is a useful answer.

## Step 3 (M4): two players, later

After Step 2 I'll update the client with the real class names and the best puppet strategy. You will then need:

- **Visual Studio 2022** with "Desktop development with C++".
- Your GitHub account linked to an Epic Games account (UE4SS's source build needs Epic's Unreal headers repo, which is free but gated by that link: https://www.unrealengine.com/en-US/ue-on-github).
- A friend who owns the game, or a second PC.

I'll write the exact build commands then. The server you run with `unwritten-server --port 30120`; the friend sets your IP in `config.lua` and presses F8.

## Want to watch the server work now?

On any PC with CMake and a C++ compiler: from the repo folder run `cmake -S . -B build` then `cmake --build build --config Release`. Start `unwritten-server`, then in a second window `botswarm --bots 128 --seconds 30`. It prints how many fake players connected and how far their positions drifted.

Back to [[Phase 0 Plan]]
