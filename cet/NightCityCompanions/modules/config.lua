-- Night City Companions -- settings, with defaults, kept in settings.json beside init.lua.
local U = require('modules/util')

local C = {}
local PATH = 'settings.json'

C.defaults = {
  -- followers
  maxFollowers = 4,
  invulnerable = true,         -- recruited followers cannot die
  respawnLost = true,          -- a follower who despawned (far away, after a load) is brought back near you
  teleportBeyond = 60,         -- metres: a follower further than this is brought to you
  recruitCopies = 'crowd',     -- recruit as a copy: 'crowd' (street people only), 'always', 'never'
  autoSaveContacts = true,     -- a new follower goes into your neurointerface contacts
  -- neurointerface
  callSeconds = 2.5,           -- the call rings this long before they arrive
  greetOnArrival = true,       -- a called contact says something when they arrive (needs the bridge)
  -- AI chat
  chatEnabled = true,
  historyTurns = 16,           -- lines of conversation sent with each message
  speakReplies = false,        -- the bridge reads replies aloud (needs --voice on the bridge)
  subtitleSeconds = 8,
  -- growth
  scaleMode = 0,               -- 0 Root bone, 1 every bone (see red4ext/CompanionScale); pick whichever looks right
  growSpeed = 0.5,             -- scale units per second when changing size
  gradualGrowth = false,       -- followers keep growing slowly on their own
  gradualPerMinute = 0.05,
  minScale = 0.25,
  maxScale = 12.0,
  -- climbing and riding
  rideMinScale = 3.0,          -- a follower must be at least this big to climb
  climbSeconds = 1.6,          -- the climb from the ground to the mount point (0 = instant)
  comfortFade = false,         -- skip the climb movement and jump straight up (less motion)
  walkDistance = 6.0,          -- metres per "walk where I look" step, times their scale
  mounts = {
    -- right, forward, up in metres at scale 1; tuned in the window
    { name = 'Right shoulder', offset = { 0.17, -0.02, 1.50 } },
    { name = 'Left shoulder',  offset = { -0.17, -0.02, 1.50 } },
    { name = 'Head',           offset = { 0.0, -0.02, 1.84 } },
    { name = 'Open palm',      offset = { 0.30, 0.30, 1.05 } },
  },
}

local function merge(into, from)
  for k, v in pairs(from) do
    if type(v) == 'table' and type(into[k]) == 'table' and #v == 0 then
      merge(into[k], v)
    else
      into[k] = v
    end
  end
end

local function copy(t)
  if type(t) ~= 'table' then return t end
  local o = {}
  for k, v in pairs(t) do o[k] = copy(v) end
  return o
end

function C.load()
  C.v = copy(C.defaults)
  local saved = U.readJson(PATH)
  if type(saved) == 'table' then merge(C.v, saved) end
  return C.v
end

function C.save()
  U.writeJson(PATH, C.v)
end

C.load()
return C
