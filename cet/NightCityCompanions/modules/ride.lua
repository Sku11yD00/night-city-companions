-- Night City Companions -- climbing up a large follower and riding on them (shoulder, head, open palm).
--
-- The follower's collision does not grow with them (the CompanionScale plugin scales what is drawn, not the
-- capsule), so there is nothing physical to stand on. Riding holds the player at the mount point every frame, in the
-- follower's own frame, so the point walks and turns with them. The Climb key (or the window's button) plays an eased
-- climb from where you stand to the mount point, or jumps straight up with the comfort option.
-- While riding, "walk where I look" sends the follower a few of their own strides in the direction you face.
local U = require('modules/util')
local C = require('modules/config')
local R = require('modules/roster')

local Ride = {}
Ride.state = 'none'     -- none | climbing | mounted
Ride.follower = nil
Ride.mount = 1

local climb = { t = 0, from = nil }

local function teleport(pos)
  local player = Game.GetPlayer()
  if not player then return end
  local rot
  pcall(function() rot = player:GetWorldOrientation():ToEulerAngles() end)
  rot = rot or EulerAngles.new(0, 0, player:GetWorldYaw())
  Game.GetTeleportationFacility():Teleport(player, pos, rot)
end

local function mountPoint(f, index)
  local m = C.v.mounts[index] or C.v.mounts[1]
  return U.localToWorld(f.entity, m.offset, f.scale or 1)
end

local function bigEnough(f)
  return f and R.alive(f) and (f.scale or 1) >= C.v.rideMinScale - 1e-3
end
Ride.bigEnough = bigEnough

local function smooth(x)
  x = U.clamp(x, 0, 1)
  return x * x * (3 - 2 * x)
end

function Ride.start(f, index)
  f = f or R.current()
  if not bigEnough(f) then
    U.say('%s needs to be at least %.1fx tall to climb', f and f.name or 'A follower', C.v.rideMinScale)
    return
  end
  local player = Game.GetPlayer()
  if not player then return end
  Ride.follower, Ride.mount = f, index or Ride.mount
  f.riding = true
  if C.v.comfortFade or C.v.climbSeconds <= 0 then
    Ride.state = 'mounted'
  else
    climb.t = 0
    local p = player:GetWorldPosition()
    climb.from = { x = p.x, y = p.y, z = p.z }
    Ride.state = 'climbing'
  end
  U.say('climbing onto %s', f.name)
end

function Ride.dismount()
  local f = Ride.follower
  Ride.state, Ride.follower = 'none', nil
  if not f then return end
  f.riding = false
  if R.alive(f) then
    -- set down beside them, on their right, at their feet
    local p = U.localToWorld(f.entity, { 0.6, 0.2, 0.0 }, f.scale or 1)
    teleport(Vector4.new(p.x, p.y, f.entity:GetWorldPosition().z + 0.1, 1.0))
  end
end

function Ride.cycleMount()
  Ride.mount = Ride.mount % #C.v.mounts + 1
  U.say('mount: %s', C.v.mounts[Ride.mount].name)
end

-- The follower walks a few strides the way the player faces.
function Ride.walkWhereLooking()
  local f = Ride.follower or R.current()
  if not f or not R.alive(f) then return end
  U.try('walk', function()
    local fwd = Game.GetCameraSystem():GetActiveCameraForward()
    local l = math.sqrt(fwd.x * fwd.x + fwd.y * fwd.y)
    if l < 1e-3 then return end
    local p = f.entity:GetWorldPosition()
    local d = C.v.walkDistance * (f.scale or 1)
    local to = Vector4.new(p.x + fwd.x / l * d, p.y + fwd.y / l * d, p.z, 1.0)
    -- the shape AMM uses for its "move to" command
    local dest = NewObject('WorldPosition')
    dest:SetVector4(dest, to)
    local spec = NewObject('AIPositionSpec')
    spec:SetWorldPosition(spec, dest)
    local cmd = NewObject('handle:AIMoveToCommand')
    cmd.movementTarget = spec
    cmd.rotateEntityTowardsFacingTarget = false
    cmd.ignoreNavigation = true
    cmd.desiredDistanceFromTarget = 0.5
    cmd.movementType = 'Walk'
    cmd.finishWhenDestinationReached = true
    f.entity:GetAIControllerComponent():SendCommand(cmd)
  end)
end

function Ride.update(dt)
  if Ride.state == 'none' then return end
  local f = Ride.follower
  if not f or not R.alive(f) then
    Ride.state, Ride.follower = 'none', nil
    return
  end
  if Ride.state == 'climbing' then
    climb.t = climb.t + dt
    local k = smooth(climb.t / math.max(0.05, C.v.climbSeconds))
    local to = mountPoint(f, Ride.mount)
    -- up first, then over: the height leads the horizontal movement
    local kz = smooth(math.min(1, k * 1.5))
    local x = climb.from.x + (to.x - climb.from.x) * k
    local y = climb.from.y + (to.y - climb.from.y) * k
    local z = climb.from.z + (to.z - climb.from.z) * kz
    teleport(Vector4.new(x, y, z, 1.0))
    if k >= 1 then Ride.state = 'mounted' end
  elseif Ride.state == 'mounted' then
    teleport(mountPoint(f, Ride.mount))
  end
end

return Ride
