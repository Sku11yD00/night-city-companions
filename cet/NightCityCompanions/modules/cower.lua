-- Night City Companions -- followers keep out of fights: when combat starts they drop down where they are, hands over
-- their head, and stay put; a few seconds after it ends they get up and follow again.
--
-- Combat is read from the player's state machine blackboard (the same flag the game's HUD uses). There is no "cower"
-- status effect in the game (checked in game 2.5: only SpreadFear); the cower is the civilian fear-in-place reaction
-- (ReactionsActions.*FearInPlace*), so for the fight a follower gets their own reactions back while held in place.
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

-- Crouched, the closest pose that can be set for sure: the stance the game's AI uses for cover.
local function setStance(entity, crouch)
  local ok, state = pcall(function()
    return crouch and gamedataNPCStanceState.Crouch or gamedataNPCStanceState.Stand
  end)
  if not ok then return false end
  if pcall(function() NPCPuppet.ChangeStanceState(entity, state) end) then return true end
  return pcall(function() entity:ChangeStanceState(state) end)
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

-- Taking cover: they stay where they are when the fight starts. With their own (civilian) reactions back for the
-- fight, the game's fear-in-place reaction can play: dropping down, hands over their head. If their fear makes them
-- run instead (more than a few metres from where they were), they are put back, given the follower reactions again
-- and only crouch, for the rest of the session.
local panicWorks = true

local function pos(f)
  local p
  pcall(function() p = f.entity:GetWorldPosition() end)
  return p
end

local function crouchOnly(f)
  f.panicking = false
  R.setReactions(f.entity, nil)
  hold(f)
  f.crouched = setStance(f.entity, true)
end

local function cower(f)
  if f.cowering or not R.alive(f) or f.riding then return end
  f.cowering = true
  f.coverAt = pos(f)
  if panicWorks and f.homePreset then
    f.panicking = R.setReactions(f.entity, f.homePreset)
    hold(f)
    pcall(function() f.entity:GetStimBroadcasterComponent():TriggerSingleBroadcast(f.entity, gamedataStimType.Terror) end)
    U.trace('%s takes cover with their own fear reactions', f.name)
  else
    crouchOnly(f)
    U.trace('%s takes cover (%s)', f.name, f.crouched and 'crouched' or 'holding still')
  end
end

-- While the fight lasts: someone whose fear makes them run is brought back and only crouches.
local function watch(f)
  if not f.cowering or not f.panicking or not R.alive(f) or not f.coverAt then return end
  local p = pos(f)
  if p and U.dist(p, f.coverAt) > 3 then
    panicWorks = false
    U.trace('%s ran in fear: back to where they were, crouching instead (for this session)', f.name)
    pcall(function()
      local cmd = AITeleportCommand.new()
      cmd.position = f.coverAt
      cmd.rotation = 0
      cmd.doNavTest = false
      f.entity:GetAIControllerComponent():SendCommand(cmd)
    end)
    crouchOnly(f)
  end
end

local function getUp(f)
  if not f.cowering then return end
  f.cowering = false
  if R.alive(f) then
    if f.panicking then R.setReactions(f.entity, nil) end
    if f.crouched then setStance(f.entity, false) end
    release(f)
  end
  f.panicking, f.crouched, f.coverAt = false, nil, nil
  U.trace('%s gets back up', f.name)
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
