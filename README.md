# Space Invaders (MASM 8086)

A **Computer Organization and Assembly Language (COAL)** course project: a Space Invaders–style game implemented entirely in **Intel 8086** assembly using **MASM 6.x**, running as a **16-bit real-mode DOS** program under **DOSBox**.

Demo link: https://youtu.be/J13JrBQTgwM

The project demonstrates low-level topics from computer organization: **memory models**, **segment registers**, **BIOS services** (`INT 10h`, `INT 16h`), **direct mapped video RAM** (colour text mode at segment `B800h`), the **BIOS tick counter** for timing (`0040:006C`), **extended keyboard scan codes**, structured **procedure** layout, and disciplined **register preservation** across calls.

---

## Table of contents

1. [Course context](#course-context)
2. [What you get](#what-you-get)
3. [Platform and constraints](#platform-and-constraints)
4. [Build and run](#build-and-run)
5. [Controls](#controls)
6. [Game design](#game-design)
7. [Architecture (assembly / CO concepts)](#architecture-assembly--co-concepts)
8. [Source layout](#source-layout)
9. [Files](#files)

---

## Course context

This deliverable is intended for **Computer Organization and Assembly Language (COAL)** coursework. It ties together:

- **ISA level**: 8086 instruction set, addressing modes, flags, and calling conventions for modular `PROC` routines.
- **System interface**: BIOS interrupts for video mode, keyboard, and system clock exposure.
- **Memory and I/O**: small-model segmentation (`.MODEL small`), stack use, and byte-oriented layout of game state in `.DATA`.
- **Peripherals abstractions**: treating the display as a **memory-mapped** buffer (`B800h`) and the keyboard as a **scan-code** stream via `INT 16h`.

---

## What you get

- **Start screen**: title “SPACE INVADERS”, control hints, “Press **ENTER** to Start”.
- **Player**: `[A]` sprite near the bottom; **Left/Right** arrows move within the 80-column row; **Space** fires one upward bullet (`|`) at a time.
- **Enemies**: **one row × four enemies** (`W`) at columns **10, 30, 50, 70**, row **3**, all visible when alive.
- **Enemy motion**: shared horizontal slide with bounce at screen edges; **no vertical descent**.
- **Enemy fire**: up to **five** downward enemy bullets; spawns from random **alive** enemies on a timer.
- **Collisions**: player bullet kills an enemy (score **+1**); enemy bullet hitting the player (score **−1**). Destroyed enemies **respawn** in the same slot after about **3 seconds** (BIOS-tick–based countdown).
- **Score / game over**: HUD shows `Score: X` on the top row; starting score **3**; reaching **0** shows **GAME OVER** with final score; **R** restarts fully, **Q** quits.

---

## Platform and constraints

| Item | Value |
|------|--------|
| CPU | Intel **8086** compatible (real mode only) |
| Assembler | **MASM 6.x** |
| Memory model | **`.MODEL small`** |
| OS / runtime | **DOS** (typically **DOSBox**) |
| Display | **80×25** colour **text** mode |
| Output | **INT 10h** for mode + cursor; direct **VRAM** at **B800h** for drawing |

The source avoids `.386`, protected mode, Windows APIs, high-level runtimes, and non-8086 instructions.

---

## Build and run

From a directory that contains `SPACEINV.ASM` and where MASM/LINK are on `PATH` (for example inside **DOSBox** with your toolchain mounted):

```bat
masm SPACEINV.ASM;
link SPACEINV.OBJ;
SPACEINV
```

On 64-bit Windows, the classic **16-bit `LINK.EXE`** may not run natively; assembling/linking inside **DOSBox** (or a 16-bit DOS environment) matches the intended workflow.

---

## Controls

| Input | Action |
|-------|--------|
| **Left Arrow** | Move left (scan code `4Bh`) |
| **Right Arrow** | Move right (scan code `4Dh`) |
| **Space** | Fire (extended + ASCII handled) |
| **Q** | Quit (title, gameplay, or game over flow) |
| **Enter** | Start from title screen |
| **R** | Restart from game over screen |

Extended keys are handled by reading **scan codes** in `AH` after `INT 16h`, not only ASCII in `AL`.

---

## Game design

### Scoring and difficulty

- Initial score: **3**. Killing an enemy increases score by **1**. Getting hit by an enemy bullet decreases score by **1** (not below zero for display logic).
- When score reaches **0**, the game transitions to the **game over** screen.

### Entities

- **Player bullet**: single active shot; moves **up** each frame; cleared off top or on hit.
- **Enemy bullets**: multiple slots (default **5**); move **down** each frame; spawn on a frame timer from a random living enemy using a small **16-bit PRNG** (LCG) in software.

### Enemy formation

- Fixed **base columns** `10, 30, 50, 70` plus a **shared signed offset** and **direction** implement synchronized horizontal motion with edge bounce.
- **Respawn**: per-slot timer decremented each frame; when it hits zero, that slot’s enemy returns at its **original** column.

---

## Architecture (assembly / CO concepts)

### State machine

The program is structured as explicit **screens**: `TitleScreen` → main **`game_loop`** → `GameOverScreen`, with flags for quit and restart. `ResetGame` reinitialises all mutable `.DATA` state for a fair restart.

### Frame loop (timing)

Each iteration waits until the **BIOS daily timer tick** word at **physical `0040:006Ch`** changes, giving roughly **18 Hz** pacing—stable in DOSBox without calibration loops.

### Rendering model

Every frame:

1. **Clear** the text buffer with `rep stosw` into **segment `B800h`** (space + attribute `07h`).
2. Draw **HUD**, **enemies**, **player**, and **bullets** via `PutChar` (row×80+column, times two bytes per cell: **attribute high, character low** in little-endian word layout as used by the `PutChar` implementation).

This avoids partial updates that leave stray characters and matches **memory-mapped text mode** organization.

### Input model

- **Non-blocking** drain: `INT 16h` with `AH=01h` tests the buffer; `AH=00h` consumes. Movement and fire are applied while keys are pending in one frame step.

### Procedures (modular design)

Representative routines: `InitGame`-equivalent flow in `main`, `ResetGame`, `HandleInput`, `MoveEnemies`, `SpawnEnemyBullet`, `UpdatePlayerBullet`, `UpdateEnemyBullets`, `CheckCollisions`, `CheckRespawn`, `RenderFrame`, `DrawHUD`, `TitleScreen`, `GameOverScreen`, `WaitTick`, `ClearScreen`, `PutChar`, `DrawString`, `Rand`, plus cursor helpers.

### Engineering rules

- **Push/pop** discipline inside procedures; callers do not rely on clobbered registers across `CALL`.
- **Explicit loop counters** (compare index to limit) instead of fragile `LOOP` usage where clarity matters.
- **8086-only** instruction selection via `.8086`.

---

## Source layout

- **`SPACEINV.ASM`**: single translation unit: constants (`EQU`), `.DATA` (game state, strings), `.CODE` (procedures), `END main`.

---

## Files

| File | Role |
|------|------|
| `SPACEINV.ASM` | Full game source (MASM 6.x, 8086, `.MODEL small`) |
| `SPACEINV.OBJ` | Object file (after `masm`) |
| `SPACEINV.EXE` | DOS executable (after `link`) |
| `README.md` | This document |

---

## Academic honesty note

If you submit this for a COAL course, follow your instructor’s rules on **original work**, **citation**, and **allowed collaboration**. This README describes the project’s technical scope; ownership and attribution policies are defined by your syllabus.
