# Hackoween — Membrane Robot Hackathon: Roles & Execution Plan

> Replaces the earlier `plan.md`. That one had the right priorities but no owners. This one says who does what, on which laptop, by what time.
>
> **Clock assumption:** H0 = **4:00 PM Wed Nov 4**, end = **4:00 PM Thu Nov 5**. If you started at a different time, shift the clock column. The brief's gates (H14 sign-off, H18 hidden commands, H20 upload) are counted from the official start.

---

## 0. TL;DR

| Who | Laptop | Role | One-line mission |
|---|---|---|---|
| **You** (Galaxy Book, BOOK-I9KHMK2S19) | Core Ultra 5 226V · **Arc 130V (Xe2)** · 16 GB LPDDR5X-8533 | **Engine Lead + Demo Machine** | Build the 3D world, robot, camera and physics. This laptop runs every official demo and hidden-command run. |
| **Aadya** (Dell 14S) | Core Ultra 7 355 · Intel Graphics (Xe3) · 16 GB @ 7467 | **Agent Lead (Claude brain)** | Own the Python tool-use loop, the system prompt, logging and the budget. Keep a full copy of the stack as the **hot-spare demo machine**. |
| **Yash** (ASUS Vivobook S14) | Core Ultra 5 225H (14 cores) · weak iGPU · 16 GB @ 5600 | **API & State-Machine Engineer + Repo Captain** | Write the engine's HTTP server and state machine as separate scripts, build the mock engine at H0, own `main` and merges, then lead the stretch goal. |
| **Abhinav** (ThinkPad T14 G1) | Ryzen 5 PRO 4650U · Vega · 16 GB @ 3200 · **only ~34 GB free** | **Phase 2, QA & Compliance Lead** | Build the clip pipeline, the leak checker, the log viewer, the test-command bank, docs and submission, and be the mentor liaison. Never needs to run the engine. |

**Why these assignments:**
- **Rendering at 30 FPS plus 720p POV capture is the only GPU-heavy job.** Arc 130V is clearly the best iGPU of the four, so the engine and the demos live on the Galaxy Book.
- **Ultra 7 355 is the newest, fastest CPU, with the second-best GPU and RAM.** It can run engine + agent together, so it is the backup demo box if the Galaxy Book dies.
- **225H has lots of CPU cores but a weak GPU.** That suits code-only engine work (HTTP server, state machine), Python and merges, not render tuning.
- **The 4650U is a 2020 chip with 3200 MT/s RAM and a nearly full disk.** Give it work that needs only Python and ffmpeg: clip building, leak lint, QA, docs. It has the most to contribute where nothing heavy runs.

---

## 1. What wins (from the brief)

| Weight | Component | What it really means for us |
|---|---|---|
| **40** | Phase 1: Fetch works | 2 live judge commands, pass/fail, **plus directness** (no wandering) |
| **25** | Phase 1: Image-driven agent | Judges read the logs. They want Claude finding objects from pixels, reasoning, recovering from collisions. **Any object-data leak = 0 on both Phase 1 parts (65 pts).** |
| **20** | Phase 2: User verdict | 3 clips × ≥30 raters. "Correct object reached zone?" + "Nothing wrong" share. |
| **15** | Stretch | Any one stretch goal working in the demo. |

