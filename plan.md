# Membrane Robot Hackathon — 24-Hour Winning Plan
**Reality check:** This is a real 24-hour hackathon. Sleep, fatigue, integration hell, and last-minute breakages are normal. The plan below is built for that.

**Primary Goal:** Secure Phase 1 sign-off by Hour 13–14 (65 points). Everything else is secondary until that happens.

**Hard Gates:**
- Phase 1 mentor sign-off → unlocks Phase 2 (target ≤ Hour 14)
- Hidden commands published at Hour 18
- Three clips must be uploaded by Hour 20 (hard zero if missed)

---

## 1. Scoring Priority (What Actually Wins)

| Priority | Component                    | Points | Must-Have? | Notes |
|----------|------------------------------|--------|------------|-------|
| 1        | Phase 1: Fetch works         | 40     | Yes        | Clean pass + directness |
| 2        | Phase 1: Image-driven agent  | 25     | Yes        | Pure vision logs only. Leakage = 0 |
| 3        | Phase 2: User verdict        | 20     | High       | Needs clean, short, good-looking clips |
| 4        | Stretch goal                 | 15     | Nice-to-have | Only if core is solid |

**Rule of the hackathon:** A perfect Phase 1 + average Phase 2 beats a fancy stretch that breaks the core.

---

## 2. Non-Negotiable Rules

- **Zero object data** to Claude (names, colours, shapes, positions, distances, IDs, drop-zone coords, etc.). Only `/look` pixels + optional depth + collision flag.
- One Claude call per step. One `/look` after every move/turn.
- Freeze engine while Claude thinks.
- Full JSONL logs + PNG frames.
- No human input during runs.
- POV clips: 10–20 seconds, command overlay first 2s, no team branding.

Leakage or keyboard during demo = Phase 1 death.

---

## 3. Architecture (Keep It Simple)

**Engine**
- Flat room + 4–6 coloured primitives + drop zone + simple wheeled robot with camera
- HTTP API on localhost:8080
- Endpoints: `/state`, `/look`, `/depth` (optional), `/move`, `/turn`, `/pickup`, `/drop`
- State machine + snap pickup + collision → Blocked (max 3 retries)

**Agent (Python)**
- Owns the command
- Claude tool-use loop (one tool call per step)
- Strict “pixels only” system prompt
- JSONL logger + frame saver
- Budget control (Haiku for plumbing, Sonnet for vision)

---

## 4. Realistic 24-Hour Timeline

### Hours 0–4 → Foundation (Engine + API)
**Goal:** Working scene + all endpoints + basic state machine.

- Choose fastest engine stack the team already knows (Godot / Unity / Python+PyBullet / custom — speed > perfection)
- Build flat room, 5 shapes, drop zone, robot + camera
- Implement all 6 endpoints
- Snap pickup + collision handling
- Test everything with curl / simple Python scripts (no Claude yet)
- Confirm `/look` resolution, FOV, tilt are correct

**Exit criteria:** You can move, turn, look, pickup, drop via HTTP and the robot behaves correctly.

### Hours 4–8 → Agent + Vision Loop
**Goal:** Claude can see the image and successfully fetch simple objects.

- Python agent skeleton (command → Claude → tool call → engine → log)
- JSONL logger + PNG frames working
- System prompt v1 (hard “pixels only” rule)
- Switch to Sonnet and get first successful fetches
- Implement full state flow: Locate → Go → Pickup → Carry → Drop → Done
- Add basic Blocked recovery

**Exit criteria:** Robot successfully completes at least 2 different commands with clean logs that prove image-driven decisions.

### Hours 8–12 → Robustness + Phase 1 Ready
**Goal:** Reliable enough for mentor sign-off.

- Improve directness (less wandering)
- Better collision recovery (looks intentional)
- Test edge cases (similar colours, object near wall, partial view)
- Force Claude to re-observe after every move
- Budget check — stop wasteful experiments
- Dry-run the exact Phase 1 completion check (3 different commands, no human input)

**Exit criteria:** Confident you can demo 3 clean runs to a mentor.

### Hours 12–14 → Phase 1 Sign-off
**Goal:** Get official mentor sign-off.

- Live demo
- Show logs proving pure vision
- Get sign-off → receive Phase 2 API key + guide

**Do not start Phase 2 work until you have sign-off.**

### Hours 14–17 → Phase 2 Pipeline + Stretch Decision
**Goal:** Recording system ready + choose one stretch (or none).

- Build POV recording (start on leave Idle, stop on Done, command overlay, 10–20s)
- Rehearse recording several successful runs
- Decide stretch goal (recommended: multi-view reasoning). Only start it if core is rock solid.
- Keep testing the core fetch — do not break it.

### Hour 18 → Hidden Commands
- Run each of the 3 unseen commands **exactly once**
- Capture perfect POV clips + full logs + frames
- Treat these runs as final

### Hours 18–20 → Upload + Submission
- Verify clips (duration, overlay, no branding, quality)
- Upload all three clips before Hour 20
- Finalise repo, logs, one-paragraph explanation, book demo slot

### Hours 20–24 → Buffer / Polish / Stretch / Demo Practice
- Only touch stretch if it is already close to working
- Practice the live judge demo (directness matters)
- Rest if possible — tired teams make stupid mistakes
- Do **not** risk breaking a working Phase 1 for last-minute ideas

---

## 5. Stretch Goal Decision (Be Ruthless)

Pick **at most one**. Prefer the one that is easiest to prove in logs and demo.

**Recommended order:**
1. Multi-view reasoning (“farthest cube from the green square”) — best ROI
2. Full path planning with only move/turn
3. Obstacles / furniture (higher risk of collisions)
4. Pulse-based improvement (usually too late)

**Hard rule:** If core fetch is not reliable by Hour 12, drop stretch completely and protect the 65 points.

---

## 6. Critical Success Factors in a 24h Setting

1. **Speed of first working loop** — Get Claude seeing the camera and moving the robot as early as possible.
2. **Data boundary discipline** — One person owns the “no leakage” check.
3. **Logging from day one** — Judges will read the logs. Make them clear.
4. **Direct motion** — Wandering loses points in both Phase 1 and Phase 2.
5. **Recording pipeline ready early** — Do not discover clip issues at Hour 19.
6. **Budget awareness** — Vision calls are expensive. Test plumbing with cheap models first.
7. **Sleep / rotation** — At least one person should be relatively fresh for the Hour 18–20 window.

---

## 7. Immediate Next Actions (Start Now)

1. Decide engine technology (fastest path for the team).
2. Assign clear owners:
   - Engine + API
   - Agent + Claude loop
   - Prompt + logging
   - Recording + submission
3. Scaffold the six endpoints and a minimal scene.
4. Write the first strict system prompt.
5. Set a shared budget tracker and step counter.

---

**Final mindset for 24 hours:**
Ship a reliable, image-driven fetch first. Make the logs beautiful. Record clean clips. Only then chase the stretch.

Protect Phase 1 at all costs. That is how you win.