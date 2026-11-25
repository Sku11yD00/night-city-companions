-- Night City Companions -- the people: anyone you look at made a follower, the contacts you save, and calling a contact to
-- your side.
--
-- Everyone the mod knows is one entry in roster.json, kept across saves and game sessions:
--   active  -- following you now (R.list, in the order they joined)
--   saved   -- in your neurointerface contacts (R.contacts), so they can be called again any time
-- An entry keeps who they are (record and appearance), their size, their persona and the conversation, so a contact
-- called back looks, stands and remembers as they did.
--
-- A follower is made the way the game makes its own companions: an AIFollowerRole that follows the player, the
-- "player" attitude group so they fight on your side, and the companion flag the combat and reaction systems read.
--
-- STREET PEOPLE. Crowd and background pedestrians are driven by the crowd system, not a full AI, and do not take a
-- role. They are recruited as a copy: the same record and appearance spawned where they stand (Codeware's
-- DynamicEntitySystem, which makes a full person), the original taken away, and the copy made a follower. Settings can
-- make every recruit a copy, or none.
local U = require('modules/util')
local C = require('modules/config')

local R = {}
local PATH = 'roster.json'
local TAG = 'NightCityCompanions'

R.people = {}      -- every entry
R.list = {}        -- active ones (following now)
R.contacts = {}    -- saved ones
R.selected = 1

-- SPAWNING, through Codeware's DynamicEntitySystem. Looked up when used: the game systems are not there while the
-- mod's files load.
local function spawner()
  local s
  pcall(function() s = Game.GetDynamicEntitySystem() end)
  return s
end
local function canSpawn() return spawner() ~= nil end
R.canSpawn = canSpawn

local function spawnRecord(record, appearance, pos, orientation, tags)
  local spec = DynamicEntitySpec.new()
  spec.recordID = record
  spec.appearanceName = appearance
  spec.position = pos
  spec.orientation = orientation
  spec.persistState = false
  spec.persistSpawn = false
  spec.tags = tags
  return spawner():CreateEntity(spec)
end

local function spawnedEntity(id)
  local e
  pcall(function() e = spawner():GetEntity(id) end)
  if not e then pcall(function() e = Game.FindEntityByID(id) end) end
  return e
end

local function spawnDelete(id)
  return spawner():DeleteEntity(id)
end

local function defaultPersona(name)
  return string.format(
    'You are %s, a resident of Night City who has just started travelling with V as a companion. '
    .. 'Speak in your own voice, briefly, as someone living in Night City in 2077 would.', name)
end

local function rebuild()
  local current = R.list[R.selected]
  R.list, R.contacts = {}, {}
  for _, p in ipairs(R.people) do
    if p.active then table.insert(R.list, p) end
    if p.saved then table.insert(R.contacts, p) end
  end
  R.selected = 1
  for i, p in ipairs(R.list) do if p == current then R.selected = i end end
end
R.rebuild = rebuild

local FIELDS = { 'uid', 'name', 'record', 'recordHash', 'recordLength', 'appearance', 'persona', 'history',
  'targetScale', 'active', 'saved', 'copy' }

function R.save()
  local out = {}
  for _, p in ipairs(R.people) do
    local o = {}
    for _, k in ipairs(FIELDS) do o[k] = p[k] end
    table.insert(out, o)
  end
  U.writeJson(PATH, out)
end

function R.load()
  local saved = U.readJson(PATH)
  R.people = {}
  if type(saved) == 'table' then
    for i, s in ipairs(saved) do
      s.uid = s.uid or ('p' .. i .. '_' .. os.time())
      s.history = s.history or {}
      s.targetScale = s.targetScale or 1.0
      -- rosters from the first version had no flags: everyone on them was following
      if s.active == nil and s.saved == nil then s.active = true end
      s.scale, s.entity, s.lost = 1.0, nil, true
      table.insert(R.people, s)
    end
  end
  rebuild()
end

function R.current()
  return R.list[R.selected]
end

local function newUid()
  return string.format('p%d_%d', os.time(), math.random(100000, 999999))
end

local function alive(f)
  if not f or not f.entity then return false end
  local ok, yes = pcall(function()
    return f.entity:IsAttached() and not f.entity:IsDead()
  end)
  return ok and yes
end
R.alive = alive

local function findByEntity(entity)
  local key = U.idKey(entity)
  for _, p in ipairs(R.people) do
    if p.entity == entity or (key and (p.key == key or p.originalKey == key)) then return p end
  end
  return nil
end

-- The record as the spawner wants it. A crowd person's record often has no name in the string table, so its hash and
-- length are kept too.
local function recordId(p)
  if p.record and p.record ~= '' and p.record:sub(1, 1) ~= '<' then
    local ok, id = pcall(TweakDBID.new, p.record)
    if ok and id then return id end
  end
  if p.recordHash then
    local ok, id = pcall(ToTweakDBID, { hash = p.recordHash, length = p.recordLength or 0 })
    if ok and id then return id end
  end
  return nil
