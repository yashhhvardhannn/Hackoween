#!/usr/bin/env python3
"""
leak_check.py: guards the "no object data reaches Claude" rule.

Three uses:

1. In the agent, before EVERY Claude API call (raises LeakError, aborting the run):

       from tools.leak_check import check_request, check_engine_response
       check_request(dict(system=SYSTEM, tools=TOOLS, messages=messages), command)

   and on every engine reply:

       check_engine_response("/state", resp.json())

2. Over saved runs (CI / QA):

       python tools/leak_check.py runs/<run_id>

3. Self-test:

       python tools/leak_check.py --selftest

Rules enforced
- Engine JSON responses: exact key set per endpoint (plan section 2), correct value types,
  NO free-text strings (only the `state` enum). So "picked up red_cube" is impossible.
- Everything Claude is sent (system prompt, tool schemas, user messages, tool results) is
  scanned for colours, shapes, ids, positions, counts. Images are skipped.
- The user's typed command is allowlisted as that one exact string.
- Assistant-role content is skipped: it's Claude's own output (its observations come from
  the image, which is allowed).
- Frame/clip filenames must be generic (step_012.png, not red_cube_012.png).

There is deliberately no "disable" switch. A leak costs 65 points.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path


class LeakError(Exception):
    """Raised when something that could leak object data is about to reach Claude."""


# --------------------------------------------------------------------------- denylist

COLOUR_WORDS = [
    "red", "green", "blue", "yellow", "magenta", "orange", "purple", "pink", "cyan",
    "teal", "brown", "black", "white", "grey", "gray", "violet", "crimson", "lime",
]
SHAPE_WORDS = [
    "cube", "sphere", "cylinder", "cone", "box", "ball", "square", "circle",
    "pyramid", "prism", "disc", "disk", "rectangle", "triangle",
]

# Boundaries are "not adjacent to a letter" (NOT \\b), so that red_cube, obj_3, zone_1 and
# red2 are caught: \\b treats "_" as part of a word and would miss them.
_L = r"(?<![a-z])"
_R = r"(?![a-z])"

DENY_PATTERNS = [
    re.compile(_L + r"(?:%s)s?" % "|".join(COLOUR_WORDS + SHAPE_WORDS) + _R, re.I),
    re.compile(_L + r"zone_\w+", re.I),
    re.compile(_L + r"obj[_-]?\d+", re.I),
    # "object id", "target position", "zone coordinates", ...
    re.compile(
        _L + r"(?:object|target|zone|goal)[ _-]?"
        r"(?:id|pos|position|coords?|coordinates?|location|count|name)" + _R,
        re.I,
    ),
    # counts: "there are 5 objects", "three shapes"
    re.compile(
        r"(?<![a-z0-9])(?:\d+|two|three|four|five|six|seven|eight)\s+"
        r"(?:objects?|items?|things?|shapes?)" + _R,
        re.I,
    ),
]

# NOTE: plain "target" and plain "object" are NOT denied. The system prompt legitimately
# says "locate the target" / "pick up the nearest object". They carry no object data.


def _scan_text(text: str, where: str, command: str | None) -> None:
    if command:
        text = text.replace(command, " ")  # the typed command is the one allowed string
    for pat in DENY_PATTERNS:
        m = pat.search(text)
        if m:
            lo, hi = max(0, m.start() - 30), min(len(text), m.end() + 30)
            raise LeakError(
                f"LEAK in {where}: forbidden term {m.group(0)!r} ...{text[lo:hi]!r}..."
            )


def _walk_strings(obj, path=""):
    """Yield (path, string) for every string value AND every dict key."""
    if isinstance(obj, str):
        yield path, obj
    elif isinstance(obj, dict):
        for k, v in obj.items():
            yield f"{path}.<key {k}>", str(k)
            yield from _walk_strings(v, f"{path}.{k}")
    elif isinstance(obj, (list, tuple)):
        for i, v in enumerate(obj):
            yield from _walk_strings(v, f"{path}[{i}]")


# --------------------------------------------------------------------------- engine responses

STATES = {"Idle", "Locate", "GoToObject", "PickUp", "Carry", "Drop", "Done", "Blocked"}


def _num(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def _int(v):
    return isinstance(v, int) and not isinstance(v, bool)


def _bool(v):
    return isinstance(v, bool)


def _num_or_null(v):
    return v is None or _num(v)


def _state(v):
    return isinstance(v, str) and v in STATES


# Exact keys per endpoint, from plan section 2. Edit ONLY if the whole team agrees to
# change the contract.
SCHEMAS = {
    "/state": {"state": _state, "x": _num, "y": _num, "heading": _num,
               "holding": _bool, "retries": _int},
    "/depth": {"distance": _num_or_null},
    "/move": {"moved": _num, "collided": _bool, "state": _state},
    "/turn": {"turned": _num, "state": _state},
    "/pickup": {"success": _bool},
    "/drop": {"success": _bool, "in_zone": _bool},
    "/run/start": {"ok": _bool},
    "/run/end": {"ok": _bool},
    "/reset": {"ok": _bool},
}

TOOL_TO_ENDPOINT = {
    "state": "/state", "depth": "/depth", "move": "/move", "turn": "/turn",
    "pickup": "/pickup", "drop": "/drop",
}


def check_engine_response(endpoint: str, body) -> None:
    """Validate one engine JSON response against the contract."""
    schema = SCHEMAS.get(endpoint)
    if schema is None:
        raise LeakError(f"{endpoint}: unknown endpoint, no schema (add it to SCHEMAS)")
    if not isinstance(body, dict):
        raise LeakError(f"{endpoint}: response is not a JSON object")
    extra = set(body) - set(schema)
    if extra:
        raise LeakError(f"LEAK {endpoint}: extra keys {sorted(extra)} not in the contract")
    missing = set(schema) - set(body)
    if missing:
        raise LeakError(f"CONTRACT {endpoint}: missing keys {sorted(missing)}")
    for key, ok in schema.items():
        if not ok(body[key]):
            raise LeakError(f"LEAK {endpoint}: bad value for {key!r}: {body[key]!r}")


def check_look_response(content_type: str, body: bytes) -> None:
    """/look must be a bare JPEG."""
    if "image/jpeg" not in (content_type or ""):
        raise LeakError(f"/look: content-type {content_type!r}, expected image/jpeg")
    if not body.startswith(b"\xff\xd8"):
        raise LeakError("/look: body is not a JPEG")


# --------------------------------------------------------------------------- outgoing requests

_ALLOWED_MEDIA = {"image/jpeg", "image/png"}


def _check_blocks(blocks, where: str, command: str | None) -> None:
    if isinstance(blocks, str):
        _scan_text(blocks, where, command)
        return
    for i, b in enumerate(blocks):
        w = f"{where}[{i}]"
        if not isinstance(b, dict):
            _scan_text(str(b), w, command)
            continue
        t = b.get("type")
        if t == "text":
            _scan_text(b.get("text", ""), w, command)
        elif t == "image":
            src = b.get("source", {})
            if src.get("media_type") not in _ALLOWED_MEDIA:
                raise LeakError(f"{w}: image media_type {src.get('media_type')!r}")
        elif t == "tool_result":
            _check_blocks(b.get("content", ""), w + ".content", command)
        else:
            # unknown block type: scan every string in it, to be safe
            for p, s in _walk_strings(b, w):
                _scan_text(s, p, command)


def check_request(request: dict, command: str | None) -> None:
    """
    Call right before client.messages.create(**request). `request` is the kwargs dict
    (system, tools, messages). `command` is the user's typed command (allowlisted).
    """
    system = request.get("system")
    if system:
        _check_blocks(system, "system", command)

    for p, s in _walk_strings(request.get("tools", []), "tools"):
        _scan_text(s, p, command)

    for i, msg in enumerate(request.get("messages", [])):
        if msg.get("role") == "assistant":
            continue  # Claude's own words (observation/reasoning), not engine data
        _check_blocks(msg.get("content", ""), f"messages[{i}]", command)


# --------------------------------------------------------------------------- filenames

_FILE_OK = re.compile(
    r"^(?:(?:frame|step|pov|frame_step)[_-]\d+|\d+)\.(?:png|jpe?g)$|^steps\.jsonl$|^clip\.mp4$",
    re.I,
)


def check_filename(name: str) -> None:
    base = Path(name).name
    for pat in DENY_PATTERNS:
        m = pat.search(base)
        if m:
            raise LeakError(f"LEAK filename {base!r}: forbidden term {m.group(0)!r}")
    if not _FILE_OK.match(base):
        raise LeakError(f"filename {base!r} is not a generic name (step_012.png, frame_step_03.png)")


# --------------------------------------------------------------------------- saved runs

def check_run_dir(run_dir: Path) -> list[str]:
    """Scan a runs/<run_id>/ folder. Returns a list of problems (empty = clean)."""
    problems: list[str] = []

    for f in sorted(run_dir.rglob("*")):
        if f.is_file():
            try:
                check_filename(f.name)
            except LeakError as e:
                problems.append(f"{f.relative_to(run_dir)}: {e}")

    steps = run_dir / "steps.jsonl"
    if not steps.exists():
        problems.append("steps.jsonl missing")
        return problems

    for n, line in enumerate(steps.read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip():
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            problems.append(f"steps.jsonl:{n}: not valid JSON")
            continue
        tool = row.get("tool")
        endpoint = TOOL_TO_ENDPOINT.get(tool)
        if endpoint and isinstance(row.get("result"), dict):
            try:
                check_engine_response(endpoint, row["result"])
            except LeakError as e:
                problems.append(f"steps.jsonl:{n} ({tool}): {e}")
        fp = row.get("frame_path")
        if fp:
            try:
                check_filename(fp)
            except LeakError as e:
                problems.append(f"steps.jsonl:{n}: {e}")
    return problems


# --------------------------------------------------------------------------- self-test

def _expect_ok(fn, *a):
    fn(*a)


def _expect_leak(fn, *a):
    try:
        fn(*a)
    except LeakError:
        return
    raise AssertionError(f"expected LeakError from {fn.__name__}{a}")


def selftest() -> None:
    cmd = "Bring the red cube to the green square"

    # engine responses
    _expect_ok(check_engine_response, "/state", {"state": "Locate", "x": 1.0, "y": 2.0,
               "heading": 90, "holding": False, "retries": 0})
    _expect_leak(check_engine_response, "/state", {"state": "Locate", "x": 1.0, "y": 2.0,
                 "heading": 90, "holding": False, "retries": 0, "target": "obj_3"})
    _expect_ok(check_engine_response, "/pickup", {"success": True})
    _expect_leak(check_engine_response, "/pickup", {"success": True, "picked": "red_cube"})
    _expect_leak(check_engine_response, "/move", {"moved": 0.5, "collided": False,
                 "state": "red"})
    _expect_leak(check_engine_response, "/move", {"error": "hit the blue cube"})
    _expect_ok(check_engine_response, "/depth", {"distance": None})
    _expect_ok(check_engine_response, "/drop", {"success": True, "in_zone": True})
    _expect_ok(check_look_response, "image/jpeg", b"\xff\xd8\xff")
    _expect_leak(check_look_response, "application/json", b"{}")

    # requests
    img = {"type": "image", "source": {"type": "base64", "media_type": "image/jpeg", "data": "AA"}}
    ok_req = dict(
        system="You are a robot with a forward camera. Locate the target and pick up the nearest object.",
        tools=[{"name": "pickup", "description": "Pick up the nearest object in front of you.",
                "input_schema": {"type": "object", "properties": {
                    "observation": {"type": "string"}, "reasoning": {"type": "string"}}}}],
        messages=[
            {"role": "user", "content": [{"type": "text", "text": f"Command: {cmd}"}, img]},
            {"role": "assistant", "content": [{"type": "text",
                                               "text": "I see a red cube on the left."}]},
            {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "t1",
                                          "content": [{"type": "text",
                                                       "text": '{"moved": 0.5, "collided": false, "state": "Locate"}'},
                                                      img]}]},
        ],
    )
    _expect_ok(check_request, ok_req, cmd)

    bad = json.loads(json.dumps(ok_req))
    bad["system"] += " There is a red cube in the room."
    _expect_leak(check_request, bad, cmd)

    bad = json.loads(json.dumps(ok_req))
    bad["tools"][0]["description"] = "Pick up the cube."
    _expect_leak(check_request, bad, cmd)

    bad = json.loads(json.dumps(ok_req))
    bad["messages"][2]["content"][0]["content"][0]["text"] = "picked up blue_cube"
    _expect_leak(check_request, bad, cmd)

    bad = json.loads(json.dumps(ok_req))
    bad["system"] += " There are 5 objects."
    _expect_leak(check_request, bad, cmd)

    # filenames
    _expect_ok(check_filename, "step_012.png")
    _expect_ok(check_filename, "frame_step_03.png")
    _expect_ok(check_filename, "000123.png")
    _expect_leak(check_filename, "red_cube_012.png")
    _expect_leak(check_filename, "screenshot.png")

    print("leak_check selftest: all passed")


# --------------------------------------------------------------------------- CLI

def main() -> int:
    ap = argparse.ArgumentParser(description="Scan runs for object-data leaks.")
    ap.add_argument("run_dirs", nargs="*", help="runs/<run_id> folders to scan")
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()

    if args.selftest:
        selftest()
        return 0
    if not args.run_dirs:
        ap.error("give at least one run folder, or --selftest")

    bad = 0
    for d in args.run_dirs:
        problems = check_run_dir(Path(d))
        if problems:
            bad += 1
            print(f"FAIL {d}")
            for p in problems:
                print("   ", p)
        else:
            print(f"OK   {d}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
