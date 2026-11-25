-- Night City Companions -- V's neurointerface: the saved contacts, a holo-call to talk with one wherever they are, and calling
-- one to your side.
--
-- Calling rings for a moment (callSeconds), then the contact is spawned near V with their saved appearance, size,
-- persona and conversation, made a follower, and (with the bridge running) says something about having been called.
-- Works from the window or from hotkeys alone (next / previous contact, call), so it can be used in the headset
-- without a pointer.
local U = require('modules/util')
local C = require('modules/config')
local R = require('modules/roster')
local Chat = require('modules/chat')

local N = {}
N.open = false
N.index = 1
N.state = 'idle'       -- idle | ringing | arriving
N.target = nil
N.holo = nil           -- the contact on a holo-call (talking without being here)
local ringT = 0

local function banner(text, seconds)
  Chat.subtitle = { who = 'NEUROINTERFACE', text = text, untilT = os.clock() + (seconds or 3) }
end

function N.selected()
  if #R.contacts == 0 then return nil end
  N.index = math.max(1, math.min(N.index, #R.contacts))
  return R.contacts[N.index]
end

function N.step(by)
  if #R.contacts == 0 then banner('No saved contacts.') return end
  N.index = (N.index - 1 + by) % #R.contacts + 1
  local p = R.contacts[N.index]
  banner(string.format('Contact %d/%d: %s%s', N.index, #R.contacts, p.name, p.active and ' (with you)' or ''), 2.5)
end

local function arrived(p)
  N.state, N.target = 'idle', nil
  banner(p.name .. ' has arrived.', 2.5)
  if C.v.greetOnArrival and Chat.bridgeAlive then
    Chat.send('(V just called you over the neurointerface and you have arrived at their side. Greet them.)', p,
      { hidden = true })
  end
end

function N.call(p)
  p = p or N.selected()
  if not p then banner('No saved contacts.') return end
  if N.state ~= 'idle' then return end
  if p.active and R.alive(p) then
    R.teleportToPlayer(p)
    banner(p.name .. ' is already with you.', 2.5)
    return
  end
  N.state, N.target, ringT = 'ringing', p, 0
  banner('Calling ' .. p.name .. '...', C.v.callSeconds + 1)
  pcall(function() Game.GetAudioSystem():Play(CName.new('ui_phone_initiation_call')) end)
end

function N.hangUp()
  if N.state == 'ringing' then banner('Call ended.', 2) end
  N.state, N.target = 'idle', nil
end

function N.update(dt)
  if N.state == 'ringing' then
    ringT = ringT + dt
    if ringT >= C.v.callSeconds then
      local p = N.target
      if R.summon(p, arrived) then
        N.state = 'arriving'
        banner(p.name .. ' picked up. On the way.', 3)
      else
        N.state, N.target = 'idle', nil
        banner(p.name .. " can't come right now.", 3)
      end
    end
  elseif N.state == 'arriving' then
    ringT = ringT + dt
    if ringT > C.v.callSeconds + 15 then N.state, N.target = 'idle', nil end   -- never arrived
  end
end

-- The window's contacts page. chatView draws a conversation (init.lua's Talk tab), reused for holo-calls.
function N.draw(chatView)
  ImGui.Text('NEUROINTERFACE // CONTACTS')
  ImGui.Separator()
  if #R.contacts == 0 then
    ImGui.TextWrapped('No saved contacts. Recruit someone and press "Save to contacts" (new followers are saved '
      .. 'automatically unless you turned that off in Settings).')
    return
  end
  for i, p in ipairs(R.contacts) do
    local status = p.active and (p.lost and '  [on the way]' or '  [with you]') or ''
    if ImGui.Selectable(string.format('%s  %.1fx%s##vrc_c%d', p.name, p.targetScale or 1, status, i), i == N.index) then
      N.index = i
    end
  end
  local p = N.selected()
  if not p then return end
  ImGui.Separator()
  if N.state == 'ringing' then
    ImGui.Text('Calling ' .. N.target.name .. '...')
    if ImGui.Button('Hang up') then N.hangUp() end
  else
    if ImGui.Button('Call ' .. p.name .. ' to me') then N.call(p) end
    ImGui.SameLine()
    if ImGui.Button(N.holo == p and 'End holo-call' or 'Holo-call') then N.holo = (N.holo ~= p) and p or nil end
    ImGui.SameLine()
    if ImGui.Button('Delete contact') then
      if N.holo == p then N.holo = nil end
      R.forget(p)
      return
    end
  end
  if N.holo and chatView then
    ImGui.Separator()
    ImGui.Text('Holo-call with ' .. N.holo.name)
    chatView(N.holo)
  end
end

return N