end

local function describe(entity)
  local d = { name = U.nameOf(entity), record = U.recordOf(entity), appearance = U.appearanceOf(entity) }
  pcall(function()
    local id = entity:GetRecordID()
    d.recordHash, d.recordLength = id.hash, id.length
  end)
  return d
end

-- The game's companion setup, on one person.
local function makeFollower(entity)
  local player = Game.GetPlayer()
  if not player then return false end
  local group
  pcall(function() group = Game.NameToString(entity:GetAttitudeAgent():GetAttitudeGroup()) end)
  local ok = U.try('make follower', function()
    local aic = entity:GetAIControllerComponent()
    local role = AIFollowerRole.new()
    role:SetFollowTarget(player)
    pcall(function() role:OnRoleSet(entity) end)
    role.followerRef = Game.CreateEntityReference('#player', {})
    role.attitudeGroupName = CName.new('player')
    local agent = entity:GetAttitudeAgent()
    agent:SetAttitudeGroup(CName.new('player'))
    pcall(function() agent:SetAttitudeTowards(player:GetAttitudeAgent(), EAIAttitude.AIA_Friendly) end)
    aic:SetAIRole(role)
    pcall(function() entity.isPlayerCompanionCached = true end)
    pcall(function() entity.isPlayerCompanionCachedTimeStamp = 0 end)
    pcall(function() entity.movePolicies:Toggle(true) end)
  end)
  if ok and C.v.invulnerable then
    U.try('invulnerable', function()
      Game.GetGodModeSystem():AddGodMode(entity:GetEntityID(), gameGodModeType.Invulnerable, CName.new(TAG))
    end)
  end
  return ok, group
end

-- Let a person go where they stand: no role, back in the attitude group they had before recruiting.
local function releaseEntity(entity, group)
  U.trace('dismiss: releasing the follower role')
  U.try('dismiss', function()
    entity:GetAIControllerComponent():SetAIRole(AINoRole.new())
    pcall(function() entity.isPlayerCompanionCached = false end)
    if group and group ~= '' and group ~= 'player' then
      pcall(function() entity:GetAttitudeAgent():SetAttitudeGroup(CName.new(group)) end)
    end
    pcall(function()
      Game.GetGodModeSystem():RemoveGodMode(entity:GetEntityID(), gameGodModeType.Invulnerable, CName.new(TAG))
    end)
  end)
  U.trace('dismiss: released')
end

-- Take a person out of the world (the original of a copy; a called contact going home).
local function removeEntity(entity, spawnId)
  if spawnId and canSpawn() then
    U.trace('removing a spawned person')
    local ok, done = pcall(spawnDelete, spawnId)
    U.trace('removed: %s', tostring(ok and done))
    if ok and done then return end
  end
  U.trace('disposing a person')
  if pcall(function() entity:Dispose() end) then return end
  pcall(function() entity:GetEntity():Destroy() end)
end

-- People going home are deleted a moment after the mod has let go of them, never in the frame that changed them.
local leaving = {}
local function removeLater(entity, spawnId)
  table.insert(leaving, { entity = entity, spawnId = spawnId, t = 0 })
end

-- Who the player is looking at, if it is a living person.
function R.lookAt()
  local player = Game.GetPlayer()
  if not player then return nil end
  local target
  pcall(function() target = Game.GetTargetingSystem():GetLookAtObject(player, false, false) end)
  if not target then return nil end
  local isPerson = false
  pcall(function() isPerson = target:IsNPC() and not target:IsDead() end)
  if not isPerson then
    -- some background people are puppets that do not answer IsNPC
    pcall(function() isPerson = target:IsA(CName.new('ScriptedPuppet')) and not target:IsDead() end)
  end
  if not isPerson then return nil end
  return target
end

local function isCrowd(entity)
  local crowd = false
  pcall(function() crowd = entity:IsCrowd() end)
  if not crowd then pcall(function() crowd = entity:IsCharacterCivilian() and entity:GetAIControllerComponent() == nil end) end
  return crowd
end

local function shouldCopy(entity)
  local mode = C.v.recruitCopies or 'crowd'
  if not canSpawn() then return false end
  if mode == 'always' then return true end
  if mode == 'never' then return false end
  return isCrowd(entity)
end