**Strategic calls (decided, don't re-argue them):**
1. **Engine = Godot 4.x** (Compatibility renderer). It's a ~150 MB download, runs well on all our iGPUs, needs no account or licence, and has a built-in JPEG encoder, easy pausing and simple physics. Unity is too heavy for Abhinav's disk and slow to iterate. **Fallback:** if the Godot HTTP server isn't answering curl by **H3 (7 PM)**, switch to Python + PyBullet + FastAPI on Yash's machine.
2. **No `go_to` tool, ever.** Claude drives with `move` + `turn` only, using the camera-geometry cheat sheet (§5.3). That is better for directness and it **earns the stretch goal "Claude plans the full path with move/turn only" for free.** Abhinav confirms with a mentor by H2 that this counts.
3. **Backup stretch goal:** multi-view reasoning ("cube farthest from the green square"). Our agent already scans and keeps notes, so it's cheap to add.
4. **Model:** organizer-provided **Sonnet 5.5** (`claude-sonnet-5-5`) for real runs, **Haiku 5.5** (`claude-haiku-5-5`) or a dummy agent for plumbing. Turn on prompt caching from the first commit.
5. **POV clips are built from engine-time frames.** The engine is frozen while Claude thinks, so we only capture frames during `/move` and `/turn`. Wall-clock runs last 1–2 minutes, but engine-time is about 10–20 s. That is the only way to hit the 10–20 s rule without cutting.

---

## 2. Interface contract (freeze this at H0:30, everyone builds against it)

Base URL `http://localhost:8080`. Units: metres and degrees. Heading 0 = +x, positive = clockwise from above. All responses are JSON except `/look`.

| Endpoint | Request | Response (exact keys) |
|---|---|---|
| `GET /state` | — | `{"state":"Idle|Locate|GoToObject|PickUp|Carry|Drop|Done|Blocked","x":f,"y":f,"heading":f,"holding":bool,"retries":int}` **Nothing else.** |
| `GET /look` | — | `image/jpeg`, 640×480, 90° HFOV, camera 0.5 m high, tilted 10° down |
| `GET /depth` | — | `{"distance": f or null}` (max 10 m, centre ray) |
| `POST /move` | `{"distance": f}` | `{"moved": f, "collided": bool, "state": "..."}` |
| `POST /turn` | `{"degrees": f}` | `{"turned": f, "state": "..."}` |
| `POST /pickup` | — | `{"success": bool}` (reach 0.5 m, ±30°) |
| `POST /drop` | — | `{"success": bool, "in_zone": bool}` |
| `POST /run/start` | `{"command": str, "run_id": str}` | `{"ok": true}`. Leaves Idle and starts POV frame capture into `runs/<run_id>/pov/`. **The command is stored only for the overlay and never echoed back.** |
| `POST /run/end` | `{"outcome": str}` | `{"ok": true}`. Enters Done and stops capture. |
| `POST /reset` | `{"layout": "default|L1|L2|..."}` | `{"ok": true}`. Respawns the scene (dev only, never during a judged run). |

**Leak rule baked into the contract:** no endpoint the agent calls may contain an object name, colour, shape, ID, position, count, or drop-zone coordinate. That includes error messages ("picked up red_cube" counts as a leak). Yash writes the responses and Abhinav's `leak_check.py` (§6) enforces them.

---

## 3. Repo layout (Yash creates at H0:15)

```
Hackoween/
├── engine/                  # Godot project
│   ├── scenes/world.tscn    # YOU own: room, objects, drop zone, robot, cameras
│   ├── scripts/robot.gd     # YOU own: motion, collision, pickup attach, frame capture
│   ├── scripts/api_server.gd    # YASH owns: TCPServer HTTP on :8080, routing, JSON
│   └── scripts/state_machine.gd # YASH owns: states, Blocked/retry logic, outcomes
├── mock_engine/server.py    # YASH: FastAPI fake engine serving canned JPEGs (H0–H4)
├── agent/
│   ├── agent.py             # AADYA: CLI entry `python agent.py "Bring the red cube"`
│   ├── tools.py             # AADYA: tool schemas + engine HTTP calls
│   ├── prompts.py           # AADYA: system prompt + geometry cheat sheet
│   ├── logger.py            # AADYA: JSONL + PNG frames
│   └── budget.py            # AADYA: token→$ tracker, run counter, hard stops
├── tools/
│   ├── leak_check.py        # ABHINAV: scans every Claude request + engine responses
│   ├── make_clip.py         # ABHINAV: pov frames → 720p MP4, overlay, duration fit
│   ├── log_viewer.html      # ABHINAV: step-by-step replay of JSONL + frames for judges
│   └── qa_sheet.csv         # ABHINAV: every test run, command, outcome, cost
├── runs/<run_id>/           # steps.jsonl, frames/step_XX.png, pov/*.png, clip.mp4
├── docs/how_claude_finds_objects.md   # ABHINAV (with Aadya): the required paragraph
└── .env.example             # ANTHROPIC_API_KEY=… (real .env is gitignored, NEVER commit)
```

**Git rules:** one branch per person (`engine`, `api`, `agent`, `tools`). Yash merges to `main` at every sync point. Godot `.tscn` files merge badly, so **only You edit `world.tscn`**. Yash's scripts attach to it through an autoload, so you never both touch the scene file.

---

## 4. Timeline (owners per block)

Syncs: **10-minute stand-up at every even hour**, plus extra ones at H0:30 and H13. Each person says: done / next / blocked. Yash merges after each one.

### H0–H4 (4 PM → 8 PM) — Foundation, all four working in parallel

| Person | Deliverables by H4 |
|---|---|
| **You** | Godot installed. 8×8 m room with 4 walls (1 m tall, distinct grey). 5 primitives about 0.3 m each: **red cube, red sphere, blue cube, green cylinder (tall, 0.6 m), yellow cone**, so two share a colour, two share a shape, and one is clearly tallest. Drop zone: a 1×1 m **bright magenta** flat square, a colour no object uses. Robot capsule + forward camera matching the spec (0.5 m, 10° down, 90° HFOV, 640×480 SubViewport). A second **1280×720 POV SubViewport** with the same pose, for clips. Bright, even lighting and a light floor. |
| **Yash** | Repo scaffold (H0:15). `mock_engine/server.py` (H1) so Aadya can start at once: it serves 5–10 hand-captured screenshots and fake move/turn replies. Then `api_server.gd` (GDScript `TCPServer` + minimal HTTP/1.1 parser, JSON body, `image/jpeg` response via `Image.save_jpg_to_buffer()`), with all endpoints from §2 answering curl by **H3**. |
| **Aadya** | `agent.py` loop against the mock engine: command → `/look` → Claude (Haiku) → one tool call → engine → log. JSONL + PNG logging from the first run. `tool_choice={"type":"any"}` and `disable_parallel_tool_use=true` so each step is **exactly one tool call**. Prompt caching on system + tools. `budget.py` counting $ from `usage`. |
| **Abhinav** | Clear ~10 GB of disk space. Install Python, ffmpeg and Godot (just to open the project). By H2: ask a mentor whether the "move/turn-only" stretch counts and which optional sensors are already approved. Write `leak_check.py` v1 (§6). Write `qa_sheet.csv` and the **test-command bank** (§7). Start `make_clip.py` on dummy PNGs. |

**H4 exit gate:** move, turn, look, depth, pickup and drop work from curl against the real Godot engine on your machine. The agent runs end-to-end against the mock.

### H4–H8 (8 PM → midnight) — First real fetches

| Person | Work |
|---|---|
| **You** | `robot.gd`: kinematic motion at 1 m/s and 90°/s, stepped per physics frame, with the HTTP reply returned when the motion completes. Collision: stop, back off 0.1 m, `collided=true`. Snap pickup: reparent the nearest object within 0.5 m and ±30°, and **mount it low in front of the camera so it stays visible in the POV** (raters need to see what we carry). Drop: unparent and check whether it landed in the zone. While no move or turn is running, robot motion is frozen (the scene can keep rendering). POV frame dump: write every rendered frame of the 720p viewport to `runs/<id>/pov/` only during move and turn. |
| **Yash** | `state_machine.gd`: Idle → Locate → GoToObject → PickUp → Carry → Drop → Done, plus Blocked (on a collision **or 2 s engine-time without movement during a move**), back off/turn/retry, and fail after 3 retries. Outcomes: `pass`, `fail_not_reached`, `fail_collision`. (`fail_wrong_object` is judged offline in the QA sheet, because the engine must never know the target.) `/run/start` and `/run/end`, `/reset` with 3 layouts. Integration on your machine at H6. |
| **Aadya** | Switch to the real engine (H6). System prompt v1 (§5). First **Sonnet** runs on easy commands ("Bring the yellow cone"). Tune: search pattern, approach, and the final approach using depth. Add `observation` + `reasoning` fields to every tool call (§5.2). **Goal: 2 passes by H8.** |
| **Abhinav** | `leak_check.py` hooked into the agent as a pre-send assertion (it raises before any request goes to Claude). `log_viewer.html`: a single page that loads `steps.jsonl`, shows frame → Claude reasoning → tool call → result, with arrow keys to step. `make_clip.py` working on real POV frames. Log every run in the QA sheet. |

**H8 exit gate:** 2 different commands pass end to end with no human touch. The logs show Claude naming what it sees.

### H8–H12 (midnight → 4 AM) — Robustness and directness

| Person | Work |
|---|---|
| **You** | Fix whatever QA finds: physics glitches, objects clipping into walls, a camera that's too dark. Lock the visual look. Keep the scene **deterministic** per layout. |
| **Aadya** | Directness pass: a scan strategy (turn 60° per look, at most 6 looks) and turn-then-move in big confident steps from the geometry table. For **superlative or relational commands** ("tallest", "round red thing", "farthest from"), do a full 360° scan with notes **before** committing (§5.4). Collision recovery wording in the logs. Steps per run under 25. |
| **Yash** | Sleeps **2:00–5:00 AM (H10–H13)**. Before that: hardening (concurrent request safety, timeouts, `/reset`), then start the **stretch prep**: a `layout: obstacles` with one wall segment blocking the straight path. Dormant unless the core is solid. |
| **Abhinav** | Sleeps **2:00–5:00 AM (H10–H13)**. Before that: runs the test bank (10+ commands × 3 layouts) on Aadya's spare machine, files failures as GitHub issues, runs `leak_check.py` over all logs, and drafts `docs/how_claude_finds_objects.md`. |

### H12–H14 (4 AM → 6 AM) — Phase 1 sign-off

- **H12:** full dress rehearsal of the official check. **3 different commands, pass, nobody touches keyboard or mouse during the run.** Abhinav opens the log viewer to show "found from pixels".
- **H13:** book the mentor and demo on the **Galaxy Book**. Aadya's Dell is running the identical commit as hot spare.
- **H14 (6 AM): sign-off.** Get the Phase 2 API key and guide. **Freeze the core**: from now on, core-path changes need a passing 3-command regression first.

### H14–H18 (6 AM → 10 AM) — Phase 2 pipeline and stretch

| Person | Work |
|---|---|
| **You + Aadya** | Sleep **6:30–9:00 AM (H14.5–H17)**. Non-negotiable. You two run the hidden commands. |
| **Abhinav** | Read the feedback API guide and script the upload (`tools/upload_clip.py`). Finish `make_clip.py`: 720p MP4, no audio, command overlay for the first 2 s (`ffmpeg drawtext`), **assert 10 s ≤ duration ≤ 20 s** (if over, speed up with `setpts` to fit 19 s; if under, hold the last frame showing the object in the zone). Check: no team name, logo or code on screen. Produce 3 rehearsal clips. |
| **Yash** | Stretch: show the obstacle layout passing with move/turn only (documents the stretch goal). If that's solid by H17, add the multi-view command "Bring the cube farthest from the magenta square" as a second showcase. Runs on his own machine (engine at low settings is fine). |
| **H17 (9 AM)** | Everyone up. Regression: 3 commands on the Galaxy Book. Check the budget. |

### H18–H20 (10 AM → noon) — Hidden commands (hard gate)

1. **H18:** judges publish 3 commands. Aadya reads each one aloud. If any is relational or superlative, confirm the agent's scan mode is on.
2. **You** run each command **exactly once** on the Galaxy Book. Hands off the keyboard after pressing Enter.
3. **Abhinav** builds each clip immediately after each run, verifies it (duration, overlay, no branding), and uploads it. **Target: all 3 uploaded by 11:15 AM (H19:15)**, leaving a 45-minute buffer before the H20 hard zero.
4. **Yash** commits `runs/<hidden_1..3>/steps.jsonl` + frames to the repo (they're required submission items).

### H20–H24 (noon → 4 PM) — Results, polish, demo

- ~H20:45: pulse results arrive. If time allows, **Aadya** makes one targeted behaviour fix (e.g. "too slow" → bigger steps) and records before/after clips. That's a third possible stretch goal.
- **Abhinav:** submission checklist (§8), README, demo slot booked.
- **You + Aadya:** practise the live judge demo twice and stop touching code at **3:00 PM**.
- **Yash:** final merge, make the repo public, tag `v1-final`.

---

## 5. Agent design (Aadya's spec)

### 5.1 Loop
```
start: POST /run/start → GET /look
each step (max 60, soft 25):
   messages = [system (cached), tools (cached),
               user: command + one-line text history of previous steps
                     + LATEST frame only (image block) + depth + last result/collided flag]
   → Claude returns exactly 1 tool_use
   → execute against engine → if move/turn: GET /look (one image per move/turn, never two in a row)
   → log JSONL line {step, timestamp, tool, args, result, frame_path, observation, reasoning, usage, cost}
stop on: drop with in_zone=true (pass) | 3 retries exhausted | 60 steps → POST /run/end
```

### 5.2 Tools (no `look`, no `go_to`, no object info in descriptions)
- `turn(degrees, observation, reasoning)`: positive is right.
- `move(distance, observation, reasoning)`: negative reverses.
- `pickup(observation, reasoning)`
- `drop(observation, reasoning)`
- `give_up(reason)`

`observation` = what Claude sees in this frame, `reasoning` = why it chose this action. They cost almost nothing and are **the evidence judges read for the 25 points**.

### 5.3 Camera geometry cheat sheet (goes in the system prompt; it's camera intrinsics, not object data)
Ask Claude to locate the **bottom-centre pixel** of the target, then:

**Bearing from column x** (`atan((x−320)/320)`; turn this many degrees, + = right):

| x | 0 | 80 | 160 | 240 | 320 | 400 | 480 | 560 | 640 |
|---|---|---|---|---|---|---|---|---|---|
| deg | −45 | −37 | −27 | −14 | 0 | +14 | +27 | +37 | +45 |

**Floor distance from row y of the object's bottom** (camera 0.5 m, 10° down, VFOV ≈ 73.7°):

| y | ≤184 | 210 | 225 | 240 | 270 | 300 | 360 | 420 | 480 |
|---|---|---|---|---|---|---|---|---|---|
| metres | beyond horizon | 6.2 | 3.9 | 2.8 | 1.8 | 1.3 | 0.85 | 0.6 | 0.47 |

Policy: turn to centre the target, then `move(distance − 0.4)`, then look again. Use depth to finish (pick up when depth < 0.45 and the target is centred). Optional extra: draw a faint 80-px labelled grid on the image *sent to Claude* (keep the raw PNG for logs). It makes pixel estimates much more accurate.

### 5.4 Prompt rules
- "You only know about objects from the image. If you can't see the target, search: turn 60° and look."
- Superlatives and relations ("tallest", "farthest from", "round red"): **scan all 6 headings first** and write notes per heading in `observation`, then pick and justify the choice in `reasoning`.
- Drop zone: the same search procedure. Remember its heading from earlier scans in the notes.
- After `collided=true`: turn ±45° away, move 0.5 m, re-look, re-plan.

### 5.5 Budget ($40 target, alert at $30)
- About $0.009/step and about 150 runs total. `budget.py` prints running $ after every run and **refuses to start a Sonnet run past $34** without the `--force` flag.
- Plumbing and prompt-syntax testing on Haiku or the mock only.
- **At 120 runs (or $30): development stops.** What's left is for rehearsal plus the hidden commands.

---

## 6. Leak defence (Abhinav owns it, everyone obeys it)

`tools/leak_check.py` runs **inside the agent before every API call** and **in CI over every `runs/` folder**:
- Recursively scans the entire request (system, tools, messages; text only, the image is fine) and every engine JSON response for a denylist: colour words, shape words, `cube|sphere|cylinder|cone|zone_|obj|id"|position|target`, and any key not in the §2 whitelist.
- **Exception:** the user's typed command may contain colours and shapes (that's the input, not engine data). The checker allowlists that one string.
- Checks filenames too (`frame_step_03.png`, never `red_cube_view.png`).
- A failure raises and aborts the run. **It never gets disabled to save time.** A leak costs 65 points.

---

## 7. Test-command bank (Abhinav maintains; run on all layouts)

Direct: "Bring the yellow cone" · "Bring the blue cube" · "Fetch the green cylinder"
Disambiguation: "Bring the red cube" (red sphere is a decoy) · "Bring the blue thing that isn't a cube" (none → should give up gracefully)
Reasoning: "Bring the round red thing" · "Bring the tallest object" · "Bring the pointy one" · "Bring the cube that is not red"
Relational (stretch): "Bring the cube farthest from the magenta square" · "Bring the object closest to the wall"

Every run gets one QA-sheet row: run_id, layout, command, outcome, wrong-object Y/N, steps, $, engine seconds, notes.

---

## 8. Submission checklist (Abhinav ticks, Yash pushes)

- [ ] Public repo with the `engine/` Godot project + `agent/` code + README with run instructions
- [ ] Tool-call logs (`steps.jsonl` + frames) for **each of the 3 hidden-command runs**
- [ ] One paragraph: how Claude finds the object from the image (`docs/how_claude_finds_objects.md`)
- [ ] Live demo slot booked (Galaxy Book, Dell as spare)
- [ ] 3 clips uploaded by H20: MP4, ≥720p, 10–20 s, overlay first 2 s, no names, logos or code

---

## 9. Risk register

| Risk | Likelihood | Mitigation | Owner |
|---|---|---|---|
| Godot HTTP server is painful | Med | Hard decision point at H3 → PyBullet + FastAPI fallback | Yash |
| Object-data leak | Med | `leak_check.py` pre-send assert + CI scan | Abhinav |
| Galaxy Book fails during demo | Low | Dell runs the identical commit, `.env` and layout; rehearsed once at H12 | Aadya |
| Wandering, slow runs | High | Geometry table, big steps, scan-then-commit, 25-step soft cap | Aadya |
| Clip > 20 s | Med | Engine-time capture + auto speed-fit in `make_clip.py` | Abhinav |
| Raters can't see the right object arrive | Med | Carried object visible in POV, bright zone, hold final frame 1 s | You |
| Budget runs out | Low | Haiku/mock for plumbing, stop at 120 runs, hard refusal at $34 | Aadya |
| Exhaustion at H18 | High | Split sleep shifts (§4); the hidden-run operators sleep 6:30–9 | Everyone |
| API key committed to public repo | Med | `.env` gitignored; Yash checks `git log -p` before going public | Yash |

---

## 10. Start right now (first 30 minutes)

1. **Yash:** push this `plan.md` + repo scaffold + `.gitignore` (`.env`, `runs/*/pov/`, `.godot/`).
2. **You:** install Godot 4 (standard build), create `engine/`, block out the room.
3. **Aadya:** `pip install anthropic requests pillow`, put the key in `.env`, hello-world a Haiku image call.
4. **Abhinav:** free disk space, install ffmpeg, find a mentor and ask (a) whether move/turn-only counts as the stretch goal, (b) which optional sensors are already approved.
5. **Everyone at H0:30:** read §2 aloud and agree on it. After that, the contract changes only with all four agreeing.

**Mindset:** a boring, reliable, pixel-driven fetch with beautiful logs beats a clever robot that leaks one colour name. Protect the 65.
