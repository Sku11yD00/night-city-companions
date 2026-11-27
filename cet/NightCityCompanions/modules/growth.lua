-- Night City Companions -- size: a follower grows (or shrinks) smoothly toward the size asked for, and can keep growing slowly.
--
-- The body is drawn at that size by the CompanionScale RED4ext plugin (red4ext/CompanionScale), which writes the
-- scale into the person's animation pose every frame. It has to be told again at least every 2.5 s or it lets go, so
-- this asks twice a second when nothing changes and every frame while the size is moving. Without the plugin nothing
-- is scaled and the window says so.
local U = require('modules/util')
local C = require('modules/config')
local R = require('modules/roster')

local G = {}
-- Looked up on first use, not while the mod's files load: the game is not there yet at that point.
-- Not found yet is asked again every few seconds (in the main menu the game's functions may not all be there).
local scaleNative
local nextLook, looks = 0, 0
local function lookUp()
  if scaleNative then return scaleNative end
  if os.clock() < nextLook then return nil end
  nextLook = os.clock() + 5
  looks = looks + 1
  local ok, f = pcall(U.native, 'CompanionScale')
  scaleNative = ok and f or nil
  G.available = scaleNative ~= nil
  if scaleNative or looks <= 3 then
    local kind = 'none'
    pcall(function() kind = 'raw ' .. type(rawget(_G, 'CompanionScale')) .. ' / global ' .. type(_G['CompanionScale']) .. ' / Game: ' .. type(Game['CompanionScale']) end)
    U.trace('growth plugin %s (look %d; global %s)', scaleNative and 'found' or 'NOT found', looks, kind)
  end
  return scaleNative
end
G.available = false
G.lookUp = lookUp

local function send(f, scale)
  if not lookUp() or not R.alive(f) then return false end
  local ok, yes = pcall(scaleNative, f.entity, scale, C.v.scaleMode or 0)
  -- one line each time the answer changes, so trace.log shows whether the plugin found the person
  local answer = ok and (yes and 'yes' or 'no') or ('error ' .. tostring(yes))
  if f.lastScaleAnswer ~= answer then
    f.lastScaleAnswer = answer
    U.trace('size %s: %.2f (mode %d), plugin answered %s', f.name, scale, C.v.scaleMode or 0, answer)
  end
  return ok and yes
end

function G.setTarget(f, target)
  if not f then return end
  f.targetScale = U.clamp(target, C.v.minScale, C.v.maxScale)
  R.save()
end

function G.nudge(f, by)
  if not f then return end
  G.setTarget(f, (f.targetScale or 1) + by)
end

function G.reset(f)
  if not f then return end
  f.targetScale = 1.0
  R.save()
end

local refresh = 0
function G.update(dt)
  if not lookUp() then return end
  refresh = refresh + dt
  local periodic = refresh >= 0.5
  if periodic then refresh = 0 end
  for _, f in ipairs(R.list) do
    if C.v.gradualGrowth and R.alive(f) then
      f.targetScale = math.min(C.v.maxScale, (f.targetScale or 1) + C.v.gradualPerMinute * dt / 60)
    end
    local target = f.targetScale or 1
    local now = f.scale or 1
    local moving = math.abs(target - now) > 1e-3
    if moving then
      local step = C.v.growSpeed * dt * math.max(1, now)   -- the same feel at any size
      if math.abs(target - now) <= step then now = target
      elseif target > now then now = now + step
      else now = now - step end
      f.scale = now
    end
    if moving or periodic then
      if not R.alive(f) then f.scale = 1.0
      else send(f, f.scale) end
    end
  end
end

-- Let everyone go at their real size (dismissed, mod unloaded).
function G.releaseAll()
  for _, f in ipairs(R.list) do
    if R.alive(f) then send(f, 1.0) end
  end
end

R.onDismiss = function(f) if R.alive(f) then send(f, 1.0) end end

return G
