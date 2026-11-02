-- UnwrittenDiscovery: Phase 0 step 2. Runs inside Hogwarts Legacy through UE4SS.
-- No networking. It answers three questions on your own PC:
--   F5  What is the player? (class, position, meshes, animation blueprint)
--   F6  Ghost test: a student NPC body wearing your look (round 6)
--   F7  Animation probe: press standing, then again while running; logs what changed
--   F8  What is the player wearing? (appearance data we will sync later)
--   F9  Ghost test: the game's preview character, wearing your look, replays your path
-- Output goes to the UE4SS console and UE4SS.log next to the game exe.

local TAG = "[Unwritten] "
local function log(fmt, ...) print(TAG .. string.format(fmt, ...) .. "\n") end

local function valid(o)
  -- UE4SS sometimes hands back non-object values (round 5 crashed on a function value).
  if type(o) ~= "userdata" then return false end
  local ok, res = pcall(function() return o:IsValid() end)
  return ok and res == true
end

local ghost = nil  -- the current ghost body (declared early so every key handler sees it)
local ghostDrive = "nav"  -- "nav" = walk via AI pathfinding, "speed" = game locomotion speed+direction

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
    if valid(ghost) then
      log("ghost: %s", ghost:GetFullName())
      pcall(function()
        local ga = ghost.Mesh:GetAnimInstance()
        local v = ghost:GetVelocity()
        log("ghost anim=%s speed=%.0f", valid(ga) and className(ga) or "<none>", math.sqrt(v.X * v.X + v.Y * v.Y))
      end)
    end
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
  -- Player and preview bodies call it "Customization"; NPCs (students) call it "CCComponent".
  local ok, err = pcall(function()
    local cc = a.CCComponent
    if not valid(cc) then cc = a.Customization end
    log("  look component: %s", valid(cc) and cc:GetFName():ToString() or "<none>")
    cc:SetCharacterID(pawn.Customization.CharacterName)
    cc:ReloadCharacter()
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
  -- Round 2 log showed a student with its AI removed kept pace with you when driven by
  -- SetWorldSpeedAndDirection; round 6 showed it does not walk via AI pathfinding. So: no AI,
  -- and drive it with the game's locomotion speed + direction.
  pcall(function()
    if valid(a.Controller) then a.Controller:UnPossess(); log("  AI controller detached") end
  end)
  copyLook(pawn, a)
  -- Round 8: puppet mode. No physics of its own; we place it every tick and feed its
  -- movement component the velocity you had, which is what its animation blueprint reads
  -- to pick idle / walk / run. Root motion is ignored so the animation can't drag it away.
  -- Rounds 8-9 "puppet mode" (movement off + placed every frame) crashed the game; not used.
  ghostDrive = "anim"
  hookAnimUpdate(a)
  return a
end

local pendingAnimFix = 0  -- countdown of animation-fix retries for a new preview ghost

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
  ghostDrive = "nav"
  pendingAnimFix = 20  -- the look loads asynchronously; retry the animation fix for ~10 s
  return a
end

-- Round 4: the preview body walks (round 3 log) but has no animation running on its mesh,
-- so it stays in a T-pose. Give its main mesh the player's animation blueprint once the
-- look has loaded, and report what every mesh piece is doing.
local function fixGhostAnimation(verbose)
  local pawn = getPlayerPawn()
  if not (pawn and valid(ghost)) then return true end
  local done = false
  local ok, err = pcall(function()
    local mesh = ghost.Mesh
    local playerAnimClass = pawn.Mesh:GetAnimInstance():GetClass()
    local cur = mesh:GetAnimInstance()
    if verbose then
      pcall(function()
        local pa = pawn.Mesh:GetAnimInstance()
        log("player anim=%s AnimComp=%s layers=%s tickOpt=%s", className(pa),
            valid(pa.AnimComp) and pa.AnimComp:GetFName():ToString() or "<none>",
            valid(pawn.AnimationComponent.LayersAsset) and pawn.AnimationComponent.LayersAsset:GetFName():ToString() or "<none>",
            tostring(pawn.Mesh.VisibilityBasedAnimTickOption))
        local ga = ghost.Mesh:GetAnimInstance()
        log("ghost  anim=%s AnimComp=%s layers=%s tickOpt=%s", valid(ga) and className(ga) or "<none>",
            (valid(ga) and valid(ga.AnimComp)) and ga.AnimComp:GetFName():ToString() or "<none>",
            valid(ghost.AnimationComponent.LayersAsset) and ghost.AnimationComponent.LayersAsset:GetFName():ToString() or "<none>",
            tostring(ghost.Mesh.VisibilityBasedAnimTickOption))
      end)
      log("ghost mesh=%s animMode=%s anim=%s", valid(mesh.SkeletalMesh) and mesh.SkeletalMesh:GetFName():ToString() or "<none>",
          tostring(mesh.AnimationMode), valid(cur) and className(cur) or "<none>")
    end
    if not valid(mesh.SkeletalMesh) then return end  -- look not loaded yet
    if not valid(cur) then
      -- Round 5: copy the player's animation wiring before starting the blueprint.
      -- Round 4 showed the blueprint runs but outputs a T-pose: its locomotion comes from
      -- "animation layers" that the AnimationComponent plugs in, and the preview body has none.
      pcall(function()
        local srcAC, dstAC = pawn.AnimationComponent, ghost.AnimationComponent
        local layers = srcAC.LayersAsset
        log("  player layers=%s, ghost layers=%s", valid(layers) and layers:GetFName():ToString() or "<none>",
            valid(dstAC.LayersAsset) and dstAC.LayersAsset:GetFName():ToString() or "<none>")
        dstAC:SetAnimLayersAsset(layers)
        log("  ghost layers set")
      end)
      -- Round 4 screenshot: the body hovers ~1 m up. Use the player's mesh offset in the capsule.
      pcall(function()
        local rl, rr = pawn.Mesh.RelativeLocation, pawn.Mesh.RelativeRotation
        mesh:K2_SetRelativeLocationAndRotation({ X = rl.X, Y = rl.Y, Z = rl.Z },
                                               { Pitch = rr.Pitch, Yaw = rr.Yaw, Roll = rr.Roll }, false, {}, true)
        log("  mesh offset set to (%.0f, %.0f, %.0f) yaw %.0f", rl.X, rl.Y, rl.Z, rr.Yaw)
      end)
      pcall(function()
        mesh.VisibilityBasedAnimTickOption = 0  -- always tick pose
        mesh.bPauseAnims = false
        mesh:SetComponentTickEnabled(true)
      end)
      mesh:SetAnimationMode(0)  -- AnimationBlueprint
      mesh:SetAnimClass(playerAnimClass)
      cur = mesh:GetAnimInstance()
      log("ghost animation set: %s", valid(cur) and className(cur) or "still none")
      pcall(function()
        ghost.AnimationComponent:SetAnimLayersAsset(pawn.AnimationComponent.LayersAsset)  -- again, now that the blueprint exists
        log("  ghost AnimComp=%s", valid(cur.AnimComp) and cur.AnimComp:GetFullName() or "<none>")
      end)
    end
    done = valid(cur)
  end)
  if not ok then log("animation fix failed: %s", tostring(err)); return true end
  if verbose then
    pcall(function()
      local comps = ghost:K2_GetComponentsByClass(StaticFindObject("/Script/Engine.SkeletalMeshComponent"))
      for i = 1, #comps do
        local c = comps[i]:get()
        local an = c:GetAnimInstance()
        log("  ghost piece [%d] %s mesh=%s anim=%s", i, c:GetFName():ToString(),
            valid(c.SkeletalMesh) and c.SkeletalMesh:GetFName():ToString() or "<none>",
            valid(an) and className(an) or "<none>")
      end
    end)
  end
  return done
end

-- Round 3: ask the game's own AI navigation to walk the body to where you were. NPCs walk
-- this way, so they get proper root-motion animation and stay on the ground.
local aiLib = nil
local lastMove = 0
local lastGoal = nil
-- Round 9: the game's animation runs off a handful of inputs on the AnimInstance
-- (Ambulatory_AnimInstance: Speed, IsMoving, MobilityActionState, ...). Read them from your
-- character each tick and write the same values onto the puppet. This is the design we will
-- network: send these few numbers, not bones.
-- Round 11: the round-10 probe found what actually changes on your character's animation
-- when you run: DesiredWorldSpeed (0 -> 450), DesiredWorldDirection, AnimSpeedType (0 -> 4),
-- AnimMechanicType (1 -> 2), IsInIdle, IsMovementInput, GameTimeAtStartMove.
-- These are what we copy now (and what we will send over the network).
function readAnimInputs(pawn)
  local ok, r = pcall(function()
    local ai = pawn.Mesh:GetAnimInstance()
    local d = ai.DesiredWorldDirection
    return { speed = ai.DesiredWorldSpeed, dx = d.X, dy = d.Y, speedType = ai.AnimSpeedType,
             mechanic = ai.AnimMechanicType, idle = ai.IsInIdle, input = ai.IsMovementInput,
             startMove = ai.GameTimeAtStartMove }
  end)
  return ok and r or nil
end

local animWriteError = nil
local function setField(obj, k, v)
  local ok, err = pcall(function() obj[k] = v end)
  if not ok then animWriteError = k .. ": " .. tostring(err) end
end

-- speed/dir override lets the caller steer toward where you were.
local function writeAnimInputs(g, a, speed, dirx, diry)
  if not a then return end
  local ai = g.Mesh:GetAnimInstance()
  if not valid(ai) then animWriteError = "ghost has no anim instance"; return end
  setField(ai, "DesiredWorldSpeed", speed)
  setField(ai, "LastDesiredWorldSpeed", speed)
  setField(ai, "DesiredWorldDirection", { X = dirx, Y = diry, Z = 0 })
  setField(ai, "LastDesiredWorldDirection", { X = dirx, Y = diry, Z = 0 })
  setField(ai, "AnimSpeedType", a.speedType)
  setField(ai, "AnimMechanicType", a.mechanic)
  setField(ai, "IsInIdle", a.idle)
  setField(ai, "IsMovementInput", a.input)
  -- and the character-level command that normally sets these
  pcall(function() g:SetWorldSpeedAndDirection(speed, { X = dirx, Y = diry, Z = 0 }) end)
end

local function animStr(a)
  if not a then return "<none>" end
  return string.format("speed=%.0f dir=(%.2f,%.2f) speedType=%s mechanic=%s idle=%s input=%s",
    a.speed or -1, a.dx or 0, a.dy or 0, tostring(a.speedType), tostring(a.mechanic), tostring(a.idle), tostring(a.input))
end

-- Round 12: round 11 showed the copy keeps our values when we read them back, yet its pose
-- never changes. Most likely the game recomputes them inside each animation update (from the
-- copy's own movement, which is zero) and our 30-per-second writes land at the wrong moment.
-- So hook the copy's animation update itself and re-apply our values right after it runs,
-- every frame, just before the pose is built.
animTarget = nil
local hookedClasses = {}
local hookHits = 0
local function hookAnimUpdate(g)
  local ok, err = pcall(function()
    local ai = g.Mesh:GetAnimInstance()
    local clsPath = ai:GetClass():GetFullName():match("^%S+%s+(.+)$")  -- strip "BlueprintGeneratedClass "
    if hookedClasses[clsPath] then return end
    local fn = clsPath .. ":BlueprintUpdateAnimation"
    RegisterHook(fn, function(self, dt)
      if not (valid(ghost) and animTarget) then return end
      local me = self:get()
      local gai = ghost.Mesh:GetAnimInstance()
      if not (valid(gai) and me:GetAddress() == gai:GetAddress()) then return end
      hookHits = hookHits + 1
      local t = animTarget
      setField(me, "DesiredWorldSpeed", t.speed)
      setField(me, "LastDesiredWorldSpeed", t.speed)
      setField(me, "DesiredWorldDirection", { X = t.dirx, Y = t.diry, Z = 0 })
      setField(me, "AnimSpeedType", t.a.speedType)
      setField(me, "AnimMechanicType", t.a.mechanic)
      setField(me, "IsInIdle", t.a.idle)
      setField(me, "IsMovementInput", t.a.input)
    end)
    hookedClasses[clsPath] = true
    log("  hooked %s", fn)
  end)
  if not ok then log("  animation hook failed: %s", tostring(err)) end
end

local function driveGhostAnim(h)
  local g = ghost:K2_GetActorLocation()
  local dx, dy, dz = h.x - g.X, h.y - g.Y, h.z - g.Z
  local dist = math.sqrt(dx * dx + dy * dy)
  if dist > 600 or math.abs(dz) > 400 then
    ghost:K2_SetActorLocationAndRotation({ X = h.x, Y = h.y, Z = h.z }, { Pitch = 0, Yaw = h.yaw, Roll = 0 }, false, {}, true)
    return string.format("snap (was %.0f cm away)", dist)
  end
  local a = h.anim or {}
  local speed = a.speed or 0
  local dirx, diry = a.dx or 0, a.dy or 0
  if dist > 50 then  -- steer toward where you were and catch up a little
    dirx, diry = dx / dist, dy / dist
    speed = math.max(speed, 150) + dist * 0.5
  end
  animWriteError = nil
  animTarget = { a = a, speed = speed, dirx = dirx, diry = diry }
  writeAnimInputs(ghost, a, speed, dirx, diry)
  local v = ghost:GetVelocity()
  return string.format("anim drive (hook hits %d), %.0f cm away, ghost speed %.0f\n    you : %s\n    copy: %s%s", hookHits, dist,
    math.sqrt(v.X * v.X + v.Y * v.Y), animStr(a), animStr(readAnimInputs(ghost)),
    animWriteError and ("\n    write error: " .. animWriteError) or "")
end

local function driveGhostSpeed(h)
  local g = ghost:K2_GetActorLocation()
  local dx, dy, dz = h.x - g.X, h.y - g.Y, h.z - g.Z
  local dist = math.sqrt(dx * dx + dy * dy)
  if dist > 800 or math.abs(dz) > 600 then
    ghost:K2_SetActorLocationAndRotation({ X = h.x, Y = h.y, Z = h.z }, { Pitch = 0, Yaw = h.yaw, Roll = 0 }, false, {}, true)
    return string.format("snap (was %.0f cm away)", dist)
  end
  local speed, dirx, diry = h.speed, math.cos(math.rad(h.yaw)), math.sin(math.rad(h.yaw))
  if dist > 30 then dirx, diry = dx / dist, dy / dist; speed = speed + dist * 0.5 end
  if dist < 30 and h.speed < 20 then speed = 0 end
  local ok, err = pcall(function() ghost:SetWorldSpeedAndDirection(speed, { X = dirx, Y = diry, Z = 0 }) end)
  if not ok then return "drive failed: " .. tostring(err) end
  local v = ghost:GetVelocity()
  return string.format("speed order %.0f, %.0f cm away, ghost speed %.0f", speed, dist, math.sqrt(v.X * v.X + v.Y * v.Y))
end

local function driveGhostPuppet(h)
  local g = ghost:K2_GetActorLocation()
  local dx, dy = h.x - g.X, h.y - g.Y
  local dist = math.sqrt(dx * dx + dy * dy)
  ghost:K2_SetActorLocationAndRotation({ X = h.x, Y = h.y, Z = h.z }, { Pitch = 0, Yaw = h.yaw, Roll = 0 }, false, {}, true)
  local after = readAnimInputs(ghost)
  return string.format("puppet moved %.0f cm\n    you : %s\n    copy: %s%s", dist, animStr(h.anim), animStr(after),
                       animWriteError and ("\n    write error: " .. animWriteError) or "")
end

local function driveGhost(now, h)
  if ghostDrive == "anim" then return driveGhostAnim(h) end
  if ghostDrive == "puppet" then return driveGhostPuppet(h) end
  if ghostDrive == "speed" then return driveGhostSpeed(h) end
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
                                speed = math.sqrt(v.X * v.X + v.Y * v.Y), vx = v.X, vy = v.Y, vz = v.Z,
                                anim = readAnimInputs(p) })
        while #history > 2 and history[2].t <= now - DELAY do table.remove(history, 1) end
        if pendingAnimFix > 0 and math.floor(now * 2) ~= math.floor((now - 0.034) * 2) then
          pendingAnimFix = pendingAnimFix - 1
          if fixGhostAnimation(pendingAnimFix == 0) then
            pendingAnimFix = 0
            fixGhostAnimation(true)  -- one full report once it has worked
          end
        end
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