-- Ask for a person to be spawned at a place; they are attached on a later update (pollSpawn).
local function spawnAt(p, pos, yaw)
  local id = recordId(p)
  if not canSpawn() or not id then
    U.say('cannot bring %s: %s', p.name, id and 'Codeware is not installed' or 'their record is unknown')
    return false
  end
  local ok = U.try('spawn ' .. p.name, function()
    p.spawnId = spawnRecord(id, CName.new(p.appearance or ''), pos, EulerAngles.new(0, 0, yaw):ToQuat(),
      { CName.new(TAG) })
  end)
  U.trace('spawn %s: record %s, appearance %s, asked %s, id %s', p.name, tostring(p.record), tostring(p.appearance),
    tostring(ok), p.spawnId and 'yes' or 'none')
  if ok and not p.spawnId then
    p.spawnTrouble = 'the spawner refused'
    return false
  end
  if ok then p.spawnAsked = os.clock() end
  return ok
end

local function attach(p, entity)
  U.trace('%s arrived', p.name)
  p.spawnTries, p.spawnTrouble = 0, nil
  p.entity, p.key, p.lost = entity, U.idKey(entity), false
  p.scale = p.targetScale or 1.0   -- arrive at their saved size, not growing into it
  makeFollower(entity)
  if p.onArrive then pcall(p.onArrive, p) p.onArrive = nil end
end

local function pollSpawn(p)
  if not p.spawnId then return false end
  local e
  pcall(function() e = spawnedEntity(p.spawnId) end)
  if e then
    local ready = false
    pcall(function() ready = e:IsAttached() end)
    if ready then
      attach(p, e)
      p.ownSpawn = p.spawnId
      p.spawnId, p.spawnAsked = nil, nil
      return true
    end
  end
  if e and os.clock() - (p.spawnAsked or 0) <= 30 then return false end   -- made, still being set up: wait
  if os.clock() - (p.spawnAsked or 0) > 10 then   -- never came: take the request back and ask again
    p.spawnTrouble = e and 'spawned but never attached to the world' or 'the spawner never made them'
    U.trace('spawn %s: %s', p.name, p.spawnTrouble)
    pcall(spawnDelete, p.spawnId)
    p.spawnId = nil
    p.spawnTries = (p.spawnTries or 0) + 1
  end
  return false
end

function R.recruit(entity)
  entity = entity or R.lookAt()
  if not entity then U.say('look at a person to recruit them') return nil end
  local existing = findByEntity(entity)
  if existing and existing.active and existing.spawnId then
    U.say('%s is already on the way', existing.name)
    return existing
  end
  if existing and existing.active then
    for i, p in ipairs(R.list) do if p == existing then R.selected = i end end
    U.say('%s already follows you', existing.name)
    return existing
  end
  if #R.list >= C.v.maxFollowers then U.say('you already have %d followers', #R.list) return nil end
  local d = describe(entity)
  local p = existing or {
    uid = newUid(), name = d.name, record = d.record, recordHash = d.recordHash, recordLength = d.recordLength,
    appearance = d.appearance, persona = defaultPersona(d.name), history = {}, targetScale = 1.0,
    saved = C.v.autoSaveContacts,
  }
  p.active, p.scale, p.lost = true, 1.0, false
  if shouldCopy(entity) then
    local pos = entity:GetWorldPosition()
    local yaw = 0
    pcall(function() yaw = entity:GetWorldYaw() end)
    if not spawnAt(p, pos, yaw) then return nil end
    p.copy = true
    p.originalKey = U.idKey(entity)
    removeEntity(entity)
    U.say('%s (a street person) is joining you', p.name)
  else
    local ok, group = makeFollower(entity)
    if not ok then return nil end
    p.entity, p.key = entity, U.idKey(entity)
    if group and group ~= 'player' then p.homeGroup = group end
    U.say('%s is following you', p.name)
  end
  if not existing then table.insert(R.people, p) end
  rebuild()
  R.selected = #R.list
  R.save()
  return p
end

-- Stop following. A saved contact goes home (despawned when the mod spawned them); anyone else is let go where they
-- stand and forgotten.
function R.dismiss(p)
  p = p or R.current()
  if not p then return end
  if R.onDismiss then pcall(R.onDismiss, p) end
  U.trace('dismiss %s (contact %s, spawned by the mod %s)', p.name, tostring(p.saved), tostring(p.ownSpawn ~= nil))
  if alive(p) then
    -- Always undo the companion setup (role, god mode), so nothing in the game (or a save made later) still points at
    -- them. Someone going home is deleted only a few seconds after that: undoing and deleting in one frame crashes.
    releaseEntity(p.entity, p.homeGroup)
    -- anyone the mod spawned is taken out again, contact or not: a spawned person left behind is nobody's to clean up
    if p.ownSpawn then removeLater(p.entity, p.ownSpawn) end
  end
  p.active, p.entity, p.ownSpawn, p.spawnId = false, nil, nil, nil
  if not p.saved then
    for i, q in ipairs(R.people) do if q == p then table.remove(R.people, i) break end end
  end
  rebuild()
  R.save()
  U.say(p.saved and '%s heads home (still in your contacts)' or '%s goes their own way', p.name)
