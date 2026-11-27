-- Night City Companions -- anyone as a follower, AI conversation with them, size growth, climbing a large follower,
-- and calling saved followers through V's neurointerface.
--
-- A Cyber Engine Tweaks mod (bin/x64/plugins/cyber_engine_tweaks/mods/NightCityCompanions). Needs Codeware for
-- spawning (street people, called contacts); growth needs the CompanionScale RED4ext plugin from this project.
--
--   modules/roster.lua  recruit / dismiss / follow / bring back
--   modules/chat.lua    conversation through the bridge program (companion_bridge/ in this folder)
--   modules/growth.lua  size, gradual growth
--   modules/ride.lua    climbing and riding
--   modules/neuro.lua   saved contacts: holo-call them, or call them to your side
--
-- Everything is reachable from the window (open the overlay; "Companions") and from hotkeys you bind in the
-- overlay's Bindings page. The project's README has the install and test steps.
-- Each part is loaded on its own, so one that fails to load is reported in this mod's log instead of stopping the rest.
local function load(name)
  local ok, m, err = pcall(require, name)
  if ok and type(m) == 'table' then return m end
  print(string.format('[Companions] could not load %s: %s', name, tostring(ok and (err or m) or m)))
  return nil
end
local U = load('modules/util')
local C = load('modules/config')
local R = load('modules/roster')
local Chat = load('modules/chat')
local G = load('modules/growth') or { available = false, update = function() end, releaseAll = function() end,
  nudge = function() end, reset = function() end, setTarget = function() end, lookUp = function() end }
local Ride = load('modules/ride')
local Neuro = load('modules/neuro')
local Cower = load('modules/cower') or { update = function() end, releaseAll = function() end }

local ui = { overlay = false, pinned = false, focusInput = false }
local saveClock = 0
local lastSelected = nil

