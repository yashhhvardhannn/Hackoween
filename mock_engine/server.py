"""Mock engine: a stand-in for the Godot engine so the agent can be built and tested early.

It answers exactly the HTTP contract in plan.md §2 on http://localhost:8080.
Behind the scenes it keeps a tiny 2D world (room, objects, drop zone) and draws a
simple camera picture with Pillow, so the agent sees something that looks roughly
like the real thing. Object data never leaves this file: replies contain only
what the contract allows.

Run:  python mock_engine/server.py            (from the repo root, inside .venv)
Options: --port 8080  --layout default|L1|L2  --realtime (sleep like a real robot)
"""

from __future__ import annotations

import argparse
import io
import math
import time
from dataclasses import dataclass

import uvicorn
from fastapi import FastAPI
from fastapi.responses import Response
from PIL import Image, ImageDraw
from pydantic import BaseModel

# ---------------------------------------------------------------------------
# Camera and robot constants (from the brief)
# ---------------------------------------------------------------------------
IMG_W, IMG_H = 640, 480
FOCAL = 320.0                 # pixels; 90° horizontal FOV -> tan(45°) = 1 -> 320 px
CAM_HEIGHT = 0.5              # metres above the floor
CAM_TILT = math.radians(10)   # tilted down
ROBOT_RADIUS = 0.25
PICKUP_REACH = 0.5
PICKUP_ANGLE = 30.0
MOVE_SPEED = 1.0              # m/s  (only used with --realtime)
TURN_SPEED = 90.0             # deg/s
ROOM = 8.0                    # square room from (0,0) to (8,8)
STEP = 0.05                   # collision check resolution while moving
MAX_RETRIES = 3

# World convention: heading 0 = +x, positive = clockwise seen from above.
# We use a y-down map, so forward = (cos h, sin h) and right = (-sin h, cos h).


@dataclass
class Obj:
    kind: str      # cube | sphere | cylinder | cone
    color: tuple   # RGB
    x: float
    y: float
    size: float    # footprint width in metres
    height: float


RED, BLUE, GREEN, YELLOW = (220, 40, 40), (40, 80, 220), (40, 170, 60), (240, 200, 30)
ZONE_COLOR = (230, 40, 200)  # magenta

LAYOUTS = {
    "default": {
        "robot": (4.0, 4.0, 0.0),
        "zone": (6.5, 6.5, 1.0),  # centre x, centre y, side length
        "objects": [
            Obj("cube", RED, 6.0, 3.0, 0.3, 0.3),
            Obj("sphere", RED, 2.0, 2.5, 0.3, 0.3),
            Obj("cube", BLUE, 2.5, 6.0, 0.3, 0.3),
            Obj("cylinder", GREEN, 5.5, 5.0, 0.3, 0.4),
            Obj("cone", YELLOW, 1.5, 4.5, 0.3, 0.35),
        ],
    },
    "L1": {
        "robot": (1.5, 1.5, 45.0),
        "zone": (1.5, 6.5, 1.0),
        "objects": [
            Obj("cube", RED, 4.0, 4.0, 0.3, 0.3),
            Obj("sphere", RED, 6.5, 2.0, 0.3, 0.3),
            Obj("cube", BLUE, 6.0, 6.5, 0.3, 0.3),
            Obj("cylinder", GREEN, 3.0, 6.0, 0.3, 0.4),
            Obj("cone", YELLOW, 5.0, 1.5, 0.3, 0.35),
        ],
    },
    "L2": {
        "robot": (6.5, 4.0, 180.0),
        "zone": (4.0, 1.2, 1.0),
        "objects": [
            Obj("cube", RED, 2.0, 2.0, 0.3, 0.3),
            Obj("sphere", RED, 2.5, 6.5, 0.3, 0.3),
            Obj("cube", BLUE, 4.0, 5.0, 0.3, 0.3),
            Obj("cylinder", GREEN, 1.5, 4.5, 0.3, 0.4),
            Obj("cone", YELLOW, 5.5, 6.5, 0.3, 0.35),
        ],
    },
}