end

function R.setSaved(p, yes)
  if not p then return end
  p.saved = yes and true or false
  if not p.saved and not p.active then
    for i, q in ipairs(R.people) do if q == p then table.remove(R.people, i) break end end
  end
  rebuild()
  R.save()
end

function R.forget(p)
  if not p then return end
  if p.active then
    p.saved = false
    R.dismiss(p)
  else
    R.setSaved(p, false)
  end
end

local function nearPlayer(distance, side)
  local player = Game.GetPlayer()
  local p = player:GetWorldPosition()
  local fwd = player:GetWorldForward()
  local rx, ry = fwd.y, -fwd.x
  local s = side or 0
  return Vector4.new(p.x - fwd.x * distance + rx * s, p.y - fwd.y * distance + ry * s, p.z, 1.0), player:GetWorldYaw()
end

-- Stop trying to bring someone who will not come: they stay in contacts, no longer with you.
function R.giveUp(p)
  if p.spawnId then pcall(spawnDelete, p.spawnId) end
  p.active, p.spawnId, p.spawnTries, p.onArrive, p.lost = false, nil, 0, nil, true
  if not p.saved then
    for i, q in ipairs(R.people) do if q == p then table.remove(R.people, i) break end end
  end
  rebuild()
  R.save()
end

-- Call a saved contact to the player's side. onArrive runs once they are there.
function R.summon(p, onArrive)
  if not p then return false end
  if p.active and alive(p) then
    R.teleportToPlayer(p)
    if onArrive then pcall(onArrive, p) end
    return true
  end
  if #R.list >= C.v.maxFollowers and not p.active then
    U.say('you already have %d followers', #R.list)
    return false
  end
  local at, yaw = nearPlayer(2.0 + (p.targetScale or 1), 1.0)
  if not spawnAt(p, at, yaw + 180) then return false end
  p.active, p.lost, p.onArrive = true, true, onArrive
  rebuild()
  R.save()
  return true
end

function R.teleportToPlayer(f)
  f = f or R.current()
  if not f or not alive(f) then return end
  U.try('bring follower', function()
    local at, yaw = nearPlayer(1.5 + (f.scale or 1))
    local cmd = AITeleportCommand.new()
    cmd.position = at
    cmd.rotation = yaw
    cmd.doNavTest = false
    f.entity:GetAIControllerComponent():SendCommand(cmd)
  end)
end

-- Twice a second: keep handles fresh, attach people who were spawned, bring stragglers along.
local tick = 0
function R.update(dt)
  for i = #leaving, 1, -1 do
    local l = leaving[i]
    l.t = l.t + dt
    if l.t > 3 then
      table.remove(leaving, i)
      removeEntity(l.entity, l.spawnId)
    end
  end
  tick = tick + dt
  if tick < 0.5 then return end
  tick = 0
  local player = Game.GetPlayer()
  if not player then return end
  local pp = player:GetWorldPosition()
  for _, f in ipairs(R.list) do
    if f.spawnId then
      pollSpawn(f)
    elseif alive(f) then
      f.lost = false
      if not f.riding and U.dist(f.entity:GetWorldPosition(), pp) > C.v.teleportBeyond then
        R.teleportToPlayer(f)
      end
    else
      f.lost = true
      -- The person the mod spawned may only be out of reach for a moment (streaming, a cutscene). Never make a
      -- second one while the first still exists: wait for them, and only once they are gone spawn a new one.
      local own = f.ownSpawn and spawnedEntity(f.ownSpawn)
      if own then
        f.lostFor = (f.lostFor or 0) + 0.5
        local back = false
        pcall(function() back = own:IsAttached() and not own:IsDead() end)
        if back then
          f.entity, f.lostFor = own, 0
        elseif f.lostFor > 20 then
          U.trace('%s stayed out of reach: replacing them', f.name)
          pcall(spawnDelete, f.ownSpawn)
          f.ownSpawn, f.entity, f.lostFor = nil, nil, 0
        end
      else
        f.entity, f.ownSpawn = nil, nil
      end
      if f.entity or f.ownSpawn then
        -- waiting for the one that exists
      elseif (f.spawnTries or 0) >= 3 then
        U.say('%s could not be brought back (%s)', f.name, f.spawnTrouble or 'no reason known')
        R.giveUp(f)
        break
      elseif C.v.respawnLost and canSpawn() and recordId(f) then
        local at, yaw = nearPlayer(2.0)
        spawnAt(f, at, yaw)
      end
    end
  end
end

-- After a load every handle is stale.
function R.forgetHandles()
  leaving = {}
  for _, p in ipairs(R.people) do
    p.entity, p.lost, p.scale, p.spawnId, p.ownSpawn = nil, true, 1.0, nil, nil
  end
end

R.load()
return R
