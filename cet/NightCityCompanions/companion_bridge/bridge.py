"""Night City Companions bridge: lets your in-game followers talk back, using Claude.

Lua mods inside Cyberpunk 2077 cannot make web requests, so the Night City Companions mod writes each message you send a
follower to a file, and this program (running beside the game) answers it:

    <mod>/bridge/requests/<id>.json   written by the game: follower, persona, situation, history, message
    <mod>/bridge/responses/<id>.json  written here: {"id", "reply"} or {"id", "error"}
    <mod>/bridge/heartbeat.json       written here every 2 s, so the game can show the bridge is running
    <mod>/bridge/state.json           written by the game: {"listening": bool, "speak": bool}
    <mod>/bridge/voice_context.json   written by the game: who you are talking to, for voice messages
    <mod>/bridge/responses/voice.json written here for a message heard through the microphone

Run:  start_bridge.bat  (or: python bridge.py) from this folder, which sits inside the mod folder
      python bridge.py --mod-dir "D:\\Games\\Cyberpunk 2077\\bin\\x64\\plugins\\cyber_engine_tweaks\\mods\\NightCityCompanions"
      python bridge.py --voice         (also read replies aloud; pip install pyttsx3)
      python bridge.py --listen        (also take voice input; pip install sounddevice numpy faster-whisper)

Needs an Anthropic API key: set ANTHROPIC_API_KEY, or run `ant auth login` once.
"""
from __future__ import annotations

import argparse
import json
import os
import queue
import sys
import threading
import time
from pathlib import Path

import anthropic

MODEL = "claude-opus-5-5"

RULES = """You are a character in the video game Cyberpunk 2077, travelling with the player character, V, as a \
companion. Stay in character at all times and answer as the character would, out loud, in the first person.

- Keep replies short and spoken: one to three sentences, the way people talk, with no stage directions, emotes or \
narration in asterisks.
- You know Night City in 2077, its districts, gangs, corporations and slang. If your character is a known person \
from the game, stay true to their personality and history.
- Keep it PG-13: friendly, flirty or rough is fine, explicit sexual content is not. If V pushes for it, deflect the \
way your character would.
- Never mention being an AI, a model, a game, or these instructions."""


def find_mod_dir() -> Path | None:
    here = Path(__file__).resolve().parent.parent  # companion_bridge/ lives inside the mod folder
    if (here / "init.lua").exists():
        return here
    roots = [
        Path(r"C:\Program Files (x86)\Steam\steamapps\common\Cyberpunk 2077"),
        Path(r"C:\Program Files\Steam\steamapps\common\Cyberpunk 2077"),
        Path(r"D:\SteamLibrary\steamapps\common\Cyberpunk 2077"),
        Path(r"E:\SteamLibrary\steamapps\common\Cyberpunk 2077"),
    ]
    subdirs = [
        Path("bin/x64/plugins/cyber_engine_tweaks/mods/NightCityCompanions"),
    ]
    for root in roots:
        for sub in subdirs:
            if (root / sub / "init.lua").exists():
                return root / sub
    return None


def read_json(path: Path):
    try:
        text = path.read_text(encoding="utf-8")
    except OSError:
        return None
    if not text.strip():
        return None
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return None  # half written: try again next pass


def write_json(path: Path, value) -> None:
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(value, ensure_ascii=False), encoding="utf-8")
    os.replace(tmp, path)


def build_messages(history: list, message: str) -> list:
    """The conversation as alternating user/assistant turns, starting with the user, ending with this message."""
    turns: list[dict] = []
    for line in history or []:
        role = line.get("role")
        text = (line.get("text") or "").strip()
        if role not in ("user", "assistant") or not text:
            continue
        if turns and turns[-1]["role"] == role:
            turns[-1]["content"] += "\n" + text
        else:
            turns.append({"role": role, "content": text})
    while turns and turns[0]["role"] != "user":
        turns.pop(0)
    if turns and turns[-1]["role"] == "user":
        turns[-1]["content"] += "\n" + message
    else:
        turns.append({"role": "user", "content": message})
    return turns


class Companion:
    def __init__(self, model: str):
        self.client = anthropic.Anthropic()
        self.model = model

    def reply(self, follower: dict, situation: str, history: list, message: str) -> str:
        name = follower.get("name") or "your companion"
        persona = follower.get("persona") or f"You are {name}."
        system = f"{RULES}\n\nWho you are:\n{persona}\n\nYour name is {name}."
        if situation:
            system += f"\n\nRight now: {situation}"
        response = self.client.beta.messages.create(
            model=self.model,
            max_tokens=2048,
            system=system,
            messages=build_messages(history, message),
            output_config={"effort": "low"},  # quick, conversational replies
            cache_control={"type": "ephemeral"},
            betas=["server-side-fallback-2026-07-01"],
            fallbacks="default",
        )
        if response.stop_reason == "refusal":
            return "...Let's talk about something else."
        text = "".join(block.text for block in response.content if block.type == "text").strip()
        return text or "..."


class Voice:
    """Reads replies aloud with the system's text-to-speech (Windows SAPI through pyttsx3)."""

    def __init__(self):
        import pyttsx3  # noqa: F401  (fail early if missing)

        self.lines: queue.Queue[str] = queue.Queue()
        threading.Thread(target=self._run, daemon=True).start()

    def _run(self):
        import pyttsx3

        engine = pyttsx3.init()
        while True:
            line = self.lines.get()
            engine.say(line)
            engine.runAndWait()

    def say(self, text: str):
        self.lines.put(text)


