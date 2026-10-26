# P.M.

A short survival horror game in the spirit of the original Resident Evil and P.T. A reporter investigates an occult group's compound and finds it nearly empty. It is not empty.

Built with Godot 4.7 (Compatibility renderer, GDScript) for desktop browsers first.

## Run it

1. Open Godot and click **Import**.
2. Choose this folder's `project.godot`, then **Import & Edit**.
3. Press **F5** (or the ▶ button, top right) to play.

## Controls (tank controls)

| Action | Keyboard | Gamepad (Xbox / Steam Deck) |
|---|---|---|
| Walk forward / back | W / S or ↑ / ↓ | D-pad or left stick |
| Turn left / right | A / D or ← / → | D-pad or left stick |
| Run | Hold Shift | Hold B |
| Quick 180° turn | Hold back, tap Shift | Hold back, tap B |
| Open doors, talk, pick up, shove | E, Space or Enter | A |
| Items | Tab or I | Y |
| Back / close | Esc | B |
| Performance stats on/off | F3 | Back / View |

The version number and performance stats (FPS, CPU and GPU frame time, draw calls, memory) show in the top right.

## How a night works

- Every night is one reporter's attempt. It starts at the front door, with a new seed that decides where the key, supplies and evidence are, and where the resident stands.
- Evidence (notes, ledgers, slips) goes in your notebook. It only counts once you send it home from a safe-room typewriter. Sending doesn't end the night.
- If the reporter dies or goes missing, there's no going back to a save. The post-mortem reviews the night, and the next reporter is sent, briefed on everything that reached the office.
- The compound remembers. Doors and locks you open stay open for every reporter after you. A code you send home stays the same, and the next reporter knows it.
- The typewriter can also pause the night so you can quit and pick it up later. Pausing never protects you from death.
- **Start over** on the title screen erases everything and begins again from the first reporter.

## The compound (v0.5)

- **Foyer** → East Hallway, Welcome Hall
- **Welcome Hall** (the benefactors' entrance: donor wall, the founder's portrait) → Chapel
- **Chapel** (pews, the front rows roped off for benefactors, the altar and speakers) → Infirmary (locked)
- **Infirmary / tonic lab** → Dormitory (locked; one Infirmary Key opens both doors)
- **Dormitory** (residents asleep in their bunks; walk too close and one stirs, back away and he settles) → East Hallway
- **East Hallway** → Records Room (locked)
- **Records Room** (safe room, typewriter) → Basement Stairs, down to a chained gate

Items and evidence land on marked spots that change every night. Keys always land where they can be reached.

Every door has a lamp above it. A red lamp means the door is locked.

## Fighting

- **Ready a weapon** from the inventory (picking one up readies it if your hands are empty). Hold **Aim** (Q, right-click, or R1) to raise it: your feet stay planted and you can still turn. Press **interact** to swing or fire.
- **Lead Pipe** (2 damage, 6 uses, 2 m reach) is always somewhere you can reach. **Fire Axe** (3 damage, 4 uses, 2.2 m reach) turns up on about half the nights. Weapons wear out and break.
- **Revolver** (3 damage) turns up on about a third of nights, with a few rounds. It's loud: sleepers in the same room wake up.
- **Shove** still stuns. Any hit on a stunned resident counts double, so shove-then-axe puts someone down in one blow.
- **They get back up.** A downed resident rises again after about 40 seconds, weaker. To stop that, burn the body with **Lamp Oil** or finish it with the **Fire Axe**.

## Run reports (for troubleshooting)

Every night is recorded to `~/PMRuns` on your computer, like a QA session attached to a bug ticket:

- `<date>_r<reporter>_seed<seed>.json`: the full record for Claude. Setup, every event, the player's and resident's positions five times a second, health, keys held, and the outcome.
- `<date>_r<reporter>_seed<seed>.txt`: the same night as a readable timeline.
- Press **F9** (R3 on a controller) to flag a moment. It's marked in the log and a screenshot is saved next to the run.

The file updates every few seconds, so a crash still leaves a record. The newest 40 runs are kept.

## Milestones

- [x] **1. Room prototype:** two rooms, fixed camera angles, tank controls, door transitions
- [x] **2. Threat:** a resident who is no longer himself, health, getting caught, death and restart
- [x] **3. Loop:** inventory, a key, the locked door, the Records Room safe room, typewriter saves, onboarding hints
- [x] **Roguelite foundation (v0.4):** seeded nights with separate random streams, spawn markers, evidence and dispatches, the compound's memory, a new reporter per night, event log and first post-mortem
- [x] **Compound and combat (v0.5):** five new rooms, weapons that wear out, the revolver, residents who get back up unless the body is finished
- [ ] Night Director (Adaptive / Classic setting)
- [ ] 4. Slice complete: all rooms, the puzzle, residents to talk to, the ending, sound
- [ ] 5. Polish and ship: web build on jaimesegovia.com

## Tests

Headless tests live in `tests/` and can be rerun anytime:

```
godot --headless --path . -s tests/test_compound_and_combat.gd
godot --headless --path . -s tests/test_recorder.gd
```