-- F6: round 6 - a student NPC body (it has the game's NPC walking animations) wearing your look.
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
-- ------------------------------------------------------------------ F7: animation probe
-- Round 10. Round 9 showed the animation fields we copied stay at 0 on YOUR character even
-- while you run, so the game's walk/run animation is driven by something else. This finds it:
-- press F7 standing still, then start running and press F7 again while still running. It logs
-- every number/flag that changed on your character's animation, movement and character objects.
local probeBefore = nil

local function snapshotProps(obj, label, out)
  if not valid(obj) then return end
  local ok, err = pcall(function()
    local cls = obj:GetClass()
    while valid(cls) do
      cls:ForEachProperty(function(prop)
        local name = prop:GetFName():ToString()
        local okv, v = pcall(function() return obj[name] end)
        if okv then
          local t = type(v)
          if t == "number" or t == "boolean" then
            out[label .. "." .. name] = v
          elseif t == "userdata" then
            -- vectors/rotators: record their parts if present
            pcall(function()
              if v.X ~= nil then out[label .. "." .. name .. ".X"] = v.X; out[label .. "." .. name .. ".Y"] = v.Y; out[label .. "." .. name .. ".Z"] = v.Z end
            end)
          end
        end
      end)
      cls = cls:GetSuperStruct()
    end
  end)
  if not ok then log("probe: could not read %s: %s", label, tostring(err)) end
end

local function probeSnapshot(pawn)
  local out = {}
  snapshotProps(pawn, "Character", out)
  pcall(function() snapshotProps(pawn.Mesh:GetAnimInstance(), "AnimInstance", out) end)
  pcall(function() snapshotProps(pawn.CharacterMovement, "Movement", out) end)
  pcall(function() snapshotProps(pawn.AnimationComponent, "AnimationComponent", out) end)
  return out
end

RegisterKeyBind(Key.F7, function()
  ExecuteInGameThread(function()
    local pawn = getPlayerPawn()
    if not pawn then return end
    if not probeBefore then
      probeBefore = probeSnapshot(pawn)
      local n = 0
      for _ in pairs(probeBefore) do n = n + 1 end
      log("probe: recorded %d values while standing. Now run, and press F7 again while running.", n)
      return
    end
    local after = probeSnapshot(pawn)
    local changed = {}
    for k, v in pairs(after) do
      local b = probeBefore[k]
      if b ~= nil and b ~= v then
        if type(v) ~= "number" or math.abs(v - b) > 0.001 then table.insert(changed, k) end
      end
    end
    table.sort(changed)
    log("probe: %d values changed between standing and running:", #changed)
    for _, k in ipairs(changed) do
      log("  %-70s %s -> %s", k, tostring(probeBefore[k]), tostring(after[k]))
    end
    probeBefore = nil
  end)
end)

log("UnwrittenDiscovery loaded. F5 player, F6 ghost (student wearing your look), F7 animation probe, F8 appearance, F9 ghost (preview character) [round 12]")
