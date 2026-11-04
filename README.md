# Hackoween — Membrane Robot Hackathon

A wheeled robot in a Godot scene fetches objects from typed commands. Claude sees only the robot's camera.

See [plan.md](plan.md) for roles, timeline, the API contract (§2) and the repo workflow (§3a).

## Layout
| Folder | Owner | What |
|---|---|---|
| `engine/` | Yash | Godot 4 project: scene, robot, physics, HTTP API on `localhost:8080` (`scripts/world_builder.gd`) |
| `mock_engine/` | Shaun | FastAPI fake engine for agent development |
| `agent/` | Aadya | Claude tool-use loop, prompt, logging, budget guard |
| `tools/`, `docs/` | Abhinav | Leak checker, clip builder, docs ([how Claude finds the object](docs/how_claude_finds_objects.md)) |
| `runs/final/` | Shaun | Committed logs for the hidden-command runs |

## Setup
1. Clone to `C:\dev` (not OneDrive).
2. Copy `.env.example` to `.env` and fill in your key. Never commit `.env`.
3. Work only on your own branch and folders (see plan.md §3a).
4. Install the agent's packages (PowerShell, from the repo root):
   ```powershell
   python -m venv .venv
   .\.venv\Scripts\Activate.ps1
   pip install -r agent/requirements.txt
   ```

## Run
1. Open `engine/` in Godot 4 and press **Play** (F5). The API starts on `localhost:8080`.
   The window shows a third-person view: drag the mouse to orbit, scroll to zoom, press **V** to switch between behind / front / overhead views. The robot's own camera (what Claude sees) is in the top-right corner.
2. In a terminal at the repo root, with the venv active:
   ```powershell
   python -m agent.agent "Bring the yellow cone" --mode claude --reset
   ```
   - `--reset` puts the robot and objects back at their start positions first.
   - `--final` marks a judged run: the budget guard always allows it (practice Claude runs stop at $30 of the $40 budget).
   - Other modes for testing without Claude: `dummy` (fixed moves), `mock` (scripted), `vision` (pixel-colour stand-in), `openrouter` (any OpenRouter model, needs `OPENROUTER_API_KEY`).
3. Each run writes `runs/<run_id>/steps.jsonl` (one line per step: tool, args, result, Claude's observation and reasoning, frame path), the PNG frame Claude saw for each step in `frames/`, and 720p clip frames in `pov/`.

Nobody may touch the keyboard or mouse during a judged run.

## Robot actions (Claude's tools)
`move(distance)` −1.5…1.5 m · `turn(degrees)` −180…180 (positive = right) · `pickup()` reach 0.5 m, ±30° · `drop()` reports `in_zone` · `throw(distance)` 0.5…4 m, reports `in_zone` · `give_up(reason)`. A collision stops the robot, backs it off 0.1 m and enters Blocked; the 4th collision fails the run.
