-- UnwrittenClient: Phase 0 steps 3-4. Two (or more) players see each other.
-- Needs the native half (dlls/main.dll in this same mod folder) for UW_* functions.
--   F3  connect to the server in config.lua / disconnect
-- Each remote player is a puppet actor moved by interpolated server snapshots.

local cfg = require("config")
local appearance = require("appearance")
local TAG = "[Unwritten] "
local function log(fmt, ...) print(TAG .. string.format(fmt, ...) .. "\n") end
local function valid(o) return o ~= nil and o:IsValid() end

if UW_Connect == nil then
  log("native bridge missing: put the built main.dll in UnwrittenClient/dlls/")
  return
end

-- Run fn on the game thread every `ms`. Uses UE4SS's game-thread timer when available: the old
-- LoopAsync + ExecuteInGameThread pattern hands a new closure across Lua states 30 times a second,
-- and that corrupted the Lua state after ~10-60 s (rounds 8, 9, 16, 19 crashes; round 19 logged
-- "No overload found for function 'FindFirstOf'" for a plain string argument right before dying).
local function gameLoop(ms, fn)
  local guarded = function()
    local ok, err = pcall(fn)
    if not ok then print("[Unwritten] loop error: " .. tostring(err) .. "\n") end
  end
  if LoopInGameThreadWithDelay then return LoopInGameThreadWithDelay(ms, guarded) end
  LoopAsync(ms, function() ExecuteInGameThread(guarded); return false end)
end

local function getPlayerPawn()
  local pawn = FindFirstOf("BP_Biped_Player_C")  -- confirmed from the header dump
  if valid(pawn) then return pawn end
  pawn = FindFirstOf("Biped_Player")
  if valid(pawn) then return pawn end
  local pc = FindFirstOf("PlayerController")
  if valid(pc) and valid(pc.Pawn) then return pc.Pawn end
  return nil
end

-- ------------------------------------------------------------------ puppets
-- Puppet v2, proven in UnwrittenDiscovery round 20: the game's character-preview body wearing a
-- look, placed every frame with K2_TeleportTo, its mesh playing the game's own human locomotion
-- clips directly (idle / walk / jog / sprint) chosen by the networked speed. Every remote player
-- starts from a base look, then wears the look that player sent (appearance.lua, milestone M5).
local PUPPET_CLASS = "/Script/Phoenix.PHX_Biped_Preview_Actor"
local CLIP_PATHS = {
  idle = "/Game/Animation/Human/Hu_BM_Idle_Casual_Loop_anm.Hu_BM_Idle_Casual_Loop_anm",
  walk = "/Game/Animation/Human/Hu_BM_Walk_Loop_Fwd_anm.Hu_BM_Walk_Loop_Fwd_anm",
  run = "/Game/Animation/Human/Hu_BM_Jog_Loop_Fwd_anm.Hu_BM_Jog_Loop_Fwd_anm",
  sprint = "/Game/Animation/Human/Hu_BM_Sprint_Loop_Fwd_anm.Hu_BM_Sprint_Loop_Fwd_anm",
}
local NOMINAL = { idle = 1, walk = 160, run = 420, sprint = 650 }
local clips = nil
local statics = nil

local function loadClips()
  if clips then return clips end
  local c, n = {}, 0
  for state, path in pairs(CLIP_PATHS) do
    local seq = StaticFindObject(path)
    if valid(seq) then c[state] = seq; n = n + 1 end
  end
  c.run = c.run or c.walk; c.sprint = c.sprint or c.run; c.walk = c.walk or c.run
  log("puppet clips loaded: %d of 4", n)
  clips = c
  return clips
end

-- Base look for a new puppet before the synced look goes on top. Normally your own (any complete
-- body works, every piece gets replaced). In the one-PC echo test we start from a student's look
-- instead, so if the puppet ends up looking like you, the synced appearance did that, not the base.
local function baseCharacterId(pawn, isEchoOfMe)
  if isEchoOfMe and cfg.echoTestBase ~= false then
    local ok, id = pcall(function()
      local s = FindFirstOf("BP_Student_C")
      if valid(s) then return s.CCComponent.CharacterName end
    end)
    if ok and id then log("echo test: puppet starts as student look %s", id:ToString()); return id end
    log("echo test: no student found nearby, puppet starts from your own look")
  end
  return pawn.Customization.CharacterName
end

