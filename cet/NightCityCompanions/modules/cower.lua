-- Night City Companions -- followers keep out of fights: when combat starts they drop down where they are, hands over
-- their head, and stay put; a few seconds after it ends they get up and follow again.
--
-- Combat is read from the player's state machine blackboard (the same flag the game's HUD uses). There is no "cower"
-- status effect in the game (checked in game 2.5: only SpreadFear); the cower is the civilian fear-in-place reaction
-- (ReactionsActions.*FearInPlace*). The crouch stance was tried and has no visible effect.
local U = require('modules/util')
local C = require('modules/config')
local R = require('modules/roster')

local K = {}
K.inCombat = false

local calm = 0         -- seconds out of combat since it last ended

local function playerInCombat()
  local yes = false
  pcall(function()
    local player = Game.GetPlayer()
    local defs = GetAllBlackboardDefs().PlayerStateMachine
    local bb = Game.GetBlackboardSystem():GetLocalInstanced(player:GetEntityID(), defs)
    yes = bb:GetInt(defs.Combat) == 1   -- gamePSMCombat.InCombat
  end)
  return yes
end

local function hold(f)
  U.try('cower hold', function()
    local cmd = NewObject('handle:AIHoldPositionCommand')
    cmd.duration = 600
    f.entity:GetAIControllerComponent():SendCommand(cmd)
    f.holdCmd = cmd
  end)
end

local function release(f)
  if f.holdCmd then
    pcall(function() f.entity:GetAIControllerComponent():CancelCommand(f.holdCmd) end)
    f.holdCmd = nil
  end
end

-- Taking cover: they stay where they are when the fight starts, with their own (civilian) reactions back so the game's
-- fear can play. Their fear wants them to run, and AI commands are ignored while they panic, so they are pinned to the
-- spot with the teleportation facility (which works on anyone) whenever they move off it: with nowhere to run, the
-- game's fear-in-place reaction (dropping down, hands over the head) is what is left.
local function pos(f)
  local p
  pcall(function() p = f.entity:GetWorldPosition() end)
  return p
end

local function put(entity, at)
  pcall(function()
    local rot = EulerAngles.new(0, 0, entity:GetWorldYaw())
    Game.GetTeleportationFacility():Teleport(entity, at, rot)
  end)
end

local function cower(f)
  if f.cowering or not R.alive(f) or f.riding then return end
  f.cowering = true
  f.coverAt = pos(f)
  f.pinned = 0
  hold(f)
  if f.homePreset then f.panicking = R.setReactions(f.entity, f.homePreset) end
  U.trace('%s takes cover (%s)', f.name, f.panicking and 'their own fear, pinned in place' or 'holding still')
end

-- While the fight lasts: anyone who has moved off their spot is put back on it.
local function watch(f)
  if not f.cowering or not R.alive(f) or not f.coverAt then return end
  local p = pos(f)
  if p and U.dist(p, f.coverAt) > 0.6 then
    put(f.entity, f.coverAt)
    f.pinned = f.pinned + 1
    if f.pinned == 1 or f.pinned % 100 == 0 then U.trace('%s tried to run: pinned (%d)', f.name, f.pinned) end
  end
end

local function getUp(f)
  if not f.cowering then return end
  f.cowering = false
  if R.alive(f) then
    if f.panicking then R.setReactions(f.entity, nil) end
    release(f)
    -- back at your side, whatever their fear did
    pcall(R.teleportToPlayer, f)
  end
  U.trace('%s gets back up (pinned %d times)', f.name, f.pinned or 0)
  f.panicking, f.coverAt, f.pinned = false, nil, 0
end

function K.update(dt)
  if (C.v.inCombat or 'cower') ~= 'cower' then
    if K.inCombat then for _, f in ipairs(R.list) do getUp(f) end K.inCombat = false end
    return
  end
  local now = playerInCombat()
  if now then
    calm = 0
    if not K.inCombat then
      K.inCombat = true
      U.trace('combat started')
    end
    for _, f in ipairs(R.list) do cower(f) watch(f) end   -- also anyone who arrives mid-fight
  elseif K.inCombat then
    calm = calm + dt
    if calm > 3 then
      K.inCombat = false
      U.trace('combat over')
      for _, f in ipairs(R.list) do getUp(f) end
    end
  end
end

R.beforeDismiss = getUp

-- Anyone dismissed or lost while cowering is let go of.
function K.releaseAll()
  for _, f in ipairs(R.people) do if f.cowering then getUp(f) end end
end

return K
