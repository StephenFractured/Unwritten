-- Appearance sync (Phase 0 M5): turn the local player's look into a small text blob, and put a
-- blob back onto another body. No game files are sent, only names and numbers: every player owns
-- the game, so each client loads the same pieces from its own install.
--
-- Source: UCustomizableCharacterComponent (pawn.Customization), from the header dump:
--   CharacterItems  TMap<FName piece type, UAddOnMeshProperties*>  (head, hair, body, ...)
--     .CharacterPiece (UCharacterPiece asset) + Scalar/Vector/Texture overrides (skin, colours)
--   CurrentOutfit.Name + Outfits[name].OutfitItems  (worn gear, same shape)
--   CacheCCD.BoneScaleValues / Scale  (face and body sliders)
-- Apply: SetAddOnMesh(type, pieceName), SetScalar/Vector/TextureParameter(type, param, value),
--   SetBoneSliderScale, SetScale.
--
-- Blob: one record per line, fields split by "|":
--   G|gender   P|type|piece|flipped   S|type|param|value   V|type|param|r,g,b,a
--   T|type|param|/Game/path.Object   B|slider|value   K|scale   O|outfitName
-- Items from the worn outfit use "p", "s", "v", "t" (lowercase) so we can tell them apart in logs.

local M = {}

local function valid(o) return o ~= nil and o.IsValid ~= nil and o:IsValid() end
local function str(fname) return fname:ToString() end

-- "Texture2D /Game/Foo/Bar.Bar" -> "/Game/Foo/Bar.Bar"
local function objectPath(obj)
  local full = obj:GetFullName()
  return full:match("^%S+%s+(.+)$") or full
end

local function eachMap(map, fn)
  map:ForEach(function(k, v) fn(k:get(), v:get()) end)
end

local function captureProps(lines, lower, typ, props)
  if not valid(props) then return end
  local piece = props.CharacterPiece
  local pname = valid(piece) and str(piece:GetFName()) or "None"
  local P, S, V, T = "P", "S", "V", "T"
  if lower then P, S, V, T = "p", "s", "v", "t" end
  lines[#lines + 1] = string.format("%s|%s|%s|%d", P, typ, pname, props.bIsFlipped and 1 or 0)
  pcall(eachMap, props.ScalarOverrides, function(k, v)
    lines[#lines + 1] = string.format("%s|%s|%s|%.5g", S, typ, str(k), v)
  end)
  pcall(eachMap, props.VectorOverrides, function(k, c)
    lines[#lines + 1] = string.format("%s|%s|%s|%.5g,%.5g,%.5g,%.5g", V, typ, str(k), c.R, c.G, c.B, c.A)
  end)
  pcall(eachMap, props.TextureOverrides, function(k, tex)
    if valid(tex) then lines[#lines + 1] = string.format("%s|%s|%s|%s", T, typ, str(k), objectPath(tex)) end
  end)
end

-- Returns blob, stats table. Every part is guarded: a missing field drops that part, not the blob.
function M.capture(cc)
  local lines, stats = {}, { pieces = 0, outfit = 0, sliders = 0, errors = {} }
  local function try(label, fn)
    local ok, err = pcall(fn)
    if not ok then stats.errors[#stats.errors + 1] = label .. ": " .. tostring(err) end
  end
  try("gender", function() lines[#lines + 1] = "G|" .. tostring(cc.Gender) end)
  try("items", function()
    eachMap(cc.CharacterItems, function(k, props)
      captureProps(lines, false, str(k), props); stats.pieces = stats.pieces + 1
    end)
  end)
  try("outfit", function()
    local name = str(cc.CurrentOutfit.Name)
    lines[#lines + 1] = "O|" .. name
    eachMap(cc.Outfits, function(k, outfit)
      if str(k) == name then
        eachMap(outfit.OutfitItems, function(t, props)
          captureProps(lines, true, str(t), props); stats.outfit = stats.outfit + 1
        end)
      end
    end)
  end)
  try("sliders", function()
    local ccd = cc.CacheCCD
    if not valid(ccd) then return end
    eachMap(ccd.BoneScaleValues, function(k, v)
      lines[#lines + 1] = string.format("B|%s|%.5g", str(k), v); stats.sliders = stats.sliders + 1
    end)
    lines[#lines + 1] = string.format("K|%.5g", ccd.Scale)
  end)
  return table.concat(lines, "\n"), stats
end

local function split(line)
  local f = {}
  for part in (line .. "|"):gmatch("([^|]*)|") do f[#f + 1] = part end
  return f
end

local function findTexture(path)
  local t = StaticFindObject(path)
  if valid(t) then return t end
  if LoadAsset then
    local ok, loaded = pcall(LoadAsset, path)
    if ok and valid(loaded) then return loaded end
  end
  return nil
end

-- Put a blob onto a body's CustomizableCharacterComponent. Pieces first (loaded synchronously so the
-- parameter overrides land on the new meshes), then overrides, then sliders. Returns stats.
function M.apply(cc, blob)
  local st = { pieces = 0, params = 0, sliders = 0, failed = 0, firstError = nil }
  local function try(fn, ...)
    local ok, err = pcall(fn, ...)
    if ok then return true end
    st.failed = st.failed + 1
    st.firstError = st.firstError or tostring(err)
    return false
  end
  local recs = {}
  for line in blob:gmatch("[^\n]+") do recs[#recs + 1] = split(line) end
  try(function() cc:SetAsyncLoad(false) end)
  for _, f in ipairs(recs) do
    local k = f[1]
    if (k == "P" or k == "p") and f[3] ~= "None" then
      if try(function() cc:SetAddOnMesh(FName(f[2]), FName(f[3]), true) end) then st.pieces = st.pieces + 1 end
      if f[4] == "1" then try(function() cc:SetFlipped(FName(f[2]), true) end) end
    end
  end
  for _, f in ipairs(recs) do
    local k = f[1]:upper()
    if k == "S" then
      if try(function() cc:SetScalarParameter(FName(f[2]), FName(f[3]), tonumber(f[4]), false) end) then st.params = st.params + 1 end
    elseif k == "V" then
      local r, g, b, a = f[4]:match("([^,]+),([^,]+),([^,]+),([^,]+)")
      local col = { R = tonumber(r), G = tonumber(g), B = tonumber(b), A = tonumber(a) }
      if try(function() cc:SetVectorParameter(FName(f[2]), FName(f[3]), col, false) end) then st.params = st.params + 1 end
    elseif k == "T" then
      local tex = findTexture(f[4])
      if tex and try(function() cc:SetTextureParameter(FName(f[2]), FName(f[3]), tex, false) end) then
        st.params = st.params + 1
      end
    elseif k == "B" and f[1] == "B" then
      if try(function() cc:SetBoneSliderScale(FName(f[2]), tonumber(f[3])) end) then st.sliders = st.sliders + 1 end
    elseif k == "K" and f[1] == "K" then
      try(function() cc:SetScale(tonumber(f[2])) end)
    end
  end
  return st
end

return M