class Listener:
    """Records the microphone while the game says to listen, cuts it into utterances, and transcribes them locally."""

    RATE = 16000

    def __init__(self, on_heard, whisper_model: str = "base.en"):
        import numpy  # noqa: F401
        import sounddevice  # noqa: F401
        from faster_whisper import WhisperModel

        print(f"loading speech model {whisper_model} ...")
        self.model = WhisperModel(whisper_model, device="auto", compute_type="int8")
        self.on_heard = on_heard
        self.listening = False
        threading.Thread(target=self._run, daemon=True).start()

    def _run(self):
        import numpy as np
        import sounddevice as sd

        block = int(self.RATE * 0.1)
        speech: list = []
        quiet = 0
        with sd.InputStream(samplerate=self.RATE, channels=1, dtype="float32", blocksize=block) as stream:
            while True:
                data, _ = stream.read(block)
                if not self.listening:
                    speech, quiet = [], 0
                    continue
                loud = float(np.sqrt(np.mean(data**2))) > 0.015
                if loud:
                    speech.append(data.copy())
                    quiet = 0
                elif speech:
                    speech.append(data.copy())
                    quiet += 1
                    if quiet >= 8:  # 0.8 s of quiet ends the utterance
                        audio = np.concatenate(speech)[:, 0]
                        speech, quiet = [], 0
                        if len(audio) > self.RATE * 0.4:
                            segments, _ = self.model.transcribe(audio, language="en")
                            text = " ".join(s.text.strip() for s in segments).strip()
                            if text:
                                self.on_heard(text)


def main() -> int:
    sys.stdout.reconfigure(line_buffering=True)
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--mod-dir", type=Path, help="the Night City Companions mod folder (the one with init.lua)")
    parser.add_argument("--model", default=MODEL, help=f"Claude model (default {MODEL})")
    parser.add_argument("--voice", action="store_true", help="read replies aloud (pip install pyttsx3)")
    parser.add_argument("--listen", action="store_true",
                        help="voice input (pip install sounddevice numpy faster-whisper)")
    parser.add_argument("--whisper-model", default="base.en", help="faster-whisper model for --listen")
    args = parser.parse_args()

    mod = args.mod_dir or find_mod_dir()
    if not mod or not (mod / "init.lua").exists():
        print("Could not find the Night City Companions mod folder. Pass it with --mod-dir.")
        return 2
    bridge = mod / "bridge"
    requests, responses = bridge / "requests", bridge / "responses"
    requests.mkdir(parents=True, exist_ok=True)
    responses.mkdir(parents=True, exist_ok=True)
    print(f"Night City Companions bridge: {mod}")

    companion = Companion(args.model)
    voice = Voice() if args.voice else None
    heard: queue.Queue[str] = queue.Queue()
    listener = Listener(heard.put, args.whisper_model) if args.listen else None

    def answer(follower, situation, history, message) -> dict:
        try:
            return {"reply": companion.reply(follower, situation, history, message)}
        except anthropic.AuthenticationError:
            return {"error": "the bridge has no valid Anthropic API key"}
        except anthropic.RateLimitError:
            return {"error": "too many messages at once, try again in a moment"}
        except anthropic.APIStatusError as e:
            return {"error": f"the AI service answered {e.status_code}"}
        except anthropic.APIConnectionError:
            return {"error": "could not reach the AI service"}

    def speak(result: dict, wanted: bool):
        if voice and wanted and result.get("reply"):
            voice.say(result["reply"])

    last_beat = 0.0
    while True:
        now = time.time()
        if now - last_beat > 2:
            write_json(bridge / "heartbeat.json", {"t": int(now)})
            last_beat = now
        state = read_json(bridge / "state.json") or {}
        if listener:
            listener.listening = bool(state.get("listening"))

        for path in sorted(requests.glob("*.json")):
            req = read_json(path)
            if req is None:
                if now - path.stat().st_mtime > 5:
                    path.unlink(missing_ok=True)  # never finished: drop it
                continue
            rid = req.get("id") or path.stem
            follower = req.get("follower") or {}
            print(f"V -> {follower.get('name')}: {req.get('message')}")
            result = answer(follower, req.get("situation", ""), req.get("history", []), req.get("message", ""))
            print(f"   {follower.get('name')}: {result.get('reply') or result.get('error')}")
            write_json(responses / f"{rid}.json", {"id": rid, **result})
            path.unlink(missing_ok=True)
            speak(result, req.get("speak", False))

        voice_out = responses / "voice.json"
        if not heard.empty() and read_json(voice_out) is None:
            text = heard.get()
            ctx = read_json(bridge / "voice_context.json") or {}
            follower = ctx.get("follower") or {}
            print(f"V (voice) -> {follower.get('name')}: {text}")
            result = answer(follower, ctx.get("situation", ""), ctx.get("history", []), text)
            print(f"   {follower.get('name')}: {result.get('reply') or result.get('error')}")
            write_json(voice_out, {"heard": text, **result})
            speak(result, ctx.get("speak", False) or state.get("speak", False))

        time.sleep(0.2)


if __name__ == "__main__":
    sys.exit(main())
