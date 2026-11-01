-- UnwrittenDiscovery: Phase 0 step 2. Runs inside Hogwarts Legacy through UE4SS.
-- No networking. It answers three questions on your own PC:
--   F5  What is the player? (class, position, meshes, animation blueprint)
--   F6  Ghost test: a student NPC body replays your path 2 s behind
--   F7  What other characters exist nearby? (candidate classes for remote-player puppets)
--   F8  What is the player wearing? (appearance data we will sync later)
--   F9  Ghost test: the game's preview character, wearing your look, replays your path
-- Output goes to the UE4SS console and UE4SS.log next to the game exe.

local TAG = "[Unwritten] "
local function log(fmt, ...) print(TAG .. string.format(fmt, ...) .. "\n") end

local function valid(o) return o ~= nil and o:IsValid() end

local function className(o)
  if not valid(o) then return "<nil>" end
  return o:GetClass():GetFName():ToString()
end

-- Confirmed from Stephen's header dump (2026-11-01): the player is BP_Biped_Player_C,
-- a Blueprint of the native Biped_Player : Biped_Character : Base_Character.
local function getPlayerPawn()
  local pawn = FindFirstOf("BP_Biped_Player_C")
  if valid(pawn) then return pawn end
  pawn = FindFirstOf("Biped_Player")
  if valid(pawn) then return pawn end
  local pc = FindFirstOf("PlayerController")
  if valid(pc) and valid(pc.Pawn) then return pc.Pawn end
  return nil
end

local function vecStr(v) return string.format("(%.0f, %.0f, %.0f)", v.X, v.Y, v.Z) end

