"""Vision brain: a no-API stand-in for Claude, for development and testing only.

It decides each step from the camera picture alone (colour + shape found in the
pixels), exactly like Claude must: no object data comes from the engine.
Use it to test the full pipeline, tune the engine, and produce sample clips
while no API key is available. It is NOT for judged runs: the brief requires Claude.

    python -m agent.agent "Bring the yellow cone" --mode vision --reset

Same interface as ClaudeRobotClient: decide(command, image, depth) -> one action,
then record_result(result).
"""

from __future__ import annotations

import io
import math
from collections import deque

import numpy as np
from PIL import Image

# --- camera geometry (brief: 640x480, 90 deg horizontal FOV, 0.5 m high, ~10 deg down)
W, H = 640, 480
FOCAL = 320.0                         # px: tan(45 deg) = 1 -> 320 px
CAM_HEIGHT = 0.5
CAM_TILT = math.atan(0.18)            # engine aims the camera 0.18 m down per metre (~10.2 deg)

# --- driving rules of thumb (metres / degrees)
AIM_TOLERANCE = 6.0                   # turn first if the target is further off-centre than this
PICKUP_STANDOFF = 0.22                # stop when the object's near edge is this far from the camera
DROP_OFFSET = 0.62                    # carried object sits this far ahead of the camera
MAX_MOVE = 1.5                        # this stand-in keeps to short moves (agent allows up to 3 m)
SEARCH_TURN = 45.0
BOTTOM_CUT = 470                      # blob bottom at/after this row = cut off by the image edge

COLOURS = {                           # hue ranges in degrees
    "red": [(0, 15), (345, 360)],
    "yellow": [(40, 70)],
    "green": [(90, 160)],
    "blue": [(200, 250)],
    "zone": [(290, 330)],             # magenta drop zone
}
SHAPE_WORDS = {
    "cube": "cube", "box": "cube", "block": "cube", "square": "cube",
    "sphere": "sphere", "ball": "sphere", "round": "sphere",
    "cylinder": "cylinder", "tube": "cylinder", "pillar": "cylinder",
    "cone": "cone", "pointy": "cone", "pyramid": "cone",
}


# ---------------------------------------------------------------------------
# Perception: find coloured blobs in the frame
# ---------------------------------------------------------------------------
def _hsv(img: np.ndarray):
    rgb = img.astype(np.float32) / 255.0
    r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]
    mx, mn = rgb.max(-1), rgb.min(-1)
    diff = mx - mn + 1e-6
    h = np.where(mx == r, (g - b) / diff % 6, np.where(mx == g, (b - r) / diff + 2, (r - g) / diff + 4)) * 60
    s = np.where(mx > 0, (mx - mn) / (mx + 1e-6), 0)
    return h, s, mx


def _components(mask: np.ndarray, min_px: int):
    """Connected regions of a (downsampled) boolean mask -> list of pixel-coordinate arrays."""
    seen = np.zeros_like(mask, dtype=bool)
    hh, ww = mask.shape
    out = []
    for y0, x0 in zip(*np.nonzero(mask)):
        if seen[y0, x0]:
            continue
        q = deque([(y0, x0)])
        seen[y0, x0] = True
        pts = []
        while q:
            y, x = q.popleft()
            pts.append((y, x))
            for ny, nx in ((y + 1, x), (y - 1, x), (y, x + 1), (y, x - 1)):
                if 0 <= ny < hh and 0 <= nx < ww and mask[ny, nx] and not seen[ny, nx]:
                    seen[ny, nx] = True
                    q.append((ny, nx))
        if len(pts) >= min_px:
            out.append(np.array(pts))
    return out


def ground_distance(row: float) -> float:
    """Floor distance (m) from the camera to the point seen at image row `row`."""
    below = CAM_TILT + math.atan((row - H / 2) / FOCAL)
    return 99.0 if below <= 0.01 else CAM_HEIGHT / math.tan(below)


