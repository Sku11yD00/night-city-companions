-- Night City Companions -- a big follower's body is solid to the player.
--
-- The game's own collision for a person is a capsule the size of a person and does not grow with them, so a giant
-- could be walked straight through. Here the body is rebuilt from its bones: the CompanionScale plugin says where
-- each bone is, a rounded tube is laid between neighbouring bones (thigh, shin, foot, trunk, arms), and a player who
-- overlaps one is moved sideways out of it. It is a push, not physics: nothing can be stood on (riding does that),
-- and a push does not look at walls, so it is small each frame.
local U = require('modules/util')
local C = require('modules/config')
local R = require('modules/roster')

local S = {}
S.lastPush = 0

-- from bone, to bone, thickness (half width in metres on a person of normal size)
local tubes = {
  { 'LeftUpLeg', 'LeftLeg', 0.095 }, { 'LeftLeg', 'LeftFoot', 0.07 }, { 'LeftFoot', 'LeftToeBase', 0.065 },
  { 'RightUpLeg', 'RightLeg', 0.095 }, { 'RightLeg', 'RightFoot', 0.07 }, { 'RightFoot', 'RightToeBase', 0.065 },
  { 'Hips', 'Spine3', 0.17 }, { 'Spine3', 'Head', 0.13 }, { 'Head', 'HeadTip', 0.12 },
  { 'LeftArm', 'LeftForeArm', 0.055 }, { 'LeftForeArm', 'LeftHand', 0.05 },
  { 'RightArm', 'RightForeArm', 0.055 }, { 'RightForeArm', 'RightHand', 0.05 },
}
local playerHalfWidth, playerLow, playerHigh = 0.32, 0.25, 1.55

local boneNative
local nextLook = 0
local function lookUp()
  if boneNative then return boneNative end
  if os.clock() < nextLook then return nil end
  nextLook = os.clock() + 5
  local ok, f = pcall(U.native, 'CompanionBone')
  boneNative = ok and f or nil
  if boneNative then U.trace('solid body: the plugin can say where bones are') end
  return boneNative
end

-- The closest points of two segments (p1-q1, p2-q2); returns the point on each.
local function closest(p1, q1, p2, q2)
  local d1x, d1y, d1z = q1[1] - p1[1], q1[2] - p1[2], q1[3] - p1[3]
  local d2x, d2y, d2z = q2[1] - p2[1], q2[2] - p2[2], q2[3] - p2[3]
  local rx, ry, rz = p1[1] - p2[1], p1[2] - p2[2], p1[3] - p2[3]
  local a = d1x * d1x + d1y * d1y + d1z * d1z
  local e = d2x * d2x + d2y * d2y + d2z * d2z
  local f = d2x * rx + d2y * ry + d2z * rz
  local s, t
  if a <= 1e-9 and e <= 1e-9 then s, t = 0, 0
  elseif a <= 1e-9 then s, t = 0, U.clamp(f / e, 0, 1)
  else
    local c = d1x * rx + d1y * ry + d1z * rz
    if e <= 1e-9 then t, s = 0, U.clamp(-c / a, 0, 1)
    else
      local b = d1x * d2x + d1y * d2y + d1z * d2z
      local denom = a * e - b * b
      s = denom > 1e-9 and U.clamp((b * f - c * e) / denom, 0, 1) or 0
      t = (b * s + f) / e
      if t < 0 then t, s = 0, U.clamp(-c / a, 0, 1)
      elseif t > 1 then t, s = 1, U.clamp((b - c) / a, 0, 1) end
    end
  end
  return { p1[1] + d1x * s, p1[2] + d1y * s, p1[3] + d1z * s }, { p2[1] + d2x * t, p2[2] + d2y * t, p2[3] + d2z * t }
end
S.closest = closest

-- Where one bone is in the world at the follower's size, as { x, y, z }, or nil when the plugin cannot say.
function S.boneWorld(f, name)
  if not lookUp() or not f or not f.entity then return nil end
  local ok, v = pcall(boneNative, f.entity, name)
  if not (ok and v and v.w and v.w > 0.5) then return nil end
  local w = U.localToWorld(f.entity, { v.x, v.y, v.z }, f.scale or 1)
  return { w.x, w.y, w.z }
end

-- Every bone the tubes need, in the world, or nil for one the plugin does not know (yet).
local function bones(f)
  local out, found = {}, 0
  for _, tube in ipairs(tubes) do
    for k = 1, 2 do
      local name = tube[k]
      if out[name] == nil then
        out[name] = false
        local ok, v = pcall(boneNative, f.entity, name)
        if ok and v and v.w and v.w > 0.5 then
          local w = U.localToWorld(f.entity, { v.x, v.y, v.z }, f.scale or 1)
          out[name] = { w.x, w.y, w.z }
          found = found + 1
        end
      end
    end
  end
  return out, found
end

function S.update(dt, riding)
  if not C.v.solidBody or riding then return end
  local player = Game.GetPlayer()
  if not player then return end
  local list
  for _, f in ipairs(R.list) do
    if R.alive(f) and (f.scale or 1) >= (C.v.solidMinScale or 1.5) then
      list = list or {}
      list[#list + 1] = f
    end
  end
  if not list or not lookUp() then return end
  local inCar = false
  pcall(function() inCar = Game.GetMountedVehicle(player) ~= nil end)
  if inCar then return end
  local pos = player:GetWorldPosition()
  local low, high = { pos.x, pos.y, pos.z + playerLow }, { pos.x, pos.y, pos.z + playerHigh }
  local pushX, pushY, deepest, by = 0, 0, 0, nil
  for _, f in ipairs(list) do
    local at, found = bones(f)
    if f.solidFound ~= found then
      f.solidFound = found
      U.trace('solid body %s: %d bones placed at size %.2f', f.name, found, f.scale or 1)
    end
    local centre = f.entity:GetWorldPosition()
    for _, tube in ipairs(tubes) do
      local a, b = at[tube[1]], at[tube[2]]
      if a and b then
        local reach = tube[3] * (f.scale or 1) + playerHalfWidth
        local onBody, onPlayer = closest(a, b, low, high)
        local dx, dy, dz = onPlayer[1] - onBody[1], onPlayer[2] - onBody[2], onPlayer[3] - onBody[3]
        local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
        if dist < reach and reach - dist > deepest then
          -- out sideways; from straight above or below, away from where the follower stands
          local hl = math.sqrt(dx * dx + dy * dy)
          if hl < 0.05 then
            dx, dy = pos.x - centre.x, pos.y - centre.y
            hl = math.sqrt(dx * dx + dy * dy)
            if hl < 0.05 then dx, dy, hl = 1, 0, 1 end
          end
          deepest = reach - dist
          pushX, pushY, by = dx / hl, dy / hl, f
        end
      end
    end
  end
  if not by then return end
  local step = math.min(deepest, (C.v.solidPushSpeed or 12) * math.max(dt, 0.001))
  local rot
  pcall(function() rot = player:GetWorldOrientation():ToEulerAngles() end)
  rot = rot or EulerAngles.new(0, 0, player:GetWorldYaw())
  Game.GetTeleportationFacility():Teleport(player, Vector4.new(pos.x + pushX * step, pos.y + pushY * step, pos.z, 1.0), rot)
  if os.clock() - S.lastPush > 5 then
    U.trace('solid body %s: pushed the player out by %.2f m (overlap %.2f m)', by.name, step, deepest)
  end
  S.lastPush = os.clock()
end

return S
