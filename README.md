# Night City Companions

A Cyberpunk 2077 mod (PC, game version 2.5) for the standard game:

| Feature | What you do |
|---|---|
| **Recruit anyone** | Look at a person and press *Recruit*. Named characters, vendors and ordinary street pedestrians all work. They follow you, fight on your side and can be made unkillable. Up to 4 at once (setting). |
| **Neurointerface contacts** | Followers are saved to V's contacts. From the *Neurointerface* tab or its hotkeys, call a contact to your side from anywhere, or holo-call them to talk without them being there. They arrive with their look, size and conversation, and greet you. Contacts last across saves and game sessions. |
| **AI conversation** | Type in the *Talk* tab, or talk with your microphone. The follower answers in character; the latest reply shows as a subtitle. Uses Claude through a small helper program that runs beside the game. |
| **Growth** | *Size* tab: a slider from 0.25x to 50x, +/- buttons, and optional slow growth over time. |
| **Climbing and riding** | When a follower is at least 3x tall (setting), climb up and ride on a shoulder, their head or an open palm. *Walk where I look* sends them a few strides. |

## What you need

- [Cyber Engine Tweaks](https://www.nexusmods.com/cyberpunk2077/mods/107) (runs the mod and its window)
- [Codeware](https://www.nexusmods.com/cyberpunk2077/mods/7780) (spawning: street people, called contacts)
- [RED4ext](https://www.nexusmods.com/cyberpunk2077/mods/2380) (only for growth, which is a small RED4ext plugin)
- For the AI conversation: Python 3.10 or newer and an Anthropic API key

## Install

**From a build** (GitHub Actions builds one on every push: open *Actions*, the latest *build* run, and download the
*NightCityCompanions* artifact): extract it into your Cyberpunk 2077 folder (the one with `bin`, `r6`, `red4ext`).
It puts:

```
bin\x64\plugins\cyber_engine_tweaks\mods\NightCityCompanions\   the mod, and companion_bridge\ (the chat helper)
red4ext\plugins\CompanionScale\CompanionScale.dll                 the growth plugin
```

**From source**: copy `cet\NightCityCompanions` to `<game>\bin\x64\plugins\cyber_engine_tweaks\mods\`. For growth,
build the plugin with Visual Studio 2022 ("Desktop development with C++"):

```
cmake -S red4ext/CompanionScale -B build -A x64
cmake --build build --config Release
```

and copy `build\Release\CompanionScale.dll` to `<game>\red4ext\plugins\CompanionScale\`.

**The chat helper**: get an API key at https://console.anthropic.com and set it once in a terminal:
`setx ANTHROPIC_API_KEY "sk-ant-..."` (open a new terminal afterwards). Then run
`<the mod folder>\companion_bridge\start_bridge.bat` before or while you play. The first start sets up a Python
environment and installs the `anthropic` package. Options:

- Replies read aloud: `pip install pyttsx3` in `companion_bridge\.venv`, then `start_bridge.bat --voice`, and tick
  *Read replies aloud* in the Talk tab.
- Talk with your microphone: `pip install sounddevice numpy faster-whisper`, then `start_bridge.bat --listen`.
  Speech is transcribed on your PC; only the text goes to the AI.

The helper uses `claude-opus-5-5` at low effort for quick replies (`--model` picks another). Each message costs a
fraction of a cent.

## Controls

Open CET's overlay to see the *Companions* window. Bind keys in CET's *Bindings* page; every action is listed as
`Companions: ...` (recruit, dismiss, next follower, save to contacts, bring followers to me, grow, shrink, normal
size, climb on / get down, next riding spot, walk where I look, voice on / off, show / hide window) or
`Neurointerface: ...` (show / hide contacts, next contact, previous contact, call contact to me, hang up). The
neurointerface keys work with the overlay closed: each contact you flip to shows as a subtitle.

## How it works, and its limits

- **Followers** get the game's own companion setup: an `AIFollowerRole` on the player, the `player` attitude group
  and the companion flag.
- **Street people** (crowd and background pedestrians) are run by the crowd system, which ignores AI roles, so the
  mod recruits a copy: the same character record and appearance spawned where they stand with Codeware, the
  original removed, and the copy made a follower. *Recruit as a copy* in Settings can apply this to everyone (if
  someone named will not follow) or to nobody.
- **Contacts** live in `roster.json` in the mod folder: record, appearance, size, persona and conversation, for every
  save. Dismissing a contact sends them home; dismissing someone who is not a contact forgets them.
- **Chat** goes through files (`bridge\requests`, `bridge\responses`) because CET mods have no network access.
  The persona text in the Talk tab is the character's brief; edit it freely.
- **Growth** writes the scale into the person's animation pose every frame (bodies are skinned meshes, which other
  scaling tricks do not affect). Only what is drawn grows: collision, stride and navigation stay human-sized, so a
  giant's feet slide a little as they walk, and a very large one can flicker out at the screen edge. The plugin's
  hook point is specific to game version 2.5; RED4ext will not load it on another version.
- **Riding** holds you at the mount point every frame, because the follower's collision does not grow and there is
  nothing to stand on.

## What to test

Nothing here has been run in the game yet. Please check, in order, and report what you see (the mod's lines start
with `[Companions]` in CET's console and in the Settings tab's log; the plugin logs to `red4ext\logs`):

1. The mod loads: the overlay shows a *Companions* window and the log says `loaded: ... growth available`.
2. Recruit a named character (a vendor, a bodyguard): they follow you, fight with you, and come back with *Bring
   them to me*.
3. Recruit an ordinary pedestrian: they vanish and an identical person appears in the same spot within a second or
   two and follows you. Check they look the same.
4. Dismiss a saved follower, walk away, then *Neurointerface* > *Call ... to me*: after the ring they appear beside
   you at their saved size and (helper running) greet you. Try a *Holo-call* with someone who is not there.
5. Load a different save: the contacts are still there.
6. Chat with the helper running: the window says *Bridge: running* and a message gets an in-character reply.
7. Growth, scaling method *Root bone*: set 2x. Expected: the whole body, clothes and hair twice the size, feet on the
   ground. If the body looks stretched or the limbs fly apart, switch to *Every bone* and say which looks right.
8. Climb on a 4x follower; ride while they walk; *Get down*.

## Credits

Growth adapts the pose-hook approach and engine details from the
[Cyberpunk VR Port](https://github.com/dariulone/cyberpunk-vr-port) by dariulone (MIT). See LICENSE.