local function spawnPuppet(x, y, z, yaw, isEchoOfMe)
  local pawn = getPlayerPawn()
  if not pawn then return nil end
  statics = statics or StaticFindObject("/Script/Engine.Default__GameplayStatics")
  local cls = StaticFindObject(PUPPET_CLASS)
  local half = math.rad(yaw or 0) / 2
  local xf = { Rotation = { X = 0, Y = 0, Z = math.sin(half), W = math.cos(half) },
               Translation = { X = x, Y = y, Z = z }, Scale3D = { X = 1, Y = 1, Z = 1 } }
  local a = statics:BeginDeferredActorSpawnFromClass(pawn:GetWorld(), cls, xf, 1, nil)
  if not valid(a) then return nil end
  statics:FinishSpawningActor(a, xf)
  pcall(function()
    a.Customization:SetCharacterID(baseCharacterId(pawn, isEchoOfMe))
    a.Customization:ReloadCharacter()
  end)
  pcall(function() a:SetActorEnableCollision(false) end)
  return a
end

-- Once the look has loaded: same mesh offset as the player, always tick, play clips directly.
local function preparePuppet(r)
  local mesh = r.actor.Mesh
  if not valid(mesh.SkeletalMesh) then return false end
  local pawn = getPlayerPawn()
  pcall(function()
    local rl, rr = pawn.Mesh.RelativeLocation, pawn.Mesh.RelativeRotation
    mesh:K2_SetRelativeLocationAndRotation({ X = rl.X, Y = rl.Y, Z = rl.Z },
                                           { Pitch = rr.Pitch, Yaw = rr.Yaw, Roll = rr.Roll }, false, {}, true)
  end)
  pcall(function() mesh.VisibilityBasedAnimTickOption = 0; mesh:SetComponentTickEnabled(true) end)
  mesh:SetAnimationMode(1)  -- AnimationSingleNode
  loadClips()
  r.clip = nil
  return true
end

local function animatePuppet(r, speed)
  local state = "idle"
  if speed > 20 then state = "walk" end
  if speed > 260 then state = "run" end
  if speed > 560 then state = "sprint" end
  local mesh = r.actor.Mesh
  if state ~= r.clip and clips[state] then
    mesh:PlayAnimation(clips[state], true)
    r.clip = state
  end
  if r.clip ~= "idle" then mesh:SetPlayRate(math.max(0.6, math.min(1.6, speed / NOMINAL[r.clip]))) end
end

-- ------------------------------------------------------------------ remote players
local myId = nil
local sendMyLook  -- defined below handleEvents' helpers
local remotes = {}  -- id -> { name, actor, buf = { {t, x, y, z, yaw, speed, flags} ... } }
local connected = false

local function remote(id)
  local r = remotes[id]
  if not r then r = { name = "player" .. math.tointeger(id), buf = {} }; remotes[id] = r end
  return r
end

local function removeRemote(id)
  local r = remotes[id]
  if r and valid(r.actor) then r.actor:K2_DestroyActor() end
  remotes[id] = nil
end

local function lerpAngle(a, b, t)
  local d = (b - a + 180) % 360 - 180
  return a + d * t
end

