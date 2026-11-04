"""Draws the robot's driving corridor and distance marks onto the camera image.

The model kept clipping objects that sat "a bit left of centre": it did not know how
wide the robot is. This overlay shows it. It is pure camera geometry (robot width,
camera height and tilt); it adds no information about objects, so the leak rule holds.

Anything whose base is between the two cyan lines is in the robot's path for a
straight move. The tick marks show 0.5 / 1 / 1.5 / 2 / 3 m in front of the robot.
"""

from __future__ import annotations

import io
import math

from PIL import Image, ImageDraw

WIDTH, HEIGHT = 640, 480
FOCAL = WIDTH / 2 / math.tan(math.radians(90 / 2))   # 90 degree horizontal field of view
CAM_HEIGHT = 0.5
TILT = math.radians(10)
HALF_PATH = 0.35            # robot half-width 0.28 m + 7 cm margin
COLOUR = (0, 230, 255)      # cyan: not a colour used by any object or the drop zone
TICKS = (0.5, 1.0, 1.5, 2.0, 3.0)


def _project(lateral, forward):
    """Floor point (metres right, metres ahead of the camera) -> pixel (x, y)."""
    z = forward * math.cos(TILT) + CAM_HEIGHT * math.sin(TILT)
    y = CAM_HEIGHT * math.cos(TILT) - forward * math.sin(TILT)
    return WIDTH / 2 + FOCAL * lateral / z, HEIGHT / 2 + FOCAL * y / z


def add_path_guide(image_bytes: bytes) -> bytes:
    image = Image.open(io.BytesIO(image_bytes)).convert("RGB")
    if image.size != (WIDTH, HEIGHT):
        return image_bytes
    draw = ImageDraw.Draw(image)
    near, far = 0.45, 3.0
    for side in (-1, 1):
        draw.line([_project(side * HALF_PATH, near), _project(side * HALF_PATH, far)], fill=COLOUR, width=2)
    for d in TICKS:
        (x1, y), (x2, _) = _project(-HALF_PATH, d), _project(HALF_PATH, d)
        draw.line([(x1 - 8, y), (x1, y)], fill=COLOUR, width=2)
        draw.line([(x2, y), (x2 + 8, y)], fill=COLOUR, width=2)
        draw.text((x2 + 11, y - 6), f"{d:g}m", fill=COLOUR)
    out = io.BytesIO()
    image.save(out, format="JPEG", quality=90)
    return out.getvalue()