# ---------------------------------------------------------------------------
# World state
# ---------------------------------------------------------------------------
class World:
    def __init__(self, layout: str = "default"):
        self.reset(layout)

    def reset(self, layout: str):
        cfg = LAYOUTS[layout]
        self.x, self.y, self.heading = cfg["robot"]
        zx, zy, zs = cfg["zone"]
        self.zone = (zx - zs / 2, zy - zs / 2, zx + zs / 2, zy + zs / 2)
        self.objects = [Obj(**o.__dict__) for o in cfg["objects"]]
        self.held: Obj | None = None
        self.state = "Idle"
        self.retries = 0

    # --- geometry helpers -------------------------------------------------
    def forward(self):
        h = math.radians(self.heading)
        return math.cos(h), math.sin(h)

    def to_camera(self, px: float, py: float):
        """World point -> (forward, right) metres relative to the camera."""
        fx, fy = self.forward()
        dx, dy = px - self.x, py - self.y
        return dx * fx + dy * fy, dx * -fy + dy * fx

    def collides(self, x: float, y: float) -> bool:
        if not (ROBOT_RADIUS <= x <= ROOM - ROBOT_RADIUS and ROBOT_RADIUS <= y <= ROOM - ROBOT_RADIUS):
            return True
        return any(math.hypot(o.x - x, o.y - y) < ROBOT_RADIUS + o.size / 2 for o in self.objects)

    def in_zone(self, x: float, y: float) -> bool:
        x0, y0, x1, y1 = self.zone
        return x0 <= x <= x1 and y0 <= y <= y1

    # --- actions ----------------------------------------------------------
    def move(self, distance: float):
        fx, fy = self.forward()
        sign = 1 if distance >= 0 else -1
        moved, collided = 0.0, False
        while moved < abs(distance) - 1e-9:
            step = min(STEP, abs(distance) - moved)
            nx, ny = self.x + sign * fx * step, self.y + sign * fy * step
            if self.collides(nx, ny):
                collided = True
                break
            self.x, self.y = nx, ny
            moved += step
        if collided:
            # Brief: stop, back off 0.1 m, report collision, enter Blocked.
            bx, by = self.x - sign * fx * 0.1, self.y - sign * fy * 0.1
            if not self.collides(bx, by):
                self.x, self.y = bx, by
                moved -= 0.1
            self.retries += 1
            self.state = "Done" if self.retries > MAX_RETRIES else "Blocked"
        else:
            self.state = "Carry" if self.held else "GoToObject"
        return round(sign * moved, 3), collided

    def turn(self, degrees: float):
        self.heading = (self.heading + degrees) % 360
        if self.state in ("Idle", "Blocked"):
            self.state = "Locate"
        return degrees

    def pickup(self) -> bool:
        if self.held:
            return False
        self.state = "PickUp"
        best, best_d = None, None
        for o in self.objects:
            f, r = self.to_camera(o.x, o.y)
            d = math.hypot(f, r) - o.size / 2 - ROBOT_RADIUS  # gap from robot front
            ang = abs(math.degrees(math.atan2(r, f)))
            if d <= PICKUP_REACH and ang <= PICKUP_ANGLE and (best_d is None or d < best_d):
                best, best_d = o, d
        if best is None:
            return False
        self.objects.remove(best)
        self.held = best
        self.state = "Carry"
        return True

    def drop(self):
        if not self.held:
            return False, False
        self.state = "Drop"
        fx, fy = self.forward()
        o = self.held
        o.x, o.y = self.x + fx * (ROBOT_RADIUS + 0.2), self.y + fy * (ROBOT_RADIUS + 0.2)
        self.objects.append(o)
        self.held = None
        return True, self.in_zone(o.x, o.y)

    def throw(self, distance):
        """Like drop, but the object lands `distance` m in front of the robot (0.5-4.0)."""
        if not self.held:
            return False, False
        self.state = "Drop"
        d = min(max(distance, 0.5), 4.0)
        fx, fy = self.forward()
        o = self.held
        o.x, o.y = self.x + fx * (ROBOT_RADIUS + d), self.y + fy * (ROBOT_RADIUS + d)
        self.objects.append(o)
        self.held = None
        return True, self.in_zone(o.x, o.y)

    def depth(self):
        """Single ray straight ahead: distance to the nearest thing, max 10 m."""
        fx, fy = self.forward()
        best = None
        for o in self.objects:  # ray vs circle
            f, r = self.to_camera(o.x, o.y)
            rad = o.size / 2
            if f > 0 and abs(r) <= rad:
                d = f - math.sqrt(rad * rad - r * r)
                best = d if best is None else min(best, d)
        for t in self._wall_hits(fx, fy):
            best = t if best is None else min(best, t)
        if best is None or best > 10:
            return None
        return round(max(best, 0.0), 3)

    def _wall_hits(self, dx: float, dy: float):
        hits = []
        if dx > 1e-9:
            hits.append((ROOM - self.x) / dx)
        if dx < -1e-9:
            hits.append(-self.x / dx)
        if dy > 1e-9:
            hits.append((ROOM - self.y) / dy)
        if dy < -1e-9:
            hits.append(-self.y / dy)
        return [min(hits)] if hits else []

    # --- camera rendering --------------------------------------------------
    def project(self, f: float, r: float, z: float):
        """Camera-relative point -> pixel (x, y). Simple pinhole with 10° tilt."""
        px = IMG_W / 2 + FOCAL * r / f
        below = math.atan2(CAM_HEIGHT - z, f)  # angle below horizontal
        py = IMG_H / 2 + FOCAL * math.tan(below - CAM_TILT)
        return px, py

    def render(self) -> bytes:
        img = Image.new("RGB", (IMG_W, IMG_H), (200, 200, 205))  # floor colour
        d = ImageDraw.Draw(img)

        # Walls: cast one ray per 4-pixel column and draw the 1 m tall wall band.
        for col in range(0, IMG_W, 4):
            ang = math.atan((col + 2 - IMG_W / 2) / FOCAL)
            h = math.radians(self.heading) + ang
            t = self._wall_hits(math.cos(h), math.sin(h))[0]
            f = t * math.cos(ang)
            _, y_bottom = self.project(f, 0, 0.0)
            _, y_top = self.project(f, 0, 1.0)
            d.rectangle([col, 0, col + 3, y_top], fill=(150, 170, 190))      # space above wall
            d.rectangle([col, y_top, col + 3, y_bottom], fill=(120, 120, 125))  # wall

        # Drop zone: project the four floor corners.
        x0, y0, x1, y1 = self.zone
        corners = [self.to_camera(cx, cy) for cx, cy in ((x0, y0), (x1, y0), (x1, y1), (x0, y1))]
        if all(f > 0.05 for f, _ in corners):
            d.polygon([self.project(f, r, 0.0) for f, r in corners], fill=ZONE_COLOR)

        # Objects, far to near so close ones are drawn on top.
        visible = []
        for o in self.objects:
            f, r = self.to_camera(o.x, o.y)
            if f > 0.15:
                visible.append((f, r, o))
        for f, r, o in sorted(visible, key=lambda v: -v[0]):
            cx, by = self.project(f, r, 0.0)
            _, ty = self.project(f, r, o.height)
            half = FOCAL * (o.size / 2) / f
            box = [cx - half, ty, cx + half, by]
            if o.kind == "cube" or o.kind == "cylinder":
                d.rectangle(box, fill=o.color, outline=(30, 30, 30))
            elif o.kind == "sphere":
                d.ellipse(box, fill=o.color, outline=(30, 30, 30))
            elif o.kind == "cone":
                d.polygon([(cx - half, by), (cx + half, by), (cx, ty)], fill=o.color, outline=(30, 30, 30))

        # Held object: show it low in front of the camera, like the real engine will.
        if self.held:
            o = self.held
            box = [IMG_W / 2 - 60, IMG_H - 70, IMG_W / 2 + 60, IMG_H + 40]
            if o.kind == "sphere":
                d.ellipse(box, fill=o.color, outline=(30, 30, 30))
            elif o.kind == "cone":
                d.polygon([(box[0], box[3]), (box[2], box[3]), (IMG_W / 2, box[1])], fill=o.color)
            else:
                d.rectangle(box, fill=o.color, outline=(30, 30, 30))

        buf = io.BytesIO()
        img.save(buf, format="JPEG", quality=85)
        return buf.getvalue()


