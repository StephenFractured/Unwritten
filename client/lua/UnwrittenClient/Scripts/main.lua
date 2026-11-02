-- UnwrittenClient: Phase 0 steps 3-4. Two (or more) players see each other.
-- Needs the native half (dlls/main.dll in this same mod folder) for UW_* functions.
--   F3  connect to the server in config.lua / disconnect
-- Each remote player is a puppet actor moved by interpolated server snapshots.

local cfg = require("config")
local TAG = "[Unwritten] "
local function log(fmt, ...) print(TAG .. string.format(fmt, ...) .. "\n") end
local function valid(o) return o ~= nil and o:IsValid() end

if UW_Connect == nil then
  log("native bridge missing: put the built main.dll in UnwrittenClient/dlls/")
  return
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
-- Puppet strategy is the main thing Phase 0 is testing. v1 = SkeletalMeshActor wearing the
-- local player's mesh (so remote players look like you for now; appearance sync is M5).
local PUPPET_CLASS = "/Script/Engine.SkeletalMeshActor"
local statics = nil
local skelCompClass = nil

local function spawnPuppet(x, y, z)
  local pawn = getPlayerPawn()
  if not pawn then return nil end
  statics = statics or StaticFindObject("/Script/Engine.Default__GameplayStatics")
  skelCompClass = skelCompClass or StaticFindObject("/Script/Engine.SkeletalMeshComponent")
  local cls = StaticFindObject(PUPPET_CLASS)
  local xf = { Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = { X = x, Y = y, Z = z },
               Scale3D = { X = 1, Y = 1, Z = 1 } }
  local a = statics:BeginDeferredActorSpawnFromClass(pawn:GetWorld(), cls, xf, 1, nil)
  if not valid(a) then return nil end
  statics:FinishSpawningActor(a, xf)
  local comps = pawn:K2_GetComponentsByClass(skelCompClass)
  if #comps > 0 then
    local main = comps[1]:get()
    a.SkeletalMeshComponent:SetSkeletalMesh(main.SkeletalMesh, true)
    local anim = main:GetAnimInstance()
    if valid(anim) then a.SkeletalMeshComponent:SetAnimInstanceClass(anim:GetClass()) end
  end
  return a
end

-- ------------------------------------------------------------------ remote players
local myId = nil
local remotes = {}  -- id -> { name, actor, buf = { {t, x, y, z, yaw, speed, flags} ... } }
local connected = false

local function remote(id)
  local r = remotes[id]
  if not r then r = { name = "player" .. id, buf = {} }; remotes[id] = r end
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

local function handleEvents(now)
  local events = UW_Poll()
  for i = 1, #events do
    local e = events[i]
    if e.type == "state" then
      if e.id ~= myId then
        local r = remote(e.id)
        local last = r.buf[#r.buf]
        if not last or e.tick > last.tick then
          table.insert(r.buf, { t = now, tick = e.tick, x = e.x, y = e.y, z = e.z, yaw = e.yaw,
                                speed = e.speed, flags = e.flags })
          if #r.buf > 30 then table.remove(r.buf, 1) end
        end
      end
    elseif e.type == "welcome" then
      myId = e.id; log("connected as #%d", myId)
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
  local renderT = now - cfg.interpDelay
  for id, r in pairs(remotes) do
    local buf = r.buf
    if #buf > 0 then
      if not valid(r.actor) then r.actor = spawnPuppet(buf[#buf].x, buf[#buf].y, buf[#buf].z) end
      if valid(r.actor) then
        -- find the two samples around renderT; hold the newest if we run out (no extrapolation yet)
        local a, b = buf[1], buf[#buf]
        for k = 1, #buf - 1 do
          if buf[k].t <= renderT and buf[k + 1].t >= renderT then a, b = buf[k], buf[k + 1]; break end
        end
        local t = 1
        if b.t > a.t then t = math.max(0, math.min(1, (renderT - a.t) / (b.t - a.t))) end
        local x = a.x + (b.x - a.x) * t
        local y = a.y + (b.y - a.y) * t
        local z = a.z + (b.z - a.z) * t
        local yaw = lerpAngle(a.yaw, b.yaw, t)
        r.actor:K2_SetActorLocationAndRotation({ X = x, Y = y, Z = z }, { Pitch = 0, Yaw = yaw, Roll = 0 },
                                               false, {}, true)
        -- TODO M3: push b.speed / b.flags into the puppet's AnimInstance variables once the
        -- AnimBP's locomotion variables are known (UE4SS Live View on the player's AnimInstance).
      end
    end
  end
end

local function sendOwnState()
  local p = getPlayerPawn()
  if not p then return end
  local l = p:K2_GetActorLocation()
  local v = p:GetVelocity()
  local speed = math.sqrt(v.X * v.X + v.Y * v.Y)
  local flags = 0
  if math.abs(v.Z) > 50 then flags = flags | 1 end  -- kAnimInAir (rough until M3)
  UW_SendState(l.X, l.Y, l.Z, p:K2_GetActorRotation().Yaw, speed, flags, 0, 0)
end

local loopStarted = false
local function startLoop()
  if loopStarted then return end
  loopStarted = true
  LoopAsync(math.floor(1000 / cfg.sendHz), function()
    ExecuteInGameThread(function()
      if not connected then return end
      local now = os.clock()
      handleEvents(now)
      sendOwnState()
      renderRemotes(now)
    end)
    return false
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
