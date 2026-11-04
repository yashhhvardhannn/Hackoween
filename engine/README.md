# Membrane Robot Simulator (Godot 4.x)

## Import
1. Extract `MembraneRobot_Godot_ReadyToImport.zip`.
2. Open Godot Project Manager -> Import.
3. Browse to `MembraneRobot_Godot/project.godot`.
4. Import & Edit, then press F6 or F5.

No external assets or extra plugins are required. `world.tscn` runs `scripts/world_builder.gd`, which creates the complete simulation at runtime.

## Features
- 8m x 8m arena, boundary walls and five coloured primitive physics objects.
- Robot `CharacterBody3D`, physical collision and stop-on-impact movement.
- Three simultaneous views: third-person overview, robot POV (agent view), pickup POV.
- Robot POV is 640x480 and is the only image returned by `/look`.
- Snap pickup, drop, optional throw.
- Movement trail, state and collision display.
- Local HTTP API on `127.0.0.1:8080`.

## Keyboard
W/S move 0.5m; A/D turn 30 degrees; E pickup; Q drop; T throw; R reset; P save `/look` to `user://look.jpg`.

## API
| Method | Path | JSON body | Purpose |
|---|---|---|---|
| GET | `/state` | — | Robot state only |
| GET | `/look` | — | JPEG from robot POV |
| GET | `/depth` | — | Nearest forward distance (metres) or null |
| GET | `/collision` | — | Collision flag |
| POST | `/move` | `{"distance":0.5}` | Move in metres |
| POST | `/turn` | `{"degrees":30}` | Turn in degrees |
| POST | `/pickup` | `{}` | Snap nearest eligible object in reach |
| POST | `/drop` | `{}` | Release; returns in-zone boolean |
| POST | `/throw` | `{"impulse":3.0}` | Optional throw |

PowerShell:
```powershell
Invoke-RestMethod http://127.0.0.1:8080/state
Invoke-WebRequest http://127.0.0.1:8080/look -OutFile look.jpg
Invoke-RestMethod -Uri http://127.0.0.1:8080/move -Method POST -ContentType "application/json" -Body '{"distance":0.5}'
Invoke-RestMethod -Uri http://127.0.0.1:8080/turn -Method POST -ContentType "application/json" -Body '{"degrees":30}'
Invoke-RestMethod -Uri http://127.0.0.1:8080/pickup -Method POST
Invoke-RestMethod -Uri http://127.0.0.1:8080/drop -Method POST
```

Python:
```python
import requests
base = "http://127.0.0.1:8080"
print(requests.get(base + "/state").json())
open("look.jpg", "wb").write(requests.get(base + "/look").content)
print(requests.post(base + "/move", json={"distance": 0.5}).json())
```

## Agent information boundary
`/state` contains only robot pose, heading, holding flag, retries and task state. It does not expose object names, IDs, colours, shapes, positions, counts or target distances. `/look` returns only the robot-mounted forward camera. `/depth` returns only a scalar range to the nearest hit.

## Validation notes
This is a ready-to-import baseline, not a guarantee of passing your exact machine/version without a test run. Test in your installed Godot 4.x and check the Output panel. The HTTP server handles one local request at a time. Engine physics advances while `/move` and `/turn` execute; this baseline does not yet implement a strict externally stepped clock. Collision stops movement and increments a retry counter; agent-side recovery/backoff policy remains to be added.