# ---------------------------------------------------------------------------
# HTTP API: exactly plan.md §2, nothing more
# ---------------------------------------------------------------------------
class MoveBody(BaseModel):
    distance: float


class TurnBody(BaseModel):
    degrees: float


class RunStartBody(BaseModel):
    command: str
    run_id: str


class RunEndBody(BaseModel):
    outcome: str


class ResetBody(BaseModel):
    layout: str = "default"


app = FastAPI(title="Hackoween mock engine")
world = World()
REALTIME = False


@app.get("/state")
def get_state():
    return {
        "state": world.state,
        "x": round(world.x, 3),
        "y": round(world.y, 3),
        "heading": round(world.heading, 2),
        "holding": world.held is not None,
        "retries": world.retries,
    }


@app.get("/look")
def look():
    return Response(content=world.render(), media_type="image/jpeg")


@app.get("/depth")
def depth():
    return {"distance": world.depth()}


@app.post("/move")
def move(body: MoveBody):
    if REALTIME:
        time.sleep(abs(body.distance) / MOVE_SPEED)
    moved, collided = world.move(body.distance)
    return {"moved": moved, "collided": collided, "state": world.state}


@app.post("/turn")
def turn(body: TurnBody):
    if REALTIME:
        time.sleep(abs(body.degrees) / TURN_SPEED)
    turned = world.turn(body.degrees)
    return {"turned": turned, "state": world.state}