sendMyLook = function()
  local pawn = getPlayerPawn()
  if not pawn then log("look: no player yet, not sent"); return end
  local blob, st = appearance.capture(pawn.Customization)
  log("look captured: %d pieces, %d outfit items, %d sliders, %d bytes", st.pieces, st.outfit, st.sliders, #blob)
  for _, e in ipairs(st.errors) do log("  look capture problem: %s", e) end
  if cfg.logLook then for line in blob:gmatch("[^\n]+") do log("  look> %s", line) end end
  if not UW_SetAppearance then log("look: main.dll is older than this script, rebuild it"); return end
  if not UW_SetAppearance(blob) then log("look: blob empty or too big, not sent") end
end

local function handleEvents(now)
  local events = UW_Poll()
  for i = 1, #events do
    local e = events[i]
    if e.type == "state" then
      if e.id ~= myId or cfg.echoSelf then
        local r = remote(e.id)
        local last = r.buf[#r.buf]
        if not last or e.tick > last.tick then
          table.insert(r.buf, { t = now, tick = e.tick, x = e.x, y = e.y, z = e.z, yaw = e.yaw,
                                speed = e.speed, flags = e.flags })
          if #r.buf > 120 then table.remove(r.buf, 1) end
        end
      end
    elseif e.type == "welcome" then
      myId = e.id; log("connected as #%d%s", myId, cfg.echoSelf and " (echo test: your own state comes back as a puppet)" or "")
      sendMyLook()
    elseif e.type == "appearance" then
      local r = remote(e.id)
      r.look, r.lookApplied = e.data, false
      log("look received for %s (%d bytes)", r.name, #e.data)
    elseif e.type == "joined" then
      remote(e.id).name = e.name; log("%s joined", e.name)
    elseif e.type == "left" then
      log("%s left", remotes[e.id] and remotes[e.id].name or ("#" .. e.id)); removeRemote(e.id)
    elseif e.type == "correction" then
      local p = getPlayerPawn()
      if p then p:K2_SetActorLocation({ X = e.x, Y = e.y, Z = e.z }, false, {}, true) end
      log("server corrected your position")
    elseif e.type == "disconnected" then
      log("disconnected from server"); connected = false
      for id in pairs(remotes) do removeRemote(id) end
    end
  end
end

local function renderRemotes(now)
  for id, r in pairs(remotes) do
    local buf = r.buf
    if #buf > 0 then
      local renderT = now - cfg.interpDelay - ((id == myId) and (cfg.echoDelay or 1.5) or 0)
      if not valid(r.actor) then
        r.actor = spawnPuppet(buf[#buf].x, buf[#buf].y, buf[#buf].z, buf[#buf].yaw, id == myId)
        r.ready, r.lookApplied, r.readyAt = false, false, nil
        if valid(r.actor) then log("puppet spawned for %s", r.name) end
      end
      if valid(r.actor) then
        if not r.ready then r.ready = preparePuppet(r) end
        if r.ready and not r.readyAt then r.readyAt = now end
        -- Put the synced look on once the base look has fully loaded (else the base load overwrites it).
        local baseLoading = false
        pcall(function() baseLoading = r.actor.Customization:IsLoading() end)
        if r.ready and r.look and not r.lookApplied and not baseLoading and now - r.readyAt > 0.5 then
          r.lookApplied = true
          local st = appearance.apply(r.actor.Customization, r.look)
          log("look applied to %s: %d pieces, %d params, %d sliders, %d failed%s", r.name, st.pieces, st.params,
              st.sliders, st.failed, st.firstError and (" (first: " .. st.firstError .. ")") or "")
          r.ready = preparePuppet(r)  -- meshes changed: set the anim mode and clip again
        end
        -- find the two samples around renderT; hold the oldest/newest if we run out (no extrapolation yet)
        local a, b = buf[1], buf[1]
        if renderT >= buf[#buf].t then a, b = buf[#buf], buf[#buf] end
        for k = 1, #buf - 1 do
          if buf[k].t <= renderT and buf[k + 1].t >= renderT then a, b = buf[k], buf[k + 1]; break end
        end
        local t = 1
        if b.t > a.t then t = math.max(0, math.min(1, (renderT - a.t) / (b.t - a.t))) end
        local x = a.x + (b.x - a.x) * t
        local y = a.y + (b.y - a.y) * t
        local z = a.z + (b.z - a.z) * t
        local yaw = lerpAngle(a.yaw, b.yaw, t)
        r.actor:K2_TeleportTo({ X = x, Y = y, Z = z }, { Pitch = 0, Yaw = yaw, Roll = 0 })
        if r.ready then animatePuppet(r, a.speed + (b.speed - a.speed) * t) end
      end
    end
  end
end

local function sendOwnState(now)
  local p = getPlayerPawn()
  if not p then return end
  local l = p:K2_GetActorLocation()
  local yaw = p:K2_GetActorRotation().Yaw
  -- Read the movement component's Velocity field (calling GetVelocity() failed on some frames).
  local speed, vz = 0, 0
  pcall(function()
    local v = p.CharacterMovement.Velocity
    speed, vz = math.sqrt(v.X * v.X + v.Y * v.Y), v.Z
  end)
  local flags = 0
  if math.abs(vz) > 50 then flags = flags | 1 end  -- kAnimInAir (rough)
  UW_SendState(l.X, l.Y, l.Z, yaw, speed, flags, 0, 0)
end

-- Wall-clock seconds from the game (os.clock is CPU time, wrong for interpolation).
local gameStatics = nil
local function wallNow()
  local t = nil
  pcall(function()
    gameStatics = gameStatics or StaticFindObject("/Script/Engine.Default__GameplayStatics")
    t = gameStatics:GetRealTimeSeconds(getPlayerPawn())
  end)
  return t or os.clock()
end

local loopStarted = false
local function startLoop()
  if loopStarted then return end
  loopStarted = true
  gameLoop(math.floor(1000 / cfg.sendHz), function()
    if not connected then return end
    local now = wallNow()
    -- Each step guarded so one bad frame (loading screen, cutscene) never kills the loop.
    local ok, err = pcall(handleEvents, now)
    if not ok then log("poll error: %s", tostring(err)) end
    ok, err = pcall(sendOwnState, now)
    if not ok then log("send error: %s", tostring(err)) end
    ok, err = pcall(renderRemotes, now)
    if not ok then log("render error: %s", tostring(err)) end
  end)
end

RegisterKeyBind(Key.F3, function()
  if connected then
    UW_Disconnect(); connected = false
    ExecuteInGameThread(function() for id in pairs(remotes) do removeRemote(id) end end)
    log("disconnected"); return
  end
  if UW_Connect(cfg.server, cfg.port, cfg.name) then
    connected = true; log("connecting to %s:%d ...", cfg.server, cfg.port); startLoop()
  else
    log("could not start connection to %s:%d", cfg.server, cfg.port)
  end
end)

log("UnwrittenClient loaded. F3 = connect to %s:%d", cfg.server, cfg.port)