def bearing(col: float) -> float:
    """Degrees to turn (+ = right) to centre image column `col`."""
    return math.degrees(math.atan((col - W / 2) / FOCAL))


def find_blobs(image_bytes: bytes):
    img = np.asarray(Image.open(io.BytesIO(image_bytes)).convert("RGB"))[::2, ::2]  # 320x240 is enough
    h, s, v = _hsv(img)
    vivid = (s > 0.45) & (v > 0.25)
    blobs = []
    for colour, ranges in COLOURS.items():
        hue_ok = np.zeros(h.shape, dtype=bool)
        for lo, hi in ranges:
            hue_ok |= (h >= lo) & (h < hi)
        mask = vivid & hue_ok
        if colour == "zone":
            # The carried object can cut the zone into pieces: treat all zone pixels as one region.
            pts_all = np.argwhere(mask)
            groups = [pts_all] if len(pts_all) >= 12 else []
        else:
            groups = _components(mask, min_px=12)
        for pts in groups:
            ys, xs = pts[:, 0] * 2, pts[:, 1] * 2          # back to full-resolution pixels
            top, bottom, left, right = ys.min(), ys.max() + 1, xs.min(), xs.max() + 1
            bw, bh = right - left, bottom - top
            fill = len(pts) * 4 / max(bw * bh, 1)
            dist = ground_distance(bottom)
            if dist >= 99.0:
                continue   # sits entirely above the horizon: sky, not an object on the floor
            blobs.append({
                "colour": colour,
                "shape": _shape(fill, bh / max(bw, 1)) if colour != "zone" else "zone",
                "cx": float(xs.mean()), "top": int(top), "bottom": int(bottom), "mid": float((top + bottom) / 2),
                "width": int(bw), "area": len(pts) * 4, "left": int(left), "right": int(right),
                "cut": bottom >= BOTTOM_CUT,
                "dist": dist,                                   # to the near edge, from the camera
                "height_m": (bh / FOCAL) * dist,                # rough real height
                "bearing": bearing(float(xs.mean())),
            })
    return blobs


def _shape(fill: float, aspect: float) -> str:
    if aspect > 1.45:
        return "cylinder"
    if fill < 0.64:
        return "cone"
    if fill < 0.84:
        return "sphere"
    return "cube"


def describe(b) -> str:
    if b["colour"] == "zone":
        where = "under/just ahead of me" if b["cut"] else f"~{b['dist']:.2f} m"
        return f"drop zone at x={b['cx']:.0f} ({b['bearing']:+.0f} deg), {where}"
    where = "cut off at the bottom (very close)" if b["cut"] else f"~{b['dist']:.2f} m"
    return f"{b['colour']} {b['shape']} at x={b['cx']:.0f} ({b['bearing']:+.0f} deg), {where}"


