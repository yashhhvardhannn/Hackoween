# Connecting Yash's robot to the API (step by step)

Goal: Yash's Godot scene answers `http://localhost:8080` and passes `contract_test.py`.
Then Aadya's agent can drive the real robot. About 20 minutes.

All commands are for the **VS Code terminal (PowerShell)**, from `C:\dev\Hackoween`.

---

## Part 1: Yash, on the Vivobook

### 1. Get the latest code
```powershell
git pull origin main
```

### 2. Register the two API scripts (once)
Godot → **Project → Project Settings → Globals → Autoload**. Add, in this order:

| Name | Path |
|---|---|
| `StateMachine` | `res://scripts/api/state_machine.gd` |
| `ApiServer` | `res://scripts/api/api_server.gd` |

Leave "Enable" ticked. **Do not add `fake_robot.gd`**; that's only for testing without your scene.

### 3. Make your robot script
Copy `engine/scripts/api/robot_template.gd` to `engine/scripts/robot/robot.gd` and attach it to the robot.
It already has every function the API needs, with working versions that were tested with real
3D physics (drive, wall crash, pickup, carry, drop in zone). Change it as much as you like, but
**keep the function names and what they return**.

The template expects this node layout under the robot (rename the `$` paths in the script if yours differ):

```
Robot (CharacterBody3D, robot.gd)
├── CollisionShape3D        capsule, radius 0.25
├── LookViewport (SubViewport 640x480, Update Mode: Always)
│   └── Camera3D            0.5 m above floor, rotated 10° down, FOV 73.74 (= 90° horizontal)
├── PovViewport  (SubViewport 1280x720, Update Mode: Always)
│   └── Camera3D            same position/rotation as above
├── DepthRay (RayCast3D)    target (0, 0, -10)
└── HoldPoint (Marker3D)    low in front of the camera, so the carried object is visible
```

### 4. Groups (Node tab → Groups)
- Each fetchable shape → group **`pickable`**
- The drop zone → an **Area3D** with a **BoxShape3D** collision shape, in group **`drop_zone`**
- The robot adds itself to group `robot` automatically (the template does it in `_ready`)

### 5. Three things that cause confusing bugs
- **Float the robot 1 cm above the floor** (or put the floor on a different collision layer).
  If the capsule touches the floor, every move reports a collision.
- **Heading 0 must face +x.** In Godot that's `rotation_degrees.y = -90` for a robot whose front is −Z.
  The brief's x/y map = Godot's x/z.
- **DepthRay height:** a perfectly level ray at camera height (0.5 m) flies over 0.3 m objects and hits the wall.
  Put it lower (~0.15 m) or tilt it 10° down to match the camera. Ask a mentor which they expect.

### 6. Run and check
Press **Play (F5)** in Godot. The Output panel should show:
```
ApiServer listening on http://localhost:8080
ApiServer: robot 'Robot' found, all 9 functions present. Ready.
```
If it says **missing: ...**, those function names are wrong or absent in `robot.gd`.

Then in a VS Code terminal:
```powershell
.venv\Scripts\activate
```
```powershell
python mock_engine/contract_test.py
```
Every line should say PASS. Open `runs/contract_test/look.jpg` to see what the robot sees.

**If Windows asks whether Godot may use the network, click Allow** (private networks).
That's what lets other laptops connect.

---

## Part 2: connecting from another laptop (Shaun, Aadya)

### 1. Yash finds his laptop's address
```powershell
ipconfig | Select-String "IPv4"
```
It looks like `192.168.1.23`. Both laptops must be on the same Wi-Fi.

### 2. Test from your laptop
```powershell
python mock_engine/contract_test.py --url http://192.168.1.23:8080
```
ALL PASSED means the real engine is reachable and correct.

### 3. Point the agent at it
In your `.env`:
```
ENGINE_URL=http://192.168.1.23:8080
```

**For official runs, engine and agent both run on the Vivobook** with `ENGINE_URL=http://localhost:8080`,
so venue Wi-Fi can't break a judged run.

---

## If something goes wrong

| You see | Meaning | Fix |
|---|---|---|
| `cannot listen on port 8080` | Something else uses the port (often the Python mock engine) | Close the mock engine (`Ctrl+C`), restart Godot |
| `no node in group "robot"` | Robot script not attached, or `_ready` doesn't add the group | Attach `robot.gd` to the robot node |
| `missing: do_move, ...` | Function renamed or deleted | Match the names in `README.md` |
| Every move says `collided: true` | Robot touching the floor | Raise it 1 cm (step 5) |
| `/drop` says `in_zone: false` when it's clearly in | Drop zone isn't an Area3D + BoxShape3D in group `drop_zone` | Fix the zone node (step 4) |
| Another laptop can't connect | Firewall, or different Wi-Fi | Allow Godot in Windows Firewall; check both are on the same network |
