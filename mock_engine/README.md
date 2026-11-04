# Mock engine

A pretend version of the Godot engine. It answers the same HTTP requests (plan.md §2) on
`http://localhost:8080`, so the agent can be built and tested before the real engine exists.
It keeps a small 2D room with five shapes and a magenta drop zone, and draws a simple camera picture.
No object information ever appears in its replies.

## Run it (from the repo root, in a VS Code terminal)

```bash
.venv\Scripts\activate
pip install -r mock_engine/requirements.txt
python mock_engine/server.py
```

Options: `--layout default|L1|L2` (three room setups), `--port 8080`, `--realtime` (waits like a real robot: 1 m/s, 90°/s).

## Check it works

In a second terminal:

```bash
python mock_engine/contract_test.py --fetch
```

Every line should say PASS. The camera picture is saved to `runs/contract_test/look.jpg`.

`contract_test.py` also works on the real Godot engine later (leave out `--fetch`, which only knows the mock's layout):

```bash
python mock_engine/contract_test.py --url http://localhost:8080
```

## Differences from the real engine

- Flat 2D drawing instead of 3D. Good enough to test the agent loop and prompts, not for final tuning.
- No 2-second "stuck" timer and no POV clip recording.
- Engine-side state names are approximate.
