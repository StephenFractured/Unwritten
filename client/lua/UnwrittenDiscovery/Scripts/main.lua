-- UnwrittenDiscovery: Phase 0 step 2. Runs inside Hogwarts Legacy through UE4SS.
-- No networking. It answers three questions on your own PC:
--   F5  What is the player? (class, position, meshes, animation blueprint)
--   F6  Can we spawn a second body and move it? ("ghost" that replays you 2 s behind)
--   F7  What other characters exist nearby? (candidate classes for remote-player puppets)
-- Output goes to the UE4SS console and UE4SS.log next to the game exe.

local TAG = "[Unwritten] "
local function log(fmt, ...) print(TAG .. string.format(fmt, ...) .. "\n") end

local function valid(o) return o ~= nil and o:IsValid() end

local function className(o)
  if not valid(o) then return "<nil>" end
  return o:GetClass():GetFName():ToString()
end

-- The player pawn class is a guess until F5 confirms it. Community dumps call it
-- "Biped_Player"; if that finds nothing we fall back to the first PlayerController's pawn.
local function getPlayerPawn()
  local pawn = FindFirstOf("Biped_Player")
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

-- ------------------------------------------------------------------ F6: ghost test
-- Spawns a body that follows your exact path 2 seconds late. If it moves and turns with
-- you, spawning + transform sync work. If it also animates, animation sync is solved too.
local ghost = nil
local history = {}  -- ring of {t, loc, yaw}
local DELAY = 2.0
local ghostLoopStarted = false

local function spawnActor(world, classPath, loc)
  local statics = StaticFindObject("/Script/Engine.Default__GameplayStatics")
  local cls = StaticFindObject(classPath)
  if not valid(cls) then log("class not found: %s", classPath); return nil end
  local xf = {
    Rotation = { X = 0, Y = 0, Z = 0, W = 1 },
    Translation = { X = loc.X, Y = loc.Y, Z = loc.Z },
    Scale3D = { X = 1, Y = 1, Z = 1 },
  }
  -- 1 = AlwaysSpawn (ignore collisions)
  local a = statics:BeginDeferredActorSpawnFromClass(world, cls, xf, 1, nil)
  if not valid(a) then return nil end
  statics:FinishSpawningActor(a, xf)
  return a
end

-- Puppet v1: a plain SkeletalMeshActor wearing copies of the player's meshes.
-- It will probably T-pose: the game's AnimBP expects a real character. That is fine for
-- the transform test; animation is milestone M3 (see the Phase 0 plan).
local function buildGhost(pawn)
  local world = pawn:GetWorld()
  local loc = pawn:K2_GetActorLocation()
  local a = spawnActor(world, "/Script/Engine.SkeletalMeshActor", loc)
  if not a then log("ghost spawn failed"); return nil end
  local dst = a.SkeletalMeshComponent
  local comps = pawn:K2_GetComponentsByClass(StaticFindObject("/Script/Engine.SkeletalMeshComponent"))
  if #comps > 0 then
    local main = comps[1]:get()
    dst:SetSkeletalMesh(main.SkeletalMesh, true)
    -- Try reusing the player's animation blueprint class. Log what happens.
    local anim = main:GetAnimInstance()
    if valid(anim) then
      dst:SetAnimInstanceClass(anim:GetClass())
      log("ghost anim class set to %s", className(anim))
    end
  end
  log("ghost spawned: %s", a:GetFullName())
  return a
end

RegisterKeyBind(Key.F6, function()
  ExecuteInGameThread(function()
    local pawn = getPlayerPawn()
    if not pawn then log("load a save first"); return end
    if valid(ghost) then ghost:K2_DestroyActor(); ghost = nil; log("ghost removed"); return end
    ghost = buildGhost(pawn)
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
        table.insert(history, { t = now, x = l.X, y = l.Y, z = l.Z, yaw = p:K2_GetActorRotation().Yaw })
        while #history > 2 and history[2].t <= now - DELAY do table.remove(history, 1) end
        local h = history[1]
        if h.t <= now - DELAY then
          ghost:K2_SetActorLocationAndRotation({ X = h.x, Y = h.y, Z = h.z },
                                               { Pitch = 0, Yaw = h.yaw, Roll = 0 }, false, {}, true)
        end
      end)
      return false  -- keep looping
    end)
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

log("UnwrittenDiscovery loaded. F5 = describe player, F6 = ghost test, F7 = list characters")
