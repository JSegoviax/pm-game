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

## Milestones

- [x] **1. Room prototype:** two rooms, fixed camera angles, tank controls, door transitions
- [x] **2. Threat:** a resident who is no longer himself, health, getting caught, death and restart
- [x] **3. Loop:** inventory, a key, the locked door, the Records Room safe room, typewriter saves, onboarding hints
- [x] **Roguelite foundation (v0.4):** seeded nights with separate random streams, spawn markers, evidence and dispatches, the compound's memory, a new reporter per night, event log and first post-mortem
- [ ] Night Director (Adaptive / Classic setting)
- [ ] 4. Slice complete: all rooms, the puzzle, residents to talk to, the ending, sound
- [ ] 5. Polish and ship: web build on jaimesegovia.com