@app.post("/pickup")
def pickup():
    return {"success": world.pickup()}


@app.post("/drop")
def drop():
    success, in_zone = world.drop()
    return {"success": success, "in_zone": in_zone}


@app.post("/throw")
def throw(body: MoveBody):
    success, in_zone = world.throw(body.distance)
    return {"success": success, "in_zone": in_zone}


@app.post("/run/start")
def run_start(body: RunStartBody):
    # The command is accepted (the real engine uses it for the clip overlay) but never echoed back.
    world.state = "Locate"
    world.retries = 0
    return {"ok": True}


@app.post("/run/end")
def run_end(body: RunEndBody):
    world.state = "Done"
    return {"ok": True}


@app.post("/reset")
def reset(body: ResetBody = ResetBody()):
    if body.layout not in LAYOUTS:
        return {"ok": False}
    world.reset(body.layout)
    return {"ok": True}


def main():
    global REALTIME
    parser = argparse.ArgumentParser(description="Hackoween mock engine")
    parser.add_argument("--port", type=int, default=8080)
    parser.add_argument("--layout", default="default", choices=sorted(LAYOUTS))
    parser.add_argument("--realtime", action="store_true", help="sleep for move/turn like the real robot")
    args = parser.parse_args()
    REALTIME = args.realtime
    world.reset(args.layout)
    print(f"Mock engine on http://localhost:{args.port}  (layout={args.layout}, realtime={REALTIME})")
    uvicorn.run(app, host="0.0.0.0", port=args.port, log_level="warning")


if __name__ == "__main__":
    main()