-- ------------------------------------------------------------------ F5: describe the player
RegisterKeyBind(Key.F5, function()
  ExecuteInGameThread(function()
    local pawn = getPlayerPawn()
    if not pawn then log("no player pawn found yet - load a save first"); return end
    log("player pawn: %s", pawn:GetFullName())
    log("class      : %s", className(pawn))
    log("location   : %s", vecStr(pawn:K2_GetActorLocation()))
    local r = pawn:K2_GetActorRotation()
    log("rotation   : pitch %.1f yaw %.1f roll %.1f", r.Pitch, r.Yaw, r.Roll)
    local v = pawn:GetVelocity()
    log("velocity   : %s", vecStr(v))

    -- Hogwarts Legacy builds characters from several skeletal meshes (body, head, hair,
    -- robes...). List every one so we know what a puppet has to copy.
    local comps = pawn:K2_GetComponentsByClass(StaticFindObject("/Script/Engine.SkeletalMeshComponent"))
    log("skeletal mesh components: %d", #comps)
    for i = 1, #comps do
      local c = comps[i]:get()
      local mesh = c.SkeletalMesh
      local anim = c:GetAnimInstance()
      log("  [%d] %s  mesh=%s  anim=%s", i, c:GetFName():ToString(),
          valid(mesh) and mesh:GetFullName() or "<none>",
          valid(anim) and className(anim) or "<none>")
    end
  end)
end)

-- ------------------------------------------------------------------ ghost tests (F6 / F9)
-- A ghost replays your path 2 seconds late. Round 1 (2026-11-01) showed: teleporting a body
-- every frame gives no animation, because Hogwarts Legacy animates characters with root
-- motion (the animation moves the body). So round 2 drives the ghost the way the game drives
-- NPCs: Ambulatory_Character:SetWorldSpeedAndDirection, and only teleports to fix big drift.
--   F6  ghost = a copy of a student NPC (BP_Student_C) already loaded near you
--   F9  ghost = the game's preview character (PHX_Biped_Preview_Actor) wearing your look
local ghost = nil
local history = {}  -- {t, x, y, z, yaw, speed}
local DELAY = 2.0
local SNAP_CM = 400       -- teleport if the ghost drifts further than this
local ghostLoopStarted = false
local lastReport = 0

local function spawnActorOfClass(world, cls, loc, yaw)
  local statics = StaticFindObject("/Script/Engine.Default__GameplayStatics")
  local half = math.rad(yaw or 0) / 2
  local xf = {
    Rotation = { X = 0, Y = 0, Z = math.sin(half), W = math.cos(half) },
    Translation = { X = loc.X, Y = loc.Y, Z = loc.Z },
    Scale3D = { X = 1, Y = 1, Z = 1 },
  }
  local a = statics:BeginDeferredActorSpawnFromClass(world, cls, xf, 1, nil)  -- 1 = AlwaysSpawn
  if not valid(a) then return nil end
  statics:FinishSpawningActor(a, xf)
  return a
end

local function spawnActor(world, classPath, loc, yaw)
  local cls = StaticFindObject(classPath)
  if not valid(cls) then log("class not found: %s", classPath); return nil end
  return spawnActorOfClass(world, cls, loc, yaw)
end

-- Log what we need to know about a freshly spawned body, and make sure it walks, not flies.
local function prepareBody(a)
  pcall(function()
    local cm = a.CharacterMovement
    log("  movement component: %s, mode %s", className(cm), tostring(cm.MovementMode))
    cm:SetMovementMode(1, 0)  -- MOVE_Walking: gravity on, stays on the ground
    log("  movement mode set to walking")
  end)
  pcall(function()
    local anim = a.Mesh:GetAnimInstance()
    log("  anim instance: %s", valid(anim) and className(anim) or "<none>")
  end)
  pcall(function() log("  controller: %s", valid(a.Controller) and className(a.Controller) or "<none>") end)
end

-- Copy the player's look onto any body that has a CustomizableCharacterComponent.
local function copyLook(pawn, a)
  local ok, err = pcall(function()
    a.Customization:SetCharacterID(pawn.Customization.CharacterName)
    a.Customization:ReloadCharacter()
  end)
  log("  copy your look: %s", ok and "requested" or ("failed: " .. tostring(err)))
end

-- Make sure a body has a controller (needed to walk) and that any AI brain is switched off.
local function takeControl(a)
  pcall(function()
    if not valid(a.Controller) then a:SpawnDefaultController() end
    log("  controller: %s", valid(a.Controller) and className(a.Controller) or "<none>")
  end)
  pcall(function()
    local brain = a.Controller.BrainComponent
    if valid(brain) then brain:StopLogic("Unwritten puppet"); log("  AI brain stopped") end
  end)
end

local function buildStudentGhost(pawn)
  local student = FindFirstOf("BP_Student_C")
  if not valid(student) then log("no student loaded nearby - go somewhere with students"); return nil end
  local l = pawn:K2_GetActorLocation()
  local a = spawnActorOfClass(pawn:GetWorld(), student:GetClass(), l, pawn:K2_GetActorRotation().Yaw)
  if not a then log("student ghost spawn failed"); return nil end
  log("student ghost spawned: %s", a:GetFullName())
  prepareBody(a)
  takeControl(a)
  copyLook(pawn, a)
  return a
end

-- Puppet v2: the game's own character-preview actor. It shares Biped_Character with the
-- player and carries a CustomizableCharacterComponent, so it can wear the player's look.
local function buildPreviewGhost(pawn)
  local l = pawn:K2_GetActorLocation()
  local a = spawnActor(pawn:GetWorld(), "/Script/Phoenix.PHX_Biped_Preview_Actor", l, pawn:K2_GetActorRotation().Yaw)
  if not a then log("preview ghost spawn failed"); return nil end
  log("preview ghost spawned: %s", a:GetFullName())
  local ok, err = pcall(function()
    local src, dst = pawn.Customization, a.Customization
    dst:SetCharacterID(src.CharacterName)
    dst:ReloadCharacter()
    log("  copied character id %s", src.CharacterName:ToString())
  end)
  if not ok then log("  copying appearance failed: %s", tostring(err)) end
  prepareBody(a)
  takeControl(a)
  -- If the preview actor has a "preview only" animation, give it the player's.
  pcall(function()
    local playerAnim = pawn.Mesh:GetAnimInstance()
    a.Customization:SetAnimInstanceClass(playerAnim:GetClass())
    log("  anim class set to %s", className(playerAnim))
  end)
  return a
end

-- Round 3: ask the game's own AI navigation to walk the body to where you were. NPCs walk
-- this way, so they get proper root-motion animation and stay on the ground.
local aiLib = nil
local lastMove = 0
local lastGoal = nil
local function driveGhost(now, h)
  local g = ghost:K2_GetActorLocation()
  local dx, dy, dz = h.x - g.X, h.y - g.Y, h.z - g.Z
  local dist = math.sqrt(dx * dx + dy * dy)
  if dist > 800 or math.abs(dz) > 600 then
    ghost:K2_SetActorLocationAndRotation({ X = h.x, Y = h.y, Z = h.z }, { Pitch = 0, Yaw = h.yaw, Roll = 0 }, false, {}, true)
    return string.format("snap (was %.0f cm away)", dist)
  end
  if now - lastMove < 0.2 then return string.format("walking, %.0f cm behind", dist) end
  if lastGoal and math.abs(lastGoal.x - h.x) + math.abs(lastGoal.y - h.y) < 40 and dist < 80 then
    return string.format("idle, %.0f cm away", dist)
  end
  lastMove, lastGoal = now, h
  aiLib = aiLib or StaticFindObject("/Script/AIModule.Default__AIBlueprintHelperLibrary")
  local ok, err = pcall(function() aiLib:SimpleMoveToLocation(ghost.Controller, { X = h.x, Y = h.y, Z = h.z }) end)
  if not ok then return "move failed: " .. tostring(err) end
  local v = ghost:GetVelocity()
  return string.format("move order sent, %.0f cm away, ghost speed %.0f", dist, math.sqrt(v.X * v.X + v.Y * v.Y))
end

local function toggleGhost(builder)
  ExecuteInGameThread(function()
    local pawn = getPlayerPawn()
    if not pawn then log("load a save first"); return end
    if valid(ghost) then ghost:K2_DestroyActor(); ghost = nil; log("ghost removed"); return end
    ghost = builder(pawn)
    history = {}
    if ghostLoopStarted then return end
    ghostLoopStarted = true
    LoopAsync(33, function()
      ExecuteInGameThread(function()
        if not valid(ghost) then return end
        local p = getPlayerPawn()
        if not p then return end
        local now = os.clock()
        local l = p:K2_GetActorLocation()
        local v = p:GetVelocity()
        table.insert(history, { t = now, x = l.X, y = l.Y, z = l.Z, yaw = p:K2_GetActorRotation().Yaw,
                                speed = math.sqrt(v.X * v.X + v.Y * v.Y) })
        while #history > 2 and history[2].t <= now - DELAY do table.remove(history, 1) end
        local h = history[1]
        if h.t <= now - DELAY then
          local status = driveGhost(now, h)
          if now - lastReport > 2 then lastReport = now; log("ghost: %s", status) end
        end
      end)
      return false  -- keep looping
    end)
  end)
end

RegisterKeyBind(Key.F6, function() toggleGhost(buildStudentGhost) end)
RegisterKeyBind(Key.F9, function() toggleGhost(buildPreviewGhost) end)

-- ------------------------------------------------------------------ F8: appearance
RegisterKeyBind(Key.F8, function()
  ExecuteInGameThread(function()
    local pawn = getPlayerPawn()
    if not pawn then return end
    local ok, err = pcall(function()
      local c = pawn.Customization
      log("Customization: %s", c:GetFullName())
      log("  CharacterName=%s Type=%s", c.CharacterName:ToString(), c.Type:ToString())
      local n = 0
      c.AddOnMeshes:ForEach(function(k, v)
        n = n + 1
        local mesh = v:get()
        log("  piece %-24s -> %s", k:get():ToString(), valid(mesh) and mesh:GetFullName() or "<none>")
      end)
      log("  %d add-on mesh pieces", n)
    end)
    if not ok then log("appearance dump failed: %s", tostring(err)) end
  end)
end)

-- ------------------------------------------------------------------ F7: nearby characters
RegisterKeyBind(Key.F7, function()
  ExecuteInGameThread(function()
    local pawn = getPlayerPawn()
    if not pawn then return end
    local me = pawn:K2_GetActorLocation()
    local all = FindAllOf("Character") or {}
    local counts = {}
    for _, c in ipairs(all) do
      if valid(c) then
        local n = className(c)
        counts[n] = (counts[n] or 0) + 1
      end
    end
    log("characters loaded: %d", #all)
    for n, k in pairs(counts) do log("  %4d x %s", k, n) end
    log("(your position %s)", vecStr(me))
  end)
end)

log("UnwrittenDiscovery loaded. F5 player, F6 ghost (student), F7 characters, F8 appearance, F9 ghost (preview character) [round 3]")
