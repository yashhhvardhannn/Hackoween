"""Checks that an engine follows the HTTP contract in plan.md §2.

Works against the mock engine now and the real Godot engine later:
    python mock_engine/contract_test.py                      # http://localhost:8080
    python mock_engine/contract_test.py --url http://192.168.1.20:8080
    python mock_engine/contract_test.py --fetch               # mock only: scripted full fetch

It checks every endpoint returns exactly the allowed keys with the right types,
that /look is a 640x480 JPEG, and that no reply contains object words.
Saves the camera frame to runs/contract_test/look.jpg so you can open it.
"""

from __future__ import annotations

import argparse
import io
import math
import os
import re
import sys

import requests
from PIL import Image

STATES = {"Idle", "Locate", "GoToObject", "PickUp", "Carry", "Drop", "Done", "Blocked"}
LEAK_WORDS = re.compile(
    r"\b(red|blue|green|yellow|magenta|cube|sphere|cylinder|cone|object|obj|zone_|target|id)\b", re.I
)

failures = 0


def check(cond: bool, label: str):
    global failures
    print(("  PASS  " if cond else "  FAIL  ") + label)
    if not cond:
        failures += 1


def check_json(resp, schema: dict, label: str) -> dict:
    """schema = {key: allowed python types}. Keys must match exactly."""
    check(resp.status_code == 200, f"{label}: HTTP 200 (got {resp.status_code})")
    try:
        data = resp.json()
    except ValueError:
        check(False, f"{label}: reply is JSON")
        return {}
    check(set(data) == set(schema), f"{label}: keys are exactly {sorted(schema)} (got {sorted(data)})")
    for key, types in schema.items():
        if key in data:
            check(isinstance(data[key], types), f"{label}: '{key}' has type {types}")
    check(not LEAK_WORDS.search(resp.text), f"{label}: no object words in reply")
    return data


NUM = (int, float)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--url", default=os.environ.get("ENGINE_URL", "http://localhost:8080"))
    p.add_argument("--fetch", action="store_true", help="mock only: drive a scripted fetch on the default layout")
    args = p.parse_args()
    u = args.url.rstrip("/")
    print(f"Testing engine at {u}\n")

    try:
        requests.get(u + "/state", timeout=3)
    except requests.ConnectionError:
        print(f"Cannot reach {u}. Is the engine running?")
        sys.exit(2)

    print("/reset")
    check_json(requests.post(u + "/reset", json={"layout": "default"}), {"ok": bool}, "/reset")

    print("/state")
    s = check_json(
        requests.get(u + "/state"),
        {"state": str, "x": NUM, "y": NUM, "heading": NUM, "holding": bool, "retries": int},
        "/state",
    )
    check(s.get("state") in STATES, f"/state: state is one of {sorted(STATES)}")

    print("/run/start")
    check_json(requests.post(u + "/run/start", json={"command": "test command", "run_id": "contract"}), {"ok": bool}, "/run/start")

    print("/look")
    r = requests.get(u + "/look")
    check(r.status_code == 200, "/look: HTTP 200")
    check(r.headers.get("content-type", "").startswith("image/jpeg"), "/look: content-type image/jpeg")
    try:
        img = Image.open(io.BytesIO(r.content))
        check(img.format == "JPEG" and img.size == (640, 480), f"/look: JPEG 640x480 (got {img.format} {img.size})")
        os.makedirs("runs/contract_test", exist_ok=True)
        img.save("runs/contract_test/look.jpg")
        print("        saved runs/contract_test/look.jpg")
    except Exception as e:  # noqa: BLE001
        check(False, f"/look: decodable image ({e})")

    print("/depth")
    d = check_json(requests.get(u + "/depth"), {"distance": (int, float, type(None))}, "/depth")
    if isinstance(d.get("distance"), NUM):
        check(0 <= d["distance"] <= 10, "/depth: 0 <= distance <= 10")

    print("/turn")
    check_json(requests.post(u + "/turn", json={"degrees": 30}), {"turned": NUM, "state": str}, "/turn")
    requests.post(u + "/turn", json={"degrees": -30})

    print("/move")
    check_json(requests.post(u + "/move", json={"distance": 0.5}), {"moved": NUM, "collided": bool, "state": str}, "/move")

    print("/move into a wall (expects collided=true)")
    m = check_json(requests.post(u + "/move", json={"distance": 20}), {"moved": NUM, "collided": bool, "state": str}, "/move wall")
    check(m.get("collided") is True, "/move wall: collided is true")
    check(m.get("state") == "Blocked", "/move wall: state is Blocked")

    print("/pickup (nothing in reach)")
    check_json(requests.post(u + "/pickup"), {"success": bool}, "/pickup")

    print("/drop (holding nothing)")
    check_json(requests.post(u + "/drop"), {"success": bool, "in_zone": bool}, "/drop")

    print("/run/end")
    check_json(requests.post(u + "/run/end", json={"outcome": "fail_not_reached"}), {"ok": bool}, "/run/end")

    if args.fetch:
        scripted_fetch(u)

    print(f"\n{'ALL PASSED' if failures == 0 else f'{failures} FAILED'}")
    sys.exit(1 if failures else 0)


def go_to(u: str, tx: float, ty: float, stop_short: float):
    """Turn toward a point and drive up to it, using /state for the pose."""
    s = requests.get(u + "/state").json()
    want = math.degrees(math.atan2(ty - s["y"], tx - s["x"]))
    turn = (want - s["heading"] + 180) % 360 - 180
    requests.post(u + "/turn", json={"degrees": turn})
    dist = math.hypot(tx - s["x"], ty - s["y"]) - stop_short
    return requests.post(u + "/move", json={"distance": dist}).json()


def scripted_fetch(u: str):
    """Mock-only end-to-end check: fetch the cube at (6,3) on the default layout into the zone at (6.5,6.5).
    Uses positions this script knows about the mock layout; the agent never gets these."""
    print("\nScripted fetch (mock default layout)")
    requests.post(u + "/reset", json={"layout": "default"})
    requests.post(u + "/run/start", json={"command": "scripted", "run_id": "scripted"})
    m = go_to(u, 6.0, 3.0, stop_short=0.7)
    check(m["collided"] is False, "drive to object without collision")
    check(requests.post(u + "/pickup").json()["success"] is True, "pickup succeeds")
    check(requests.get(u + "/state").json()["holding"] is True, "/state shows holding")
    requests.get(u + "/look")  # held object should now be visible at the bottom of the frame
    go_to(u, 6.5, 6.5, stop_short=0.45)
    dr = requests.post(u + "/drop").json()
    check(dr == {"success": True, "in_zone": True}, f"drop lands in zone (got {dr})")
    requests.post(u + "/run/end", json={"outcome": "pass"})


if __name__ == "__main__":
    main()
