"""Version 1 stdio service. No ML imports; EOF is observed before initialization."""
import contextlib
import json
import math
import os
from pathlib import Path
import queue
import select
import threading
import uuid

PROFILE = "gpt-sovits-v2proplus-cpu1"
MAX_LINE = 65536


def _object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate field")
        result[key] = value
    return result


def _uuid(value):
    if not isinstance(value, str) or len(value) != 36:
        raise ValueError("invalid identifier")
    if str(uuid.UUID(value)).lower() != value.lower():
        raise ValueError("invalid identifier")


def decode_command(line: bytes) -> dict:
    if not line or len(line) > MAX_LINE or not line.endswith(b"\n"):
        raise ValueError("incomplete or oversized command")
    value = json.loads(line.decode("utf-8"), object_pairs_hook=_object, parse_constant=lambda _: (_ for _ in ()).throw(ValueError("nonfinite number")))
    if not isinstance(value, dict) or type(value.get("v")) is not int or value["v"] != 1:
        raise ValueError("unsupported protocol")
    _uuid(value.get("sessionID"))
    if value.get("command") == "shutdown":
        if set(value) != {"v", "command", "sessionID"}:
            raise ValueError("unknown shutdown field")
        return value
    if set(value) != {"v", "command", "sessionID", "requestID", "text", "speedFactor"} or value.get("command") != "generate":
        raise ValueError("unknown command")
    _uuid(value["requestID"])
    text, speed = value["text"], value["speedFactor"]
    if not isinstance(text, str) or not text.strip() or len(text.encode("utf-16-le")) // 2 > 600 or any(ord(c) < 32 and c not in "\n\t" for c in text):
        raise ValueError("invalid text")
    if type(speed) not in (int, float) or not math.isfinite(speed) or not 0.7 <= speed <= 1.3:
        raise ValueError("invalid speed")
    return value


def serve(reader, writer, backend_factory) -> int:
    """Factory is internal and carries session_id; the production CLI fixes it.

    Initialization and generation run in a daemon thread. The coordinator can
    return on parent EOF even while a framework is blocked inside model loading.
    """
    session = backend_factory.session_id
    _uuid(session)
    events = queue.Queue(maxsize=8)
    disconnected = threading.Event()
    stop_reader = threading.Event()
    state = "starting"
    backend = None
    active = None
    used = set()

    def emit(event, **fields):
        payload = {"v": 1, "event": event, "sessionID": session, **fields}
        writer.write(json.dumps(payload, ensure_ascii=False, separators=(",", ":")) + "\n")
        writer.flush()

    def receive():
        try:
            pending = bytearray()
            descriptor = reader.fileno()
            while not stop_reader.is_set():
                readable, _, _ = select.select([descriptor], [], [], 0.05)
                if not readable:
                    continue
                chunk = os.read(descriptor, 4096)
                if not chunk:
                    break
                pending.extend(chunk)
                while b"\n" in pending or len(pending) > MAX_LINE:
                    newline = pending.find(b"\n")
                    count = min(newline + 1 if newline >= 0 else MAX_LINE + 1, MAX_LINE + 1)
                    line = bytes(pending[:count]); del pending[:count]
                    try:
                        events.put_nowait(("line", line))
                    except queue.Full:
                        return
        finally:
            disconnected.set()

    def initialize():
        try:
            value = backend_factory()
            value.initialize()
            events.put(("ready", value))
        except Exception:
            events.put(("initializationError", None))

    def generate(command, value):
        try:
            output = value.work_root / (command["requestID"] + ".wav")
            result = value.generate(command["text"], command["speedFactor"], output)
            if set(result) != {"sampleRate", "frames"} or type(result["sampleRate"]) is not int or result["sampleRate"] != 32000 or type(result["frames"]) is not int or not 0 < result["frames"] <= 32000 * 240:
                raise ValueError("invalid audio result")
            events.put(("result", result))
        except Exception:
            events.put(("generationError", None))

    # This begins before the model factory, not after its heavy imports.
    receiver = threading.Thread(target=receive, daemon=True)
    receiver.start()
    with open(os.devnull, "w") as discarded, contextlib.redirect_stdout(discarded):
        threading.Thread(target=initialize, daemon=True).start()
        while not disconnected.is_set():
            try:
                event, value = events.get(timeout=0.05)
            except queue.Empty:
                continue
            if event == "ready":
                backend, state = value, "idle"
                emit("ready", profile=PROFILE)
            elif event == "initializationError":
                emit("error", code="resource")
                return 1
            elif event == "line":
                try:
                    command = decode_command(value)
                    if command["sessionID"].lower() != session.lower():
                        raise ValueError("wrong session")
                    if command["command"] == "shutdown":
                        stop_reader.set(); receiver.join(timeout=0.2)
                        return 0
                    if state != "idle" or command["requestID"].lower() in used or len(used) >= 1024:
                        raise ValueError("busy or duplicate request")
                    used.add(command["requestID"].lower())
                    active, state = command["requestID"], "generating"
                    threading.Thread(target=generate, args=(command, backend), daemon=True).start()
                except (ValueError, UnicodeError, RecursionError):
                    emit("error", code="protocol")
                    stop_reader.set(); receiver.join(timeout=0.2)
                    return 1
            elif event == "result":
                emit("result", requestID=active, **value)
                active, state = None, "idle"
            elif event == "generationError":
                emit("error", requestID=active, code="generation")
                active, state = None, "idle"
    return 0