----------------------------------------------------------------------------------------------- hotkeys
-- (registerHotkey / registerInput exist only while this file's root runs)

registerHotkey('vrc_recruit', 'Companions: recruit who I look at', function() R.recruit() end)
registerHotkey('vrc_dismiss', 'Companions: dismiss selected follower', function()
  if Ride.follower == R.current() then Ride.dismount() end
  R.dismiss()
end)
registerHotkey('vrc_next', 'Companions: select next follower', function()
  if #R.list > 0 then R.selected = R.selected % #R.list + 1 U.say('selected %s', R.current().name) end
end)
registerHotkey('vrc_bring', 'Companions: bring followers to me', function()
  for _, f in ipairs(R.list) do R.teleportToPlayer(f) end
end)
registerHotkey('vrc_grow', 'Companions: grow selected (+0.5x)', function() G.nudge(R.current(), 0.5) end)
registerHotkey('vrc_shrink', 'Companions: shrink selected (-0.5x)', function() G.nudge(R.current(), -0.5) end)
registerHotkey('vrc_size_reset', 'Companions: normal size', function() G.reset(R.current()) end)
registerHotkey('vrc_climb', 'Companions: climb on / get down', function()
  if Ride.state == 'none' then Ride.start() else Ride.dismount() end
end)
registerHotkey('vrc_mount', 'Companions: next riding spot', function() Ride.cycleMount() end)
registerHotkey('vrc_walk', 'Companions: walk where I look (while riding)', function() Ride.walkWhereLooking() end)
registerHotkey('vrc_talk', 'Companions: voice on / off', function()
  Chat.publishContext()
  Chat.setListening(not Chat.listening)
  U.say(Chat.listening and 'listening' or 'stopped listening')
end)
registerHotkey('vrc_window', 'Companions: show / hide window', function() ui.pinned = not ui.pinned end)
registerHotkey('vrc_save', 'Companions: save selected follower to contacts', function()
  local f = R.current()
  if f then R.setSaved(f, true) U.say('%s saved to your contacts', f.name) end
end)
registerHotkey('vrc_neuro', 'Neurointerface: show / hide contacts', function()
  Neuro.open = not Neuro.open
  if Neuro.open then Neuro.step(0) end
end)
registerHotkey('vrc_neuro_next', 'Neurointerface: next contact', function() Neuro.step(1) end)
registerHotkey('vrc_neuro_prev', 'Neurointerface: previous contact', function() Neuro.step(-1) end)
registerHotkey('vrc_neuro_call', 'Neurointerface: call contact to me', function() Neuro.call() end)
registerHotkey('vrc_neuro_hangup', 'Neurointerface: hang up', function() Neuro.hangUp() end)

----------------------------------------------------------------------------------------------- events

-- The mod does nothing while a save loads: spawning people or changing AI before the world is up crashes the game.
-- After the player is attached it waits for the HUD to appear (the quest tracker starting) and a few seconds more,
-- or at most 30 seconds.
local session = { ready = false, hud = false, wait = 0 }

-- True in the main menu and character creation, where there is a player of sorts but no game to put anyone in.
local function preGame()
  local yes = false
  pcall(function() yes = Game.GetSystemRequestsHandler():IsPreGame() end)
  return yes
end

registerForEvent('onInit', function()
  session.ready = Game.GetPlayer() ~= nil and not preGame()   -- the mod was reloaded in the middle of play
  -- after a load or a new game every entity handle is stale
  pcall(function()
    Observe('PlayerPuppet', 'OnGameAttached', function()
      session.ready, session.hud, session.wait = false, false, 0
      U.trace('a game is loading: waiting')
      Ride.state, Ride.follower = 'none', nil
      R.forgetHandles()
    end)
  end)
  pcall(function()
    Observe('QuestTrackerGameController', 'OnInitialize', function() session.hud = true end)
  end)
  pcall(function()
    ObserveBefore('PlayerPuppet', 'OnDetach', function()
      session.ready = false
      Ride.state, Ride.follower = 'none', nil
    end)
  end)
  Chat.setListening(false)
  pcall(G.lookUp)
  U.say('loaded: %d followers on the roster; growth %s', #R.list,
    G.available and 'available' or 'NOT available (install the CompanionScale plugin)')
end)

registerForEvent('onOverlayOpen', function() ui.overlay = true end)
registerForEvent('onOverlayClose', function() ui.overlay = false end)

registerForEvent('onUpdate', function(dt)
  if not Game.GetPlayer() then return end
  if preGame() then session.ready, session.hud, session.wait = false, false, 0 return end
  if not session.ready then
    session.wait = session.wait + dt
    if (session.hud and session.wait > 3) or session.wait > 30 then
      session.ready = true
      U.trace('the game is up: followers can come back')
    else
      return
    end
  end
  U.try('roster', R.update, dt)
  U.try('growth', G.update, dt)
  U.try('ride', Ride.update, dt)
  U.try('chat', Chat.update, dt)
  U.try('neurointerface', Neuro.update, dt)
  U.try('cower', Cower.update, dt)
  if lastSelected ~= R.current() then
    lastSelected = R.current()
    pcall(Chat.publishContext)
  end
  saveClock = saveClock + dt
  if saveClock > 30 then saveClock = 0 R.save() end
end)

registerForEvent('onShutdown', function()
  pcall(G.releaseAll)
  pcall(R.save)
  pcall(Chat.setListening, false)
end)

----------------------------------------------------------------------------------------------- window

local function followerList()
  if #R.list == 0 then
    ImGui.TextWrapped('No followers yet. Look at someone and press Recruit.')
  end
  for i, f in ipairs(R.list) do
    local label = string.format('%s%s##f%d', f.name, f.lost and ' (away)' or '', i)
    if ImGui.Selectable(label, i == R.selected) then R.selected = i end
  end
  if ImGui.Button('Recruit who I look at') then R.recruit() end
  ImGui.SameLine()
  if ImGui.Button('Bring them to me') then for _, f in ipairs(R.list) do R.teleportToPlayer(f) end end
  local f = R.current()
  if f then
    ImGui.SameLine()
    if ImGui.Button('Dismiss ' .. f.name) then
      if Ride.follower == f then Ride.dismount() end
      R.dismiss(f)
      return
    end
    ImGui.SameLine()
    local saved, changed = ImGui.Checkbox('In contacts', f.saved == true)
    if changed then R.setSaved(f, saved) end
  end
end

local function chatTab(f)
  ImGui.Text(Chat.bridgeAlive and 'Bridge: running' or 'Bridge: NOT running (run companion_bridge\\start_bridge.bat)')
  ImGui.BeginChild('vrc_history', 0, 260, true)
  for _, line in ipairs(f.history) do
    if line.role == 'user' then
      ImGui.TextWrapped('V: ' .. line.text)
    elseif line.role == 'assistant' then
      ImGui.TextWrapped(f.name .. ': ' .. line.text)
    else
      ImGui.TextWrapped(line.text)
    end
  end
  if f.waiting then ImGui.TextWrapped(f.name .. ' is thinking...') end
  ImGui.EndChild()
  if ui.focusInput then ImGui.SetKeyboardFocusHere() ui.focusInput = false end
  local text, entered = ImGui.InputText('##vrc_say', Chat.draft, 400, ImGuiInputTextFlags.EnterReturnsTrue)
  if text ~= nil then Chat.draft = text end
  ImGui.SameLine()
  if ImGui.Button('Say') or entered then
    Chat.send(Chat.draft, f)
    Chat.draft = ''
    ui.focusInput = true
  end
  if ImGui.Button(Chat.listening and 'Stop listening' or 'Talk (voice)') then
    Chat.publishContext()
    Chat.setListening(not Chat.listening)
  end
  ImGui.SameLine()
  local speak, changed = ImGui.Checkbox('Read replies aloud', C.v.speakReplies)
  if changed then C.v.speakReplies = speak C.save() Chat.setListening(Chat.listening) end
  ImGui.SameLine()
  if ImGui.Button('Forget conversation') then f.history = {} R.save() end
  if ImGui.CollapsingHeader('Personality') then
    local persona, edited = ImGui.InputTextMultiline('##vrc_persona', f.persona or '', 2000, 0, 120)
    if edited then f.persona = persona end
    if ImGui.Button('Save personality') then R.save() Chat.publishContext() end
  end
end

local function sizeTab(f)
  if not G.available then
    ImGui.TextWrapped('Size changes need the CompanionScale plugin (red4ext\\plugins\\CompanionScale). '
      .. 'Without it the slider does nothing.')
  end
  ImGui.Text(string.format('Now %.2fx, going to %.2fx', f.scale or 1, f.targetScale or 1))
  local t, used = ImGui.SliderFloat('Size##vrc_size', f.targetScale or 1, C.v.minScale, C.v.maxScale, '%.2fx')
  if used then G.setTarget(f, t) end
  if ImGui.Button('-0.5x') then G.nudge(f, -0.5) end
  ImGui.SameLine()
  if ImGui.Button('+0.5x') then G.nudge(f, 0.5) end
  ImGui.SameLine()
  if ImGui.Button('Normal') then G.reset(f) end
  local v, c
  v, c = ImGui.SliderFloat('Change speed', C.v.growSpeed, 0.05, 3.0, '%.2f') if c then C.v.growSpeed = v C.save() end
  v, c = ImGui.Checkbox('Keep growing slowly', C.v.gradualGrowth) if c then C.v.gradualGrowth = v C.save() end
  if C.v.gradualGrowth then
    v, c = ImGui.SliderFloat('Growth per minute', C.v.gradualPerMinute, 0.01, 1.0, '%.2fx')
    if c then C.v.gradualPerMinute = v C.save() end
  end
  v, c = ImGui.SliderFloat('Largest size', C.v.maxScale, 1.0, 50.0, '%.1fx') if c then C.v.maxScale = v C.save() end
  ImGui.Separator()
  ImGui.TextWrapped('Scaling method: if the body looks swollen, stretched or crumpled, try another one.')
  if ImGui.RadioButton('Whole body (default)', C.v.scaleMethod == 2) then C.v.scaleMethod = 2 C.save() end
  ImGui.SameLine()
  if ImGui.RadioButton('Root bone only', C.v.scaleMethod == 0) then C.v.scaleMethod = 0 C.save() end
  ImGui.SameLine()
  if ImGui.RadioButton('Every bone', C.v.scaleMethod == 1) then C.v.scaleMethod = 1 C.save() end
  ImGui.SameLine()
  if ImGui.RadioButton('Every bone, size only', C.v.scaleMethod == 3) then C.v.scaleMethod = 3 C.save() end
  if ImGui.RadioButton('By skeleton', C.v.scaleMethod == 4) then C.v.scaleMethod = 4 C.save() end
  ImGui.SameLine()
  if ImGui.RadioButton('Test: head only', C.v.scaleMethod == 5) then C.v.scaleMethod = 5 C.save() end
end

local function rideTab(f)
  ImGui.TextWrapped(string.format('Climbing needs a follower at least %.1fx tall. %s is %.2fx.',
    C.v.rideMinScale, f.name, f.scale or 1))
  ImGui.Text('State: ' .. Ride.state)
  for i, m in ipairs(C.v.mounts) do
    if ImGui.RadioButton(m.name .. '##vrc_mount' .. i, Ride.mount == i) then Ride.mount = i end
    if i < #C.v.mounts then ImGui.SameLine() end
  end
  if Ride.state == 'none' then
    if ImGui.Button('Climb on') then Ride.start(f) end
  else
    if ImGui.Button('Get down') then Ride.dismount() end
    ImGui.SameLine()
    if ImGui.Button('Walk where I look') then Ride.walkWhereLooking() end
  end
  local v, c
  v, c = ImGui.SliderFloat('Climb time', C.v.climbSeconds, 0, 5, '%.1fs') if c then C.v.climbSeconds = v C.save() end
  v, c = ImGui.Checkbox('Comfort: no climb movement', C.v.comfortFade) if c then C.v.comfortFade = v C.save() end
  v, c = ImGui.SliderFloat('Smallest size to climb', C.v.rideMinScale, 1.0, 10.0, '%.1fx')
  if c then C.v.rideMinScale = v C.save() end
  if ImGui.CollapsingHeader('Tune riding spot') then
    local m = C.v.mounts[Ride.mount]
    local labels = { 'Right / left', 'Forward / back', 'Height' }
    for k = 1, 3 do
      local val, ch = ImGui.SliderFloat(labels[k] .. '##vrc_off' .. k, m.offset[k], -1.0, 2.2, '%.2f m')
      if ch then m.offset[k] = val C.save() end
    end
    ImGui.TextWrapped('Offsets are at normal size; they grow with the follower.')
  end
end

local function settingsTab()
  local v, c
  v, c = ImGui.Checkbox('Followers cannot die', C.v.invulnerable) if c then C.v.invulnerable = v C.save() end
  v, c = ImGui.Checkbox('Bring back followers who despawned', C.v.respawnLost) if c then C.v.respawnLost = v C.save() end
  v, c = ImGui.SliderInt('Most followers', C.v.maxFollowers, 1, 8) if c then C.v.maxFollowers = v C.save() end
  v, c = ImGui.Checkbox('Save new followers to contacts', C.v.autoSaveContacts)
  if c then C.v.autoSaveContacts = v C.save() end
  ImGui.Text('Recruit as a copy:')
  ImGui.SameLine()
  for _, mode in ipairs({ { 'crowd', 'street people' }, { 'always', 'everyone' }, { 'never', 'nobody' } }) do
    if ImGui.RadioButton(mode[2] .. '##vrc_copy_' .. mode[1], C.v.recruitCopies == mode[1]) then
      C.v.recruitCopies = mode[1] C.save()
    end
    ImGui.SameLine()
  end
  ImGui.NewLine()
  ImGui.TextWrapped('If someone will not follow after you recruit them, dismiss them and choose "everyone".')
  v, c = ImGui.Checkbox('Take cover in fights (off: they fight)', (C.v.inCombat or 'cower') == 'cower')
  if c then C.v.inCombat = v and 'cower' or 'fight' C.save() end
  v, c = ImGui.Checkbox('Called contacts greet you', C.v.greetOnArrival) if c then C.v.greetOnArrival = v C.save() end
  v, c = ImGui.SliderFloat('Call rings for', C.v.callSeconds, 0, 8, '%.1fs') if c then C.v.callSeconds = v C.save() end
  v, c = ImGui.SliderInt('Conversation remembered (turns)', C.v.historyTurns, 2, 40) if c then C.v.historyTurns = v C.save() end
  ImGui.Separator()
  ImGui.Text('Log')
  ImGui.BeginChild('vrc_log', 0, 140, true)
  for _, line in ipairs(U.log) do ImGui.TextWrapped(line) end
  ImGui.EndChild()
end

registerForEvent('onDraw', function()
  -- the latest reply, as a subtitle, whether or not the overlay is open
  local s = Chat.subtitle
  if s and os.clock() < s.untilT then
    ImGui.SetNextWindowBgAlpha(0.55)
    local flags = ImGuiWindowFlags.NoTitleBar + ImGuiWindowFlags.NoInputs + ImGuiWindowFlags.AlwaysAutoResize
      + ImGuiWindowFlags.NoNav
    if ImGui.Begin('##vrc_subtitle', flags) then
      ImGui.PushTextWrapPos(520)
      ImGui.TextWrapped(s.who .. ': ' .. s.text)
      ImGui.PopTextWrapPos()
    end
    ImGui.End()
  end
  if Neuro.open then
    ImGui.SetNextWindowSize(420, 480, ImGuiCond.FirstUseEver)
    if ImGui.Begin('Neurointerface') then Neuro.draw(chatTab) end
    ImGui.End()
  end
  if not (ui.overlay or ui.pinned) then return end
  ImGui.SetNextWindowSize(560, 640, ImGuiCond.FirstUseEver)
  if ImGui.Begin('Companions') then
    followerList()
    local f = R.current()
    if ImGui.BeginTabBar('vrc_tabs') then
      if f and ImGui.BeginTabItem('Talk') then chatTab(f) ImGui.EndTabItem() end
      if f and ImGui.BeginTabItem('Size') then sizeTab(f) ImGui.EndTabItem() end
      if f and ImGui.BeginTabItem('Climb') then rideTab(f) ImGui.EndTabItem() end
      if ImGui.BeginTabItem('Neurointerface') then Neuro.draw(chatTab) ImGui.EndTabItem() end
      if ImGui.BeginTabItem('Settings') then settingsTab() ImGui.EndTabItem() end
      ImGui.EndTabBar()
    end
  end
  ImGui.End()
end)

return { roster = R, chat = Chat, growth = G, ride = Ride, config = C, neuro = Neuro }
