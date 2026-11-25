-- Night City Companions -- followers keep out of fights: when combat starts they drop down where they are, hands over
-- their head, and stay put; a few seconds after it ends they get up and follow again.
--
-- Combat is read from the player's state machine blackboard (the same flag the game's HUD uses). Cowering is the
-- game's own fear reaction, applied as a status effect; which status effect record that is has not been confirmed in
-- the game yet, so the first candidate that exists in TweakDB is used, and the first combat writes every fear-like
-- status effect the game has to trace.log so the right one can be picked.
local U = require('modules/util')
local C = require('modules/config')
local R = require('modules/roster')

local K = {}
K.inCombat = false

local CANDIDATES = {
  'BaseStatusEffect.Cower', 'BaseStatusEffect.Cowering', 'BaseStatusEffect.Terrified', 'BaseStatusEffect.Fear',
  'BaseStatusEffect.Panic', 'BaseStatusEffect.Scared',
}
local effect           -- the TweakDBID in use, found on first combat
local looked, listed = false, false
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

local function exists(name)
  local ok, rec = pcall(function() return TweakDB:GetRecord(name) end)
  return ok and rec ~= nil
end

-- Every status effect whose name sounds like fear, written once to trace.log.
local function listFearEffects()
  if listed then return end
  listed = true
  pcall(function()
    local found = 0
    for _, rec in ipairs(TweakDB:GetRecords('gamedataStatusEffect_Record') or {}) do
      local name = TDBID.ToStringDEBUG(rec:GetID())
      local low = name:lower()
      if low:find('cower') or low:find('fear') or low:find('panic') or low:find('terrif') or low:find('scare')
        or low:find('crouch') or low:find('surrender') then
        U.trace('status effect: %s', name)
        found = found + 1
        if found >= 60 then break end
      end
    end
    U.trace('status effects listed: %d', found)
  end)
end

local function findEffect()
  if looked then return effect end
  looked = true
  for _, name in ipairs(CANDIDATES) do
    if exists(name) then
      effect = TweakDBID.new(name)
      U.trace('cower: using %s', name)
      return effect
    end
  end
  U.trace('cower: none of the candidate status effects exist; followers will only hold still')
  return nil
end

local function apply(entity, id)
  if pcall(function() StatusEffectHelper.ApplyStatusEffect(entity, id) end) then return true end
  return pcall(function()
    Game.GetStatusEffectSystem():ApplyStatusEffect(entity:GetEntityID(), id, entity:GetRecordID(), entity:GetEntityID())
  end)
end

local function remove(entity, id)
  if pcall(function() StatusEffectHelper.RemoveStatusEffect(entity, id) end) then return end
  pcall(function() Game.GetStatusEffectSystem():RemoveStatusEffect(entity:GetEntityID(), id) end)
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

local function cower(f)
  if f.cowering or not R.alive(f) or f.riding then return end
  f.cowering = true
  hold(f)
  local id = findEffect()
  if id then f.cowerApplied = apply(f.entity, id) and id or nil end
  U.trace('%s takes cover (%s)', f.name, f.cowerApplied and 'cowering' or 'holding still')
end

local function getUp(f)
  if not f.cowering then return end
  f.cowering = false
  if R.alive(f) then
    if f.cowerApplied then remove(f.entity, f.cowerApplied) end
    release(f)
  end
  f.cowerApplied = nil
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
      listFearEffects()
    end
    for _, f in ipairs(R.list) do cower(f) end   -- also anyone who arrives mid-fight
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
