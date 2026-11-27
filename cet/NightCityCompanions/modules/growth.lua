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
  local ok, yes = pcall(scaleNative, f.entity, scale, (C.v.scaleFrom or 6) + 10 * (C.v.scaleWhen or 2))
  -- one line each time the answer changes, so trace.log shows whether the plugin found the person
  local answer = ok and (yes and 'yes' or 'no') or ('error ' .. tostring(yes))
  if f.lastScaleAnswer ~= answer then
    f.lastScaleAnswer = answer
    U.trace('size %s: %.2f (mode %d), plugin answered %s', f.name, scale, C.v.scaleFrom or 6, answer)
  end
  return ok and yes
end

-- Which single bone the 'one part' test method resizes.
function G.setTestBone(name)
  local ok, f = pcall(U.native, 'CompanionScaleBone')
  if ok and f then
    local done, err = pcall(f, name)
    if done then G.testBone = name else U.trace('test bone %s: %s', name, tostring(err)) end
  else
    U.trace('test bone: the plugin has no CompanionScaleBone')
  end
end

-- A giant that moves at a person's pace looks weightless, so time runs slower for a bigger follower: by the square
-- root of the size, as a pendulum's swing goes. Set again only when the size has moved enough to see.
local function pace(scale)
  if not C.v.slowWithSize then return 1 end
  return U.clamp(1 / math.sqrt(math.max(scale, 0.05)), 0.12, 1.6)
end

local function setPace(f, scale)
  local want = pace(scale)
  -- said again every ten seconds: a follower called back is a new body that has not been told
  if f.pace and math.abs(f.pace - want) < 0.02 and os.clock() - (f.paceAt or 0) < 10 then return end
  f.paceAt = os.clock()
  local reason = CName.new('CompanionSize')
  local ok, err
  if math.abs(want - 1) < 0.02 then
    ok, err = pcall(function() f.entity:UnsetIndividualTimeDilation(CName.new('')) end)
  else
    ok, err = pcall(function()
      f.entity:SetIndividualTimeDilation(reason, want, 100000, CName.new(''), CName.new(''), false)
    end)
    if not ok then
      ok, err = pcall(function()
        TimeDilationHelper.SetIndividualTimeDilation(f.entity, reason, want, 100000, CName.new(''), CName.new(''))
      end)
    end
  end
  -- what the game says it took, written down whenever the answer or the pace has changed enough to matter
  if f.paceAnswer ~= ok or math.abs((f.paceLogged or 1) - want) >= 0.05 then
    f.paceAnswer = ok
    f.paceLogged = want
    local has, value = '?', '?'
    pcall(function() has = tostring(f.entity:HasIndividualTimeDilation(reason)) end)
    pcall(function() value = string.format('%.2f', f.entity:GetTimeDilationValue()) end)
    U.trace('pace %s: %.2f at size %.2f %s (the game says: has it %s, runs at %s)', f.name, want, scale,
      ok and 'set' or ('FAILED ' .. tostring(err)), has, value)
  end
  f.pace = want
end
G.setPace = setPace

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
    local target = U.clamp(f.targetScale or 1, C.v.minScale, C.v.maxScale)
    f.targetScale = target
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
      else
        send(f, f.scale)
        if periodic then setPace(f, f.scale) end
      end
    end
  end
end

-- Let everyone go at their real size (dismissed, mod unloaded).
function G.releaseAll()
  for _, f in ipairs(R.list) do
    if R.alive(f) then send(f, 1.0) end
  end
end

R.onDismiss = function(f) if R.alive(f) then send(f, 1.0) setPace(f, 1.0) end end

return G
