-- Night City Companions -- talking with a follower through an AI model.
--
-- Lua inside the game cannot reach the internet, so the conversation goes through files to a small program running
-- beside the game (companion_bridge/bridge.py in this mod). A message is written to bridge/requests/<id>.json with who the
-- follower is, their persona, what is going on around them and the recent conversation; the bridge asks the model
-- and writes bridge/responses/<id>.json, which is picked up here. bridge/state.json tells the bridge whether to listen
-- to the microphone (voice input) and whether to read replies aloud.
--
-- The bridge writes bridge/heartbeat.json every couple of seconds; the window shows whether it is running.
local U = require('modules/util')
local C = require('modules/config')
local R = require('modules/roster')

local Chat = {}
local DIR = 'bridge/'
Chat.pending = {}         -- id -> follower
Chat.subtitle = nil       -- { who, text, until }
Chat.listening = false
Chat.bridgeAlive = false
Chat.draft = ''

local seq = 0
local function newId()
  seq = seq + 1
  return string.format('%d_%d', math.floor(os.time()), seq)
end

local function gameHour()
  local h
  pcall(function() h = Game.GetTimeSystem():GetGameTime():Hours() end)
  return h
end

local function situation(f)
  local parts = {}
  local h = gameHour()
  if h then table.insert(parts, string.format('It is about %02d:00 in Night City.', h)) end
  local s = f.scale or 1
  if s > 1.15 then
    table.insert(parts, string.format('You have grown to about %.1f times normal human height.', s))
  elseif s < 0.85 then
    table.insert(parts, string.format('You have shrunk to about %.1f times normal human height.', s))
  end
  if not R.alive(f) then
    table.insert(parts, 'You are not with V right now: V is talking with you over a holo-call through their neurointerface.')
  end
  if f.riding then
    table.insert(parts, 'V is riding on you, up on your shoulder.')
  end
  pcall(function()
    local player = Game.GetPlayer()
    if player:IsInCombat() then table.insert(parts, 'You and V are in a fight right now.') end
  end)
  return table.concat(parts, ' ')
end

local function push(f, role, text)
  table.insert(f.history, { role = role, text = text })
  local keep = math.max(2, C.v.historyTurns * 2)
  while #f.history > keep do table.remove(f.history, 1) end
end

-- opts.hidden: sent to the model but not shown as something V said (a call's greeting prompt).
function Chat.send(text, f, opts)
  f = f or R.current()
  if not f or not text or text:match('^%s*$') then return end
  local hidden = opts and opts.hidden
  if not hidden then push(f, 'user', text) end
  local id = newId()
  local history = {}
  for i = 1, #f.history - (hidden and 0 or 1) do history[i] = f.history[i] end
  local ok = U.writeJson(DIR .. 'requests/' .. id .. '.json', {
    id = id,
    follower = { name = f.name, record = f.record, appearance = f.appearance, persona = f.persona },
    situation = situation(f),
    history = history,
    message = text,
    speak = C.v.speakReplies,
  })
  if ok then
    Chat.pending[id] = f
    f.waiting = true
  else
    push(f, 'system', '(could not write the message for the bridge)')
  end
  R.save()
end

-- Voice: the bridge listens while this is on and sends what it hears as a message for the selected follower.
function Chat.setListening(on)
  Chat.listening = on
  local f = R.current()
  U.writeJson(DIR .. 'state.json', {
    listening = on and f ~= nil,
    follower = f and f.name or nil,
    speak = C.v.speakReplies,
  })
end

local poll = 0
function Chat.update(dt)
  poll = poll + dt
  if poll < 0.25 then return end
  poll = 0
  for id, f in pairs(Chat.pending) do
    local path = DIR .. 'responses/' .. id .. '.json'
    local r = U.readJson(path)
    if r then
      Chat.pending[id] = nil
      f.waiting = false
      U.remove(path)
      if r.heard and r.heard ~= '' then
        -- a voice message: what the player said comes back with the reply
        push(f, 'user', r.heard)
      end
      if r.error then
        push(f, 'system', '(' .. tostring(r.error) .. ')')
      elseif r.reply then
        push(f, 'assistant', r.reply)
        Chat.subtitle = { who = f.name, text = r.reply, untilT = os.clock() + C.v.subtitleSeconds }
      end
      R.save()
      pcall(Chat.publishContext)
    end
  end
  -- a voice message the bridge started on its own (it heard the player): bridge/responses/voice.json. The bridge
  -- writes the next one only once this one is gone.
  do
    local path = DIR .. 'responses/voice.json'
    local r = U.readJson(path)
    if r then
      U.remove(path)
      local f = R.current()
      if f then
        if r.heard then push(f, 'user', r.heard) end
        if r.reply then
          push(f, 'assistant', r.reply)
          Chat.subtitle = { who = f.name, text = r.reply, untilT = os.clock() + C.v.subtitleSeconds }
        elseif r.error then
          push(f, 'system', '(' .. tostring(r.error) .. ')')
        end
        R.save()
      pcall(Chat.publishContext)
      end
    end
  end
  local hb = U.readJson(DIR .. 'heartbeat.json')
  Chat.bridgeAlive = hb ~= nil and type(hb.t) == 'number' and math.abs(os.time() - hb.t) < 10
end

-- What the bridge needs to answer a voice message for the selected follower: written whenever it changes.
function Chat.publishContext()
  local f = R.current()
  if not f then return end
  local history = {}
  for i = 1, #f.history do history[i] = f.history[i] end
  U.writeJson(DIR .. 'voice_context.json', {
    follower = { name = f.name, record = f.record, appearance = f.appearance, persona = f.persona },
    situation = situation(f),
    history = history,
    speak = C.v.speakReplies,
  })
end

return Chat