# ---------------------------------------------------------------------------
# Decision making
# ---------------------------------------------------------------------------
class VisionBrain:
    def __init__(self):
        self.phase = "find_target"
        self.search_turns = 0
        self.relocations = 0
        self.pickup_tries = 0
        self.last_action = None
        self.last_result = {}
        self.last_target = None
        self.avoiding = False
        self.nudged = False
        self.zone_nudged = False
        self.last_move = 0.0
        self.plan = []                    # queued (action, args, reason) steps, e.g. a detour

    # --- command understanding -------------------------------------------
    @staticmethod
    def parse(command: str):
        words = command.lower().replace(",", " ").split()
        colour = next((w for w in words if w in ("red", "blue", "green", "yellow")), None)
        shape = next((SHAPE_WORDS[w] for w in words if w in SHAPE_WORDS), None)
        tallest = any(w.startswith("tall") for w in words)
        return colour, shape, tallest

    def pick_target(self, command: str, blobs):
        colour, shape, tallest = self.parse(command)
        cands = [b for b in blobs if b["colour"] != "zone"]
        if colour:
            cands = [b for b in cands if b["colour"] == colour]
        if shape:
            cands = [b for b in cands if b["shape"] == shape]
        if not cands:
            return None
        if tallest:
            return max(cands, key=lambda b: b["height_m"])
        return max(cands, key=lambda b: b["area"])  # nearest/biggest match

    # --- one step ----------------------------------------------------------
    def decide(self, command, image_bytes, depth=None):
        blobs = find_blobs(image_bytes)
        seen = "; ".join(describe(b) for b in blobs) or "no coloured objects"
        res = self.last_result or {}

        # outcome of the previous action
        if self.last_action == "pickup":
            if res.get("success"):
                self.phase, self.search_turns, self.relocations = "find_zone", 0, 0
            else:
                self.pickup_tries += 1
        if self.last_action == "drop" and res.get("success") and not res.get("in_zone"):
            self.phase, self.pickup_tries = "find_target", 0      # dropped short: pick it up again

        if self.plan and not res.get("collided"):
            name, args, why = self.plan.pop(0)
            return self._act(name, seen, why, **args)
        self.plan = []

        if self.phase == "find_target":
            return self._go_to_target(command, blobs, seen, res)
        return self._go_to_zone(blobs, seen, res)

    def _act(self, name, seen, why, **args):
        self.last_action = name
        if name == "move":
            self.last_move = args.get("distance", 0.0)
        args.update({"observation": f"I see: {seen}", "reasoning": why})
        return {"name": name, "arguments": args, "input_tokens": 0, "output_tokens": 0}

    def _search(self, seen, what, depth_hint=None):
        self.search_turns += 1
        if self.search_turns > 360 / SEARCH_TURN:              # full circle without a sighting
            self.search_turns = 0
            self.relocations += 1
            if self.relocations > 2:
                self.last_action = "give_up"
                return {"name": "give_up", "arguments": {"reason": f"Could not find {what} after searching from 3 places."},
                        "input_tokens": 0, "output_tokens": 0}
            return self._act("move", seen, f"Searched a full circle without seeing {what}; moving to a new spot.", distance=1.0)
        return self._act("turn", seen, f"{what} not in view; turning {SEARCH_TURN:.0f} deg to search.", degrees=SEARCH_TURN)

    def _obstacle(self, blobs, target, max_dist):
        for b in blobs:
            if b is target or b["colour"] == "zone":
                continue
            if abs(b["bearing"]) < 14 and b["dist"] < max_dist - 0.25 and b["dist"] < 2.5:
                return b
        return None

    def _go_to_target(self, command, blobs, seen, res):
        t = self.pick_target(command, blobs)

        if self.last_action == "move" and res.get("collided"):
            if self.last_target and (self.last_target["cut"] or self.last_target["dist"] < 0.5):
                return self._act("pickup", seen, "Bumped into the target while approaching it, so it is within reach; picking up.")
            self.avoiding = False
            side = 40 if (self.last_target is None or self.last_target["bearing"] <= 0) else -40
            self.plan = [("turn", {"degrees": side}, "Detour around the obstacle I hit."),
                         ("move", {"distance": 0.7}, "Detour: driving past the obstacle."),
                         ("turn", {"degrees": -side}, "Detour done; turning back toward the target area.")]
            return self._act("move", seen, "Collided with something that is not the target; backing up 0.3 m, then going around it.", distance=-0.3)

        if t is None:
            reached = (self.last_target is not None and self.last_action == "move" and not res.get("collided")
                       and (self.last_target["cut"] or self.last_target["dist"] - self.last_move <= 0.45))
            if reached and abs(self.last_target["bearing"]) <= 12:
                self.nudged = True
                return self._act("pickup", seen, "The target dropped out of view right after an approach that should have reached it; it is directly in front, so picking up.")
            if self.last_action == "pickup" and not res.get("success") and self.last_target is not None:
                return self._act("move", seen, "Pickup missed and the target is out of view; backing up 0.4 m to see it again.", distance=-0.4)
            if self.nudged and self.last_action == "move" and not res.get("collided"):
                return self._act("pickup", seen, "The target was just below the view after moving into reach, so it is directly in front; picking up.")
            self.last_target = None
            return self._search(seen, "the requested object")
        self.search_turns = 0
        self.last_target = t
        what = describe(t)

        if self.pickup_tries >= 3:
            self.pickup_tries = 0
            return self._act("move", seen, f"Pickup failed 3 times; backing up to re-approach the {t['colour']} {t['shape']}.", distance=-0.3)

        if abs(t["bearing"]) > AIM_TOLERANCE and (not t["cut"] or abs(t["bearing"]) > 12):
            return self._act("turn", seen, f"Target is {what}; turning to centre it.", degrees=round(t["bearing"], 1))

        if t["cut"] or t["dist"] <= PICKUP_STANDOFF + 0.05:
            if self.last_action == "pickup" and not res.get("success"):
                return self._act("move", seen, "Pickup missed; edging 0.1 m closer.", distance=0.1)
            if t["cut"] and not self.nudged:
                # Bottom just left the frame: the near edge is ~0.45 m away, just outside reach.
                self.nudged = True
                return self._act("move", seen, f"Target {what}; moving 0.2 m into reach.", distance=0.2)
            return self._act("pickup", seen, f"Target {what} is centred and within reach; picking up.")
        self.nudged = False

        obstacle = self._obstacle(blobs, t, t["dist"])
        if obstacle and not self.avoiding:
            self.avoiding = True
            side = -35 if obstacle["bearing"] >= 0 else 35
            return self._act("turn", seen, f"{describe(obstacle)} blocks the way to the target; turning {side:+d} deg to go around.", degrees=side)
        if self.avoiding and obstacle is None:
            self.avoiding = False

        step = min(MAX_MOVE, t["dist"] - PICKUP_STANDOFF)
        if self.avoiding:
            self.avoiding = False
            step = min(step, 0.6)
        return self._act("move", seen, f"Target {what} is centred; driving {step:.2f} m toward it.", distance=round(step, 2))

    def _go_to_zone(self, blobs, seen, res):
        zone = next((b for b in blobs if b["colour"] == "zone"), None)

        if self.last_action == "move" and res.get("collided"):
            return self._act("move", seen, "Collided while carrying; backing up 0.3 m before re-aiming.", distance=-0.3)
        if zone is None:
            self.zone_nudged = False
            return self._search(seen, "the drop zone")
        self.search_turns = 0

        # Aim at the middle of the zone's left/right edges: steadier than the pixel average,
        # which jumps around when the zone is close and seen at an angle.
        centre_col = (zone["left"] + zone["right"]) / 2
        aim = bearing(centre_col)
        far_edge = ground_distance(zone["top"])
        spans_ahead = zone["left"] < W / 2 - 20 and zone["right"] > W / 2 + 20

        if zone["cut"] and spans_ahead:
            # The zone runs under the camera view and covers straight ahead.
            if self.zone_nudged:
                return self._act("drop", seen, "Moved onto the drop zone; the carried object is over it. Dropping.")
            if far_edge >= 0.9:
                self.zone_nudged = True
                return self._act("move", seen, f"Drop zone covers straight ahead (far edge ~{far_edge:.2f} m); moving 0.3 m onto it.", distance=0.3)
            return self._act("move", seen, "Drop zone is mostly behind the drop point; backing up 0.3 m.", distance=-0.3)

        tolerance = AIM_TOLERANCE if not zone["cut"] and zone["dist"] > 1.2 else 15.0
        if abs(aim) > tolerance:
            return self._act("turn", seen, f"Drop zone at {aim:+.0f} deg; turning toward it.", degrees=round(aim * (1.0 if tolerance == AIM_TOLERANCE else 0.6), 1))

        to_centre = ground_distance(zone["mid"]) if zone["mid"] < BOTTOM_CUT else 0.3
        step = min(MAX_MOVE, max(0.2, to_centre - DROP_OFFSET))
        return self._act("move", seen, f"Drop zone centre ~{to_centre:.2f} m ahead; driving {step:.2f} m.", distance=round(step, 2))

    def record_result(self, result):
        self.last_result = result or {}
