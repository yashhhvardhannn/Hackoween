# Engine API scripts (owner: Shaun)

| File | What it does |
|---|---|
| `api_server.gd` | Autoload `ApiServer`. HTTP server on port 8080 that answers plan.md §2. Builds every reply from an explicit key list, so no object data can leak. |
| `state_machine.gd` | Autoload `StateMachine`. Tracks Idle → Locate → GoToObject → PickUp → Carry → Drop → Done, plus Blocked. Ends the run with `fail_collision` after the 4th collision (3 retries). |
| `fake_robot.gd` | Stand-in robot for testing without the real scene. **Not registered in the real game.** |

## What the real robot must provide (Yash)

Put the robot node in group `"robot"` and give its script these functions. `api_server.gd` calls only these:

```gdscript
func do_move(distance: float) -> Dictionary   # may await; {"moved": float, "collided": bool}
                                               # report "no movement for 2 s" as collided = true
func do_turn(degrees: float) -> Dictionary    # may await; {"turned": float}
func do_pickup() -> bool
func do_drop() -> Dictionary                  # {"success": bool, "in_zone": bool}
func get_pose() -> Dictionary                 # {"x", "y", "heading", "holding"}
func get_look_jpeg() -> PackedByteArray       # 640x480 JPEG
func get_depth() -> Variant                   # float metres, or null
func start_capture(run_id: String, command: String) -> void
func stop_capture() -> void
func reset_layout(layout: String) -> void     # optional, used by POST /reset
```

Extra keys in the robot's return values are ignored, never sent to the agent.

## Testing without the real game

A small practice Godot project outside the repo links to this folder, so it runs these exact files.
One-time setup from Git Bash:

```bash
mkdir -p /c/dev/api_sandbox/scripts
cmd //c "mklink /J C:\\dev\\api_sandbox\\scripts\\api C:\\dev\\Hackoween\\engine\\scripts\\api"
```

Then create `C:\dev\api_sandbox\project.godot`:

```ini
config_version=5

[application]
config/name="API Sandbox"
run/main_scene="res://main.tscn"

[autoload]
FakeRobot="*res://scripts/api/fake_robot.gd"
StateMachine="*res://scripts/api/state_machine.gd"
ApiServer="*res://scripts/api/api_server.gd"
```

and `C:\dev\api_sandbox\main.tscn`:

```ini
[gd_scene format=3]

[node name="Main" type="Node"]
```

Run it (stop the Python mock engine first, since both use port 8080), then run the checker from the repo root:

```bash
Godot_v4.7.2-stable_win64_console.exe --headless --path C:/dev/api_sandbox
```

```bash
python mock_engine/contract_test.py
```
