-- Night City Companions -- small helpers shared by the modules: logging, safe calls, files, vectors.
local U = {}

U.lastError = nil
U.log = {}

function U.say(fmt, ...)
  local ok, line = pcall(string.format, fmt, ...)
  if not ok then line = tostring(fmt) end
  line = '[Companions] ' .. line
  print(line)
  table.insert(U.log, line)
  if #U.log > 60 then table.remove(U.log, 1) end
end

-- A step written only to the log file (CET writes print to NightCityCompanions.log), to find where a crash happened.
function U.trace(fmt, ...)
  local ok, line = pcall(string.format, fmt, ...)
  print('[Companions] ' .. (ok and line or tostring(fmt)))
end

-- pcall that remembers and logs the failure once per distinct message.
local seen = {}
function U.try(what, fn, ...)
  local ok, a, b, c = pcall(fn, ...)
  if ok then return true, a, b, c end
  local msg = what .. ': ' .. tostring(a)
  U.lastError = msg
  if not seen[msg] then
    seen[msg] = true
    U.say('%s', msg)
  end
  return false
end

function U.readJson(path)
  local f = io.open(path, 'r')
  if not f then return nil end
  local body = f:read('*a')
  f:close()
  if body == nil or body == '' then return nil end
  local ok, value = pcall(json.decode, body)
  if ok then return value end
  return nil
end

function U.writeJson(path, value)
  local ok, body = pcall(json.encode, value)
  if not ok then U.say('cannot encode %s: %s', path, tostring(body)) return false end
  -- write beside, then rename, so the bridge never reads half a file
  local tmp = path .. '.tmp'
  local f = io.open(tmp, 'w')
  if not f then
    f = io.open(path, 'w')
    if not f then U.say('cannot write %s', path) return false end
    f:write(body) f:close()
    return true
  end
  f:write(body)
  f:close()
  local renamed = false
  if os and os.rename then
    pcall(function() if os.remove then os.remove(path) end end)
    renamed = pcall(os.rename, tmp, path) and true or false
    -- os.rename returns nil, err on failure without raising
    local check = io.open(path, 'r')
    if check then check:close() else renamed = false end
  end
  if not renamed then
    local g = io.open(path, 'w')
    if not g then return false end
    g:write(body) g:close()
  end
  return true
end

function U.remove(path)
  if os and os.remove then return pcall(os.remove, path) end
  -- no os.remove in this sandbox: blank it so it is not read again
  local f = io.open(path, 'w')
  if f then f:close() end
  return false
end

function U.clamp(x, lo, hi)
  if x < lo then return lo end
  if x > hi then return hi end
  return x
end

function U.dist(a, b)
  local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
  return math.sqrt(dx * dx + dy * dy + dz * dz)
end

function U.dist2d(a, b)
  local dx, dy = a.x - b.x, a.y - b.y
  return math.sqrt(dx * dx + dy * dy)
end

-- A person's local offset (right, forward, up) in metres, to a world position, at their scale.
function U.localToWorld(entity, offset, scale)
  local p = entity:GetWorldPosition()
  local f = entity:GetWorldForward()
  local fx, fy = f.x, f.y
  local fl = math.sqrt(fx * fx + fy * fy)
  if fl < 1e-4 then fx, fy, fl = 0, 1, 1 end
  fx, fy = fx / fl, fy / fl
  -- right = forward x up (z-up world)
  local rx, ry = fy, -fx
  local s = scale or 1
  return Vector4.new(
    p.x + (rx * offset[1] + fx * offset[2]) * s,
    p.y + (ry * offset[1] + fy * offset[2]) * s,
    p.z + offset[3] * s,
    1.0)
end

-- A native global function from a RED4ext plugin, if it is installed (nil otherwise).
function U.native(name)
  local f = rawget(_G, name)
  if type(f) == 'function' then return f end
  local ok, g = pcall(function() return Game[name] end)
  if ok and type(g) == 'function' then
    return function(...) return Game[name](...) end
  end
  return nil
end

function U.nameOf(entity)
  local name
  pcall(function()
    local n = entity:GetTweakDBDisplayName(true)
    if n and n ~= '' then name = n end
  end)
  if not name then
    pcall(function()
      local n = entity:GetDisplayName()
      if n and n ~= '' then name = n end
    end)
  end
  if not name then
    pcall(function() name = Game.NameToString(entity:GetCurrentAppearanceName()) end)
  end
  return name or 'Stranger'
end

function U.recordOf(entity)
  local id
  pcall(function() id = TDBID.ToStringDEBUG(entity:GetRecordID()) end)
  return id
end

function U.appearanceOf(entity)
  local a
  pcall(function() a = Game.NameToString(entity:GetCurrentAppearanceName()) end)
  return a
end

function U.idKey(entity)
  local k
  pcall(function() k = tostring(entity:GetEntityID().hash) end)
  return k
end

return U
