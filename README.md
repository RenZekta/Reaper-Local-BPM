# Reaper Local BPM

A ReaScript for Cockos REAPER that makes MIDI items respect the **local tempo and time signature** at their timeline position — in projects where REAPER's native behavior ignores them.

Two tools in a single action:

- **Insert** — creates a blank MIDI item across the active time selection with the local BPM and time signature baked in.
- **Rebuild** — fixes *existing* MIDI items whose internal grid runs at the wrong tempo, keeping every note at its exact audible position.

Both paths can fire in one invocation.

## The Problem

REAPER projects configured with a **Time** timebase have two long-standing quirks:

**1. New MIDI items ignore local tempo.**
`Insert > New MIDI item` (and mouse-modifier equivalents) initialize the item with the project's global default statistics instead of the tempo and time signature markers at its physical position. The SWS "ignore project tempo" workaround is unstable when applied to a blank project-native container: with `Create new MIDI items as: .MID files` enabled, closing the piano roll without saving shrinks the item, offsets notes, or renders a wall of loop notches across the block.

**2. Existing items can't change their baked tempo.**
A MIDI take's tempo is fixed when the take is created, and there is no API to change it afterwards. Drag an item from a 92 BPM region into a 162 BPM region and its grid still runs at 92 — the editor grid is wrong and notes sit at meaningless bar:beat positions.

## The Solution

Both problems get the same cure: a compliant SMF (Standard MIDI File) containing the correct local tempo and time signature meta-events is compiled in a temp cache, imported as an external asset, and run through a stabilization chain — `timebase = Time → SWS ignore-tempo → convert to in-project → glue` — which forces REAPER to bake the local tempo and time signature into the take. PPQ resolution follows your `miditicksperqn` preference; new-track automation follows `launchnewtrkmode`.

- **Insert path:** the imported file *is* the item — a clean, correctly gridded blank MIDI block, structurally stable when closed unsaved, with edge-drag looping active and two-digit take naming (`NN-MIDI` / `NN-TrackName-MIDI`).
- **Rebuild path:** before the swap, every note, CC, text and sysex event of the original item is captured as an *audible timeline position*. After the rebuild, the events are re-injected through the finished take's own PPQ↔time mapping — the grid now runs at the local BPM while playback stays identical (a built-in verification measures the drift of every note, before the optional grid snap cleans up the fractional ticks left by non-integer tempo ratios).

Loops survive: a looped item is rebuilt as one corrected iteration, then the item's length and loop flag are restored — including partial final iterations. Items that already conform to the local tempo are detected and left untouched, so the action is safe on mass selections and safe to run twice.

## Requirements

- REAPER v6.0 or newer (Lua ReaScript support)
- SWS / S&M Extension

## Installation

1. Open REAPER.
2. Open the Action List (`?` or `Actions > Show action list`).
3. Click **ReaScript: New...** in the bottom right corner.
4. Set the file name to `Reaper-Local-BPM` (or any other) and click **Save**.
5. Copy the full source code from the `.lua` file in this repository, paste it into the editor, and save (`Ctrl+S` / `Cmd+S`).

## Usage

### Hotkey Mapping
Locate the registered script in your Action List, select it, and assign it to a custom keyboard shortcut or layout button.

### Insert a blank item
1. Draw a **time selection** over the target region.
2. Run the action.

With a track selected, the item is created on that track. With no track selected, a new track is spawned at the end of the track list.

### Rebuild existing items
1. **Select one or more MIDI items.**
2. Run the action.

Items whose internal tempo doesn't match the local tempo are rebuilt — notes keep their audible positions. Items that already conform are skipped untouched. Looped items keep their loops.

### Both at once
With items selected *and* a time selection active, both paths run in a single invocation: the selected items are rebuilt, and a blank local item is inserted.

## Behavior & Configuration

The script is silent by default — no console output during a clean run. Hard failures (event injection failure, tempo bake not sticking, note drift) always print an `ERROR:` line so nothing fails silently. Set `verbose = true` in the script's `CONFIG` table for a full diagnostic report: per-item old/new grid BPM, tempo ratio, injected event counts, measured note drift, and loop verification.

Notable `CONFIG` options (all documented inline):

| Option | Default | Description |
| --- | --- | --- |
| `check_meter` | `false` | Rebuild only on tempo mismatch. Leave off for polyrhythm workflows that deliberately mix meters within a bar; set `true` to also fix baked time signatures. |
| `quantize` | `"grid"` | Post-rebuild snap: `"grid"` (MIDI editor grid), `"tick"` (whole ticks only, sub-0.05 ms movement), or `"off"`. |
| `preserve_loops` | `true` | Rebuild looped items as one corrected iteration and restore the loop afterwards. |
| `skip_if_conforms` | `true` | Leave items already matching the local tempo completely untouched. |
| `insert_when_no_track_selected` | `true` | The insert path spawns a new track when no track is selected. |
| `consume_selection_after_insert` | `false` | Restore the time selection after an insert. |
| `use_glue` | `true` | **Leave on** — the glue step is required for the tempo bake to survive the import chain. |

## Known Limitations

- Items with multiple takes are skipped (glue to a single take first).
- Looped items that are split pieces sharing a MIDI source (non-zero take offset) are skipped — glue them manually first.
- Notes, CCs (including bezier shapes), text, sysex and per-event mute state are carried across a rebuild; item fades and take envelopes are not.
- The rebuild path is tempo-only by default (see `check_meter`); the insert path always bakes the local time signature for new items.

## License

This project is licensed under the Mozilla Public License 2.0 (MPL-2.0). See [LICENSE](LICENSE) for details.

## About

Built for Time-timebase projects where local tempo regions are the norm, not the exception: create new MIDI on the correct grid, and rescue items that were drawn on the wrong one.