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

## Step 3 (M3): build the C++ mod and connect the game to our server

This builds `UnwrittenClient`, our native mod. It has two halves in one mod folder: `dlls\main.dll` (C++, owns the network connection) and `Scripts\main.lua` (moves characters in game). The first milestone is simple: the game connects to `unwritten-server`. After that, all ghost and animation work moves into C++.

The C++ mod must be compiled together with the UE4SS source, at the **same version you installed (v3.0.1)**.

### 3a. Accounts, once (about 10 minutes, then a wait for an email)

1. Link your GitHub account to an Epic Games account: https://www.unrealengine.com/en-US/ue-on-github (sign in to Epic, open Apps and Accounts, connect GitHub).
2. Epic sends an email inviting you to the **EpicGames** organization on GitHub. Accept it. You can also accept at https://github.com/EpicGames.
3. Check: https://github.com/EpicGames/UnrealEngine should open (a 404 page means the invite isn't accepted yet).

UE4SS needs this because one of its parts mirrors Unreal Engine headers, which Epic only shows to linked accounts.

### 3b. Tools, once

1. **Rust** (UE4SS uses it to find functions in the game): download `rustup-init.exe` from https://rustup.rs and accept the defaults. Close and reopen any terminals afterwards.
2. **Visual Studio 2026** with "Desktop development with C++", plus the VS 2022 compiler: in Visual Studio Installer, Modify, Individual components, tick **"MSVC v143 - VS 2022 C++ x64/x86 build tools (Latest)"**. UE4SS 3.0.1 is built with that compiler. Use **Developer PowerShell** for every command below, not plain PowerShell. (If you have real VS 2022 instead, use `-G "Visual Studio 17 2022"` and drop `-T v143`.)
3. Check that all three work:
   ```
   git --version
   cargo --version
   cmake --version
   ```

### 3c. Get the code

```
git config --global url."https://github.com/".insteadOf "git@github.com:"
cd E:\Unwritten\Unwritten
git pull
cd client\cpp
git clone --branch v3.0.1 https://github.com/UE4SS-RE/RE-UE4SS.git
cd RE-UE4SS
git submodule update --init --recursive
cd ..
```

The first line makes git use your normal GitHub sign-in instead of SSH keys. If a browser window asks you to sign in to GitHub during the submodule step, sign in with the account you linked to Epic. If that step fails on `deps/first/Unreal` (or CMake later says `deps/first/Unreal` has no CMakeLists.txt), the Epic invite from 3a isn't active yet; accept it and rerun the submodule command. The extra `Rust_*` options in 3d are needed because UE4SS 3.0.1's Rust finder can't read the output of current rustup.

### 3d. Build (first build takes 10 to 20 minutes)

Still in `E:\Unwritten\Unwritten\client\cpp`:

```
cmake -S . -B build -G "Visual Studio 18 2026" -T v143 "-DCMAKE_POLICY_VERSION_MINIMUM=3.5" "-DRust_COMPILER=$env:USERPROFILE\.cargo\bin\rustc.exe" "-DRust_CARGO=$env:USERPROFILE\.cargo\bin\cargo.exe" "-DRust_RESOLVE_RUSTUP_TOOLCHAINS=OFF"
cmake --build build --config Game__Shipping__Win64 --target UnwrittenClient
```

When it finishes, the build copies `main.dll` straight into `E:\HogwartsLegacy\Phoenix\Binaries\Win64\ue4ss\Mods\UnwrittenClient\dlls\`. (If your game is somewhere else, add `-DUW_MODS_DIR="<your Win64>\ue4ss\Mods"` to the first command.)

**Send back:** the last 30 lines of output if either command fails.

### 3e. Test the connection

1. Tell me the build worked; I install the Lua half and `enabled.txt` into `Mods\UnwrittenClient`.
2. Start the server: `E:\Unwritten\Unwritten\build\Release\unwritten-server.exe --port 30120`.
3. Start the game and load a save. The UE4SS log should show `[Unwritten] native bridge loaded` and `UnwrittenClient loaded. F3 = connect`.
4. Press **F3**. The game log should say `connected as #1`, and the server window should show 1 player.

**Send back:** "connected" or the UE4SS log.

If the game crashes at start after installing `main.dll`, delete the `UnwrittenClient\dlls` folder to get back to normal, and send me `UE4SS.log`.

## Step 4 (M4): two players, later

A friend who owns the game (or a second PC) installs the same mod. You run `unwritten-server`, and they set your IP in `config.lua` and press F3.

## Want to watch the server work now?

On any PC with CMake and a C++ compiler: from the repo folder run `cmake -S . -B build` then `cmake --build build --config Release`. Start `unwritten-server`, then in a second window `botswarm --bots 128 --seconds 30`. It prints how many fake players connected and how far their positions drifted.

Back to [[Phase 0 Plan]]
