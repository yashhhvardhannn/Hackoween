# Hackoween — Membrane Robot Hackathon

A wheeled robot in a Godot scene fetches objects from typed commands. Claude sees only the robot's camera.

See [plan.md](plan.md) for roles, timeline, the API contract (§2) and the repo workflow (§3a).

## Layout
| Folder | Owner | What |
|---|---|---|
| `engine/` | Yash (scene, robot), Shaun (`scripts/api/`) | Godot 4 project, HTTP API on `localhost:8080` |
| `mock_engine/` | Shaun | FastAPI fake engine for agent development |
| `agent/` | Aadya | Claude tool-use loop, logging, budget |
| `tools/`, `docs/` | Abhinav | Clip builder, leak checker, log viewer, docs |
| `runs/final/` | Shaun | Committed logs for the hidden-command runs |

## Setup
1. Clone to `C:\dev` (not OneDrive).
2. Copy `.env.example` to `.env` and fill in your key. Never commit `.env`.
3. Work only on your own branch and folders (see plan.md §3a).
