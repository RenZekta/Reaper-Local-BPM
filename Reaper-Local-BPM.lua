--[[
  Local BPM Unified
  =================
  Repository:  https://github.com/RenZekta/Reaper-Local-BPM
  License:     MPL-2.0
  Requirements: REAPER v6+ (Lua ReaScript), SWS / S&M Extension

  Makes MIDI items respect the LOCAL tempo and time signature at their
  timeline position, in projects using a "Time" project timebase where
  REAPER natively initializes MIDI with the project's default statistics
  instead. One action, two paths (both may fire in a single invocation):

  PATH A - REBUILD selected MIDI items
    Selected MIDI items whose internal (baked) tempo does not match the
    local tempo at their position are rebuilt to run at the local BPM:
      * before any tempo decision, boundaries sitting in the wrong
        tempo region are snapped onto the region marker with
        take-offset compensation - down to sub-microsecond straddles
        (a boundary grazing a marker makes the item read as sitting in
        the PREVIOUS region, causing false rebuilds and errors)
      * every note / CC / text / sysex event keeps its exact audible
        timeline position (re-measured afterwards; drift is reported)
      * playback-rate compensations are normalized: the effective rate
        is item D_PLAYRATE x take D_PLAYRATE (changing a MIDI item's
        BPM via item properties stores the compensation in the TAKE
        rate), and any item whose rate differs from 1.0 is rebuilt at
        the local tempo with rate 1.0 - audible positions preserved
      * looped items are rebuilt as ONE corrected iteration, then the
        loop is restored - including a partial final iteration
      * items that already conform (effective grid = local tempo, rate
        1.0) are left completely untouched - safe on mass selections,
        safe to re-run
      * an optional grid-snap pass cleans the fractional ticks left
        by non-integer tempo ratios
    Items with multiple takes and looped split pieces sharing a MIDI
    source (non-zero take offset) are skipped with an explanation;
    straddles beyond snap_straddle_ms are reported, not forced.

  PATH B - INSERT a blank MIDI item into the active time selection
    A new MIDI item is created across the time selection with the local
    tempo + time signature baked in, ready to draw on the correct grid:
      * with a track selected, the item lands on that track
      * with no track selected, a new track is spawned at the end of
        the track list (repository naming/automation conventions)
      * edge-drag looping is active; the take is named NN-MIDI or
        NN-TrackName-MIDI

  WHY THE TEMP FILE?
    REAPER bakes a MIDI take's tempo and time signature when the take
    is created from a file, and exposes no API to change them later.
    Both paths therefore write a tiny SMF (tempo + time signature +
    EndOfTrack meta events only, sized to the target span, at the
    user's miditicksperqn PPQ) to a uniquely named temp file, import it
    via InsertMedia, and run the stabilization chain:

        timebase = Time -> SWS ignore-tempo ->
        convert to in-project -> glue

    The glue step is REQUIRED: without it the tempo bake does not
    survive the chain. Path A then injects the original events into
    the finished take through that take's own PPQ<->time mapping, so
    nothing downstream can re-time them. The temp file is deleted at
    the end of the run.

  CONFIGURATION: see the CONFIG table below. Notables:
    verbose (default false)        fully silent except ERROR lines;
                                   true = full per-item diagnostic report
    snap_boundaries (true)         fix boundaries sitting in the wrong
                                   tempo region before reading it
    normalize_playrate (true)      rebuild items carrying a playback-
                                   rate compensation so they run at
                                   rate 1.0 (audible positions kept)
    check_meter (default false)    rebuild on tempo mismatch only; leave
                                   off for polyrhythm workflows that
                                   deliberately mix meters within a bar
    quantize (default "grid")      post-rebuild snap: "grid", "tick", off

  Everything runs inside a single undo point. Original items are only
  deleted after the rebuilt item is verified, so a failed rebuild
  leaves the source item untouched.
]]

local CONFIG = {
  tolerance        = 0.005,
  skip_if_conforms = true,
  force_rebuild    = false,
  check_meter      = false,   -- tempo-only by default; true = also fix meter
  normalize_playrate = true,  -- rebuild items with a playback-rate
                              -- compensation (rate != 1.0), normalizing
                              -- them to the local tempo at rate 1.0

  snap_boundaries   = true,   -- fix start/end boundaries that sit in the wrong
                              -- tempo region (sub-us straddles up to 250 ms),
                              -- before reading the local tempo
  snap_straddle_ms  = 250,    -- max leading/trailing sliver auto-trimmed
  snap_dust_ms      = 20,     -- float-dust grid/marker snap threshold
  
  use_glue         = true,    -- REQUIRED, see header
  preserve_loops   = true,
  quantize         = "grid",  -- "grid" | "tick" | "off"
  grid_qn          = 0.25,
  quantize_lengths = true,
  quantize_cc      = true,

  consume_selection_after_insert = false, -- restore the time selection after insert
  insert_when_no_track_selected  = true,  -- no track selected + time selection:
                                          -- spawn a NEW track and insert there
  verbose = false,                        -- false = silent except ERROR lines
                                          -- true  = full diagnostic report
}

-- ================= logging =================

local function log(msg)   -- information: verbose only
  if CONFIG.verbose then reaper.ShowConsoleMsg(msg) end
end

local function err(msg)   -- hard errors: ALWAYS printed, even when silent
  reaper.ShowConsoleMsg(msg)
end

-- ================= helpers =================

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

local function ptr_ok(item)
  if item == nil then return false end
  if reaper.ValidatePtr then return reaper.ValidatePtr(item, "MediaItem*") end
  return true
end

local function tptr_ok(track)
  if track == nil then return false end
  if reaper.ValidatePtr then return reaper.ValidatePtr(track, "MediaTrack*") end
  return true
end

-- Effective playback rate of a MIDI item.
-- REAPER stores MIDI tempo compensations on the TAKE's D_PLAYRATE (the
-- item-level read can return 0 - an impossible real value - on some
-- builds/items). Each read is validated independently; an invalid read
-- falls back to 1.0 BEFORE multiplying, so a bad item-level read can
-- never mask a valid take-level rate (the v17 bug).
local function GetEffectiveRate(item, take)
  local ipr_raw = reaper.GetMediaItemInfo_Value(item, "D_PLAYRATE")
  local ipr = (type(ipr_raw) == "number" and ipr_raw > 0 and ipr_raw <= 100.0)
              and ipr_raw or 1.0
  local tpr = 1.0
  if reaper.GetMediaItemTakeInfo_Value then
    local v = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
    if type(v) == "number" and v > 0 and v <= 100.0 then tpr = v end
  end
  return ipr * tpr, ipr, tpr
end

-- ============ boundary snapping (Phase 0) ============

-- reads exactly like the local-tempo lookup below it
local function LocalTempoReadAt(t)
  local bpm, num, den
  if reaper.FindTempoTimeSigMarker then
    local idx = reaper.FindTempoTimeSigMarker(0, t) or -1
    if idx >= 0 then
      local _, _, _, _, b, n, d = reaper.GetTempoTimeSigMarker(0, idx)
      if b and b > 0 then bpm = b end
      if n and n >= 1 and d and d >= 1 then num, den = n, d end
    end
  end
  if not bpm and reaper.TimeMap2_GetDividedBpmAtTime then
    local v = reaper.TimeMap2_GetDividedBpmAtTime(0, t)
    if v and v > 0 then bpm = v end
  end
  if not bpm and reaper.Master_GetTempo then bpm = reaper.Master_GetTempo() end
  if not bpm or bpm <= 0 then bpm = 120.0 end
  if not num or not den then num, den = 4, 4 end
  return bpm, num, den
end

local function BodyTempo(pos, len)
  local counts, first_sig = {}, {}
  for k = 1, 9 do
    local t = pos + len * k / 10.0
    local bpm, num, den = LocalTempoReadAt(t)
    local key = string.format("%.3f", bpm)
    counts[key] = (counts[key] or 0) + 1
    if not first_sig[key] then first_sig[key] = { num, den } end
  end
  local bestKey, bestN = nil, 0
  for key, c in pairs(counts) do
    if c > bestN then bestKey, bestN = key, c end
  end
  local bpm = tonumber(bestKey) or 120.0
  local sig = first_sig[bestKey] or { 4, 4 }
  return bpm, sig[1], sig[2], bestN
end

local function MarkersInside(a, b)
  local list = {}
  if reaper.CountTempoTimeSigMarkers then
    local n = reaper.CountTempoTimeSigMarkers(0)
    for i = 0, n - 1 do
      local ok, mtime, qnpos, sortpos, mbpm, mnum, mden =
        reaper.GetTempoTimeSigMarker(0, i)
      if ok and type(mtime) == "number" and mtime > a and mtime <= b then
        list[#list + 1] = { t = mtime, bpm = mbpm, num = mnum, den = mden }
      end
    end
  end
  table.sort(list, function(x, y) return x.t < y.t end)
  return list
end

local function BestDustTarget(t)
  local thr = CONFIG.snap_dust_ms / 1000.0
  if reaper.CountTempoTimeSigMarkers then
    local n = reaper.CountTempoTimeSigMarkers(0)
    local best_m, best_d = nil, math.huge
    for i = 0, n - 1 do
      local ok, mtime = reaper.GetTempoTimeSigMarker(0, i)
      if ok and type(mtime) == "number" then
        local d = math.abs(mtime - t)
        if d <= thr and d < best_d then best_m, best_d = mtime, d end
      end
    end
    if best_m then return best_m, "marker" end
  end
  local t2qn = reaper.TimeMap_timeToQN
  local qn2t = reaper.TimeMap_QNToTime
  if t2qn and qn2t then
    local qn = t2qn(t)
    if type(qn) == "number" then
      local k = math.floor(qn / 0.25 + 0.5)
      local gt = qn2t(math.max(0, k * 0.25))
      if type(gt) == "number" then
        local d = math.abs(gt - t)
        if d <= thr then return gt, "grid 1/16" end
      end
    end
  end
  return nil
end

-- Phase 0: snap boundaries that sit in the wrong tempo region (or off
-- the grid by dust), with take-offset compensation. Returns a report
-- line for verbose mode (nil when nothing changed).
local function SnapBoundaries(item, take)
  local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  if len <= 0.001 then return nil end
  local end_t = pos + len

  local offs = 0
  if reaper.GetMediaItemTakeInfo_Value then
    offs = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS") or 0
  end

  local bpm_s = LocalTempoReadAt(pos)
  local bpm_b, num_b, den_b, votes = BodyTempo(pos, len)
  local bpm_e = LocalTempoReadAt(end_t)
  local inside = MarkersInside(pos, end_t)
  local body_ok = (votes >= 5)

  local new_pos, new_end, moved = pos, end_t, false
  local report = {}
  local thr = CONFIG.snap_straddle_ms / 1000.0

  -- START: sits in the wrong region -> snap onto the body-region marker
  if body_ok and math.abs(bpm_s - bpm_b) > 0.01 then
    for _, m in ipairs(inside) do
      if math.abs(LocalTempoReadAt(m.t + 0.001) - bpm_b) <= 0.01 then
        local sliver = m.t - pos
        if sliver > 0 and sliver <= thr then
          new_pos = m.t
          moved = true
          report[#report + 1] = string.format(
            "start snap %+.6f ms onto region %.3f (read %.3f -> %.3f BPM)",
            sliver * 1000.0, bpm_b, bpm_s, bpm_b)
        elseif sliver > thr then
          report[#report + 1] = string.format(
            "start straddles by %.1f ms (over %d ms threshold) - not snapped",
            sliver * 1000.0, CONFIG.snap_straddle_ms)
        end
        break
      end
    end
  else
    -- dust snap only
    local t, kind = BestDustTarget(pos)
    if t and t >= 0 and math.abs(t - pos) > 0.000001 then
      new_pos = t
      moved = true
      report[#report + 1] = string.format(
        "start dust snap %+.1f ms (%s)", (t - pos) * 1000.0, kind)
    end
  end

  -- END: sits in the next region -> snap back onto its marker
  if body_ok and math.abs(bpm_e - bpm_b) > 0.01 then
    for i = #inside, 1, -1 do
      local m = inside[i]
      if math.abs(LocalTempoReadAt(m.t + 0.001) - bpm_e) <= 0.01 then
        local sliver = end_t - m.t
        if sliver > 0 and sliver <= thr then
          new_end = m.t
          moved = true
          report[#report + 1] = string.format(
            "end snap -%.6f ms onto region boundary (after-end read %.3f -> %.3f BPM)",
            sliver * 1000.0, bpm_e, bpm_b)
        elseif sliver > thr then
          report[#report + 1] = string.format(
            "end straddles by %.1f ms (over %d ms threshold) - not snapped",
            sliver * 1000.0, CONFIG.snap_straddle_ms)
        end
        break
      end
    end
  else
    local t, kind = BestDustTarget(end_t)
    if t and math.abs(t - end_t) > 0.000001 then
      new_end = t
      moved = true
      report[#report + 1] = string.format(
        "end dust snap %+.1f ms (%s)", (t - end_t) * 1000.0, kind)
    end
  end

  if not moved then return nil end
  local new_len = new_end - new_pos
  if new_len <= 0.001 then
    return "boundary snap SKIPPED: would collapse the item"
  end

  reaper.SetMediaItemInfo_Value(item, "D_POSITION", new_pos)
  reaper.SetMediaItemInfo_Value(item, "D_LENGTH", new_len)
  -- offset compensation: notes keep their exact audible positions,
  -- same semantics as dragging the edge by hand
  reaper.SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", offs + (new_pos - pos))
  if reaper.MarkProjectDirty then reaper.MarkProjectDirty() end

  return "boundary snap: " .. table.concat(report, "; ")
end

-- ============ end boundary snapping ============

-- create a new track at the end of the track list and select it
local function SpawnTrackAtEnd()
  local before = reaper.CountTracks(0)
  if reaper.InsertTrackAtIndex then
    pcall(reaper.InsertTrackAtIndex, before, true)
  end
  if reaper.CountTracks(0) <= before then
    reaper.Main_OnCommand(40001, 0)   -- Track: Insert new track
  end
  local after = reaper.CountTracks(0)
  if after > before then
    local t = reaper.GetTrack(0, after - 1)
    if t then reaper.SetOnlyTrackSelected(t) end
    return t
  end
  return nil
end

local function vlq(n)
  local s = string.char(n & 0x7F)
  n = n >> 7
  while n > 0 do
    s = string.char((n & 0x7F) | 0x80) .. s
    n = n >> 7
  end
  return s
end

local function GridLabel(qn)
  local names = { [4] = "1/1", [2] = "1/2", [1] = "1/4", [0.5] = "1/8",
                  [0.25] = "1/16", [0.125] = "1/32", [0.0625] = "1/64" }
  return names[qn] or string.format("%g QN", qn)
end

local function SnapToGrid(ppq, g)
  if CONFIG.quantize == "tick" then
    return math.floor(ppq + 0.5)
  end
  return math.floor(math.floor(ppq / g + 0.5) * g + 0.5)
end

-- robust time-selection read (handles both return layouts)
local function ReadTimeSelection()
  local a, b, c = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
  local s, e
  if type(a) == "number" and type(b) == "number" then
    s, e = a, b
  elseif type(b) == "number" and type(c) == "number" then
    s, e = b, c
  end
  if s and e and e > s + 0.001 then return s, e end
  return nil, nil
end

local function GetLocalTempoAtTime(t)
  local bpm, num, den
  local idx = -1
  if reaper.FindTempoTimeSigMarker then
    idx = reaper.FindTempoTimeSigMarker(0, t) or -1
  end
  if idx >= 0 and reaper.GetTempoTimeSigMarker then
    local _, _, _, _, b, n, d = reaper.GetTempoTimeSigMarker(0, idx)
    if b and b > 0 then bpm = b end
    if n and n >= 1 and d and d >= 1 then num, den = n, d end
  end
  if not bpm and reaper.TimeMap2_GetDividedBpmAtTime then
    local v = reaper.TimeMap2_GetDividedBpmAtTime(0, t)
    if v and v > 0 then bpm = v end
  end
  if not bpm and reaper.Master_GetTempo then bpm = reaper.Master_GetTempo() end
  if not bpm or bpm <= 0 then bpm = 120.0 end
  if not num or not den then num, den = 4, 4 end
  return bpm, num, den
end

-- effective grid BPM (baked tempo x effective rate), via the take's own
-- PPQ<->time mapping
local function TakeGridBPM(take)
  local t0 = reaper.MIDI_GetProjTimeFromPPQPos(take, 0)
  local t1 = reaper.MIDI_GetProjTimeFromPPQPos(take, 960)
  if t0 and t1 and (t1 - t0) > 0 then return 60.0 / (t1 - t0) end
  return nil
end

local function TakeConforms(take, pos, lbpm, lnum, lden, R, old_bpm, eff_rate)
  if math.abs(old_bpm / lbpm - 1.0) > CONFIG.tolerance then
    return false, string.format("tempo %.3f vs local %.3f", old_bpm, lbpm)
  end
  if CONFIG.normalize_playrate and math.abs(eff_rate - 1.0) > CONFIG.tolerance then
    -- effective grid matches the local tempo, but a playback-rate
    -- compensation remains (baked tempo differs) - normalize it
    return false, string.format(
      "tempo matches, but playback rate %.4f (baked ~%.3f BPM) - normalizing to rate 1.0",
      eff_rate, old_bpm / eff_rate)
  end
  if CONFIG.check_meter and reaper.MIDI_GetPPQPos_StartOfMeasure
     and reaper.MIDI_GetPPQPos_EndOfMeasure then
    local p = 0
    local pp = reaper.MIDI_GetPPQPosFromProjTime(take, pos + 0.001)
    if pp and pp > 0 then p = pp end
    local m0 = reaper.MIDI_GetPPQPos_StartOfMeasure(take, p)
    local m1 = reaper.MIDI_GetPPQPos_EndOfMeasure(take, p)
    if m0 and m1 and (m1 - m0) > 0 then
      local baked_qn = (m1 - m0) / R
      local local_qn = lnum * 4.0 / lden
      if math.abs(baked_qn - local_qn) > 0.02 then
        return false, string.format(
          "tempo OK, but baked meter is %.2f QN/bar vs local %.2f QN/bar",
          baked_qn, local_qn)
      end
      return true, string.format("tempo + meter match (%.2f QN/bar)", baked_qn)
    end
  end
  return true, "tempo matches, rate 1.0"
end

local function BuildBlankSMF(bpm, num, den, item_len, R)
  local usqn = clamp(math.floor(60000000.0 / bpm + 0.5), 1, 16777215)
  local bpm_file = 60000000.0 / usqn
  local t1 = string.char((usqn >> 16) & 0xFF)
  local t2 = string.char((usqn >> 8) & 0xFF)
  local t3 = string.char(usqn & 0xFF)
  local di = math.floor(den)
  local dd = 2
  if di == 1 then dd = 0 elseif di == 2 then dd = 1 elseif di == 4 then dd = 2
  elseif di == 8 then dd = 3 elseif di == 16 then dd = 4 elseif di == 32 then dd = 5 end
  local ts1 = string.char(clamp(math.floor(num), 1, 255))
  local ts2 = string.char(dd)
  local total_ticks = math.ceil(item_len * (bpm_file / 60.0) * R)
  if total_ticks < 1 then total_ticks = 1 end
  local header     = "MThd\000\000\000\006\000\000\000\001"
                    .. string.char((R >> 8) & 0xFF, R & 0xFF)
  local meta_ts    = "\000\255\088\004" .. ts1 .. ts2 .. "\024\008"
  local meta_tempo = "\000\255\081\003" .. t1 .. t2 .. t3
  local meta_end   = vlq(total_ticks) .. "\255\047\000"
  local track_data = meta_ts .. meta_tempo .. meta_end
  return header .. "MTrk" .. string.pack(">I4", #track_data) .. track_data,
         bpm_file, total_ticks
end

-- ================= loop analysis (deterministic) =================

local function AnalyzeLoop(item, take, len)
  local loopsrc_on = reaper.GetMediaItemInfo_Value(item, "B_LOOPSRC") == 1
  local eff, ipr, tpr = GetEffectiveRate(item, take)
  local slen = 0
  local src = reaper.GetMediaItemTake_Source(take)
  if src then slen = reaper.GetMediaSourceLength(src) or 0 end

  local audible_iter = (slen > 0.05) and (slen / eff) or nil
  local is_looped = loopsrc_on and audible_iter ~= nil
                    and audible_iter < len - 0.05

  local diag
  if is_looped then
    diag = string.format(
      "loop: source %.3fs @ playrate %.4f (item %.3f x take %.3f) -> one" ..
      " iteration %.3fs; item %.3fs = %.2f iterations (partial %.3fs)",
      slen, eff, ipr, tpr, audible_iter, len, len / audible_iter,
      len % audible_iter)
  elseif loopsrc_on then
    if audible_iter == nil then
      diag = string.format(
        "loop: B_LOOPSRC on but source length unreadable (%.3fs)," ..
        " playrate %.4f - rebuilding unlooped", slen, eff)
    else
      diag = string.format(
        "loop: B_LOOPSRC on but the source (%.3fs audible, playrate %.4f)" ..
        " covers the item (%.3fs) - not actually looped",
        audible_iter, eff, len)
    end
  else
    diag = "loop: off (B_LOOPSRC not set)"
  end
  return is_looped, audible_iter, diag
end

-- ================= snapshot / injection =================

local function SnapshotEvents(take, pos)
  local notes, ccs, texts, dropped = {}, {}, {}, 0
  local _, notecnt, cccnt, textcnt = reaper.MIDI_CountEvts(take)

  for i = 0, (notecnt or 0) - 1 do
    local ok, sel, mute, s, e, chan, pitch, vel = reaper.MIDI_GetNote(take, i)
    if ok then
      local ts = reaper.MIDI_GetProjTimeFromPPQPos(take, s)
      local te = reaper.MIDI_GetProjTimeFromPPQPos(take, e)
      if ts and te then
        if te <= pos then
          dropped = dropped + 1
        else
          if ts < pos then ts = pos end
          notes[#notes + 1] = { sel = sel, mute = mute, ts = ts, te = te,
                                chan = clamp(chan, 0, 15),
                                pitch = clamp(pitch, 0, 127),
                                vel = clamp(vel, 1, 127) }
        end
      end
    end
  end

  for i = 0, (cccnt or 0) - 1 do
    local ok, sel, mute, ppq, chanmsg, chan, m2, m3 = reaper.MIDI_GetCC(take, i)
    if ok then
      local ts = reaper.MIDI_GetProjTimeFromPPQPos(take, ppq)
      if ts then
        if ts < pos then
          dropped = dropped + 1
        else
          local shape, bezt = 0, 0.0
          if reaper.MIDI_GetCCShape then
            local ok2, sh, bz = reaper.MIDI_GetCCShape(take, i)
            if ok2 then shape, bezt = sh, bz end
          end
          ccs[#ccs + 1] = { sel = sel, mute = mute, ts = ts,
                            chanmsg = math.floor(chanmsg or 0xB0),
                            chan = clamp(chan, 0, 15),
                            m2 = clamp(m2, 0, 127), m3 = clamp(m3, 0, 127),
                            shape = shape, bezt = bezt }
        end
      end
    end
  end

  for i = 0, (textcnt or 0) - 1 do
    local ok, sel, mute, ppq, typ, msg = reaper.MIDI_GetTextSysexEvt(take, i)
    if ok and msg then
      local ts = reaper.MIDI_GetProjTimeFromPPQPos(take, ppq)
      if ts then
        if ts < pos then
          dropped = dropped + 1
        else
          texts[#texts + 1] = { sel = sel, mute = mute, ts = ts,
                                typ = typ, msg = msg }
        end
      end
    end
  end

  return notes, ccs, texts, dropped
end

local function InjectEvents(final_take, notes, ccs, texts)
  local failed = 0

  for _, n in ipairs(notes) do
    local s = reaper.MIDI_GetPPQPosFromProjTime(final_take, n.ts)
    local e = reaper.MIDI_GetPPQPosFromProjTime(final_take, n.te)
    local ok = false
    if s and e then
      if e <= s then e = s + 1 end
      ok = reaper.MIDI_InsertNote(final_take, n.sel, n.mute, s, e,
                                  n.chan, n.pitch, n.vel, true)
    end
    if not ok then failed = failed + 1 end
  end

  for _, c in ipairs(ccs) do
    local p = reaper.MIDI_GetPPQPosFromProjTime(final_take, c.ts)
    local ok = false
    if p then
      ok = reaper.MIDI_InsertCC(final_take, c.sel, c.mute, p,
                                c.chanmsg, c.chan, c.m2, c.m3, true)
    end
    if not ok then failed = failed + 1 end
  end

  for _, t in ipairs(texts) do
    local p = reaper.MIDI_GetPPQPosFromProjTime(final_take, t.ts)
    local ok = false
    if p then
      ok = reaper.MIDI_InsertTextSysexEvt(final_take, t.sel, t.mute,
                                          p, t.typ, t.msg, true)
    end
    if not ok then failed = failed + 1 end
  end

  if reaper.MIDI_Sort then reaper.MIDI_Sort(final_take) end

  if #ccs > 0 and reaper.MIDI_SetCCShape then
    local _, _, cccnt2 = reaper.MIDI_CountEvts(final_take)
    if (cccnt2 or 0) == #ccs then
      for i, c in ipairs(ccs) do
        if c.shape ~= 0 or c.bezt ~= 0.0 then
          reaper.MIDI_SetCCShape(final_take, i - 1, c.shape, c.bezt)
        end
      end
    end
  end

  return failed
end

-- ================= PATH A: per-item rebuild =================

local function ProcessItem(item, R, temp_path, ctx)
  local take = reaper.GetActiveTake(item)
  if not take or not reaper.TakeIsMIDI(take) then
    return "skip", "not a MIDI item"
  end
  if reaper.CountTakes(item) > 1 then
    return "skip", "item has multiple takes (glue to one take first)"
  end

  local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  if len <= 0.001 then return "skip", "item has no length" end

  -- PHASE 0: boundary snap BEFORE any tempo decisions, so the local
  -- tempo is read from the region the item actually sits in
  local snap_msg = nil
  if CONFIG.snap_boundaries then
    snap_msg = SnapBoundaries(item, take)
    -- re-read: the snap may have moved the item
    pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  end

  local track = reaper.GetMediaItemTrack(item)

  local old_bpm = TakeGridBPM(take)
  if not old_bpm then return "skip", "could not measure the take's grid" end

  local eff_rate, ipr, tpr = GetEffectiveRate(item, take)

  local lbpm, lnum, lden = GetLocalTempoAtTime(pos)

  local start_offs = 0
  if reaper.GetMediaItemTakeInfo_Value then
    local v = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
    if v and v > 0 then start_offs = v end
  end

  local line1 = string.format(
    "item @ %.3fs len %.3fs: take grid %.3f BPM, local %.3f BPM (%d/%d), ratio %.4f",
    pos, len, old_bpm, lbpm, lnum, lden, lbpm / old_bpm)
  if math.abs(eff_rate - 1.0) > CONFIG.tolerance then
    line1 = line1 .. string.format(
      ", playback rate %.4f (item %.3f x take %.3f, baked ~%.3f BPM)",
      eff_rate, ipr, tpr, old_bpm / eff_rate)
  end
  if start_offs > 0.0005 then
    line1 = line1 .. string.format(", take offset %.3fs (shared source)", start_offs)
  end
  if snap_msg then
    line1 = line1 .. "\n      " .. snap_msg
  end

  if CONFIG.skip_if_conforms and not CONFIG.force_rebuild then
    local conforms, why = TakeConforms(take, pos, lbpm, lnum, lden, R,
                                       old_bpm, eff_rate)
    if conforms then
      return "same", line1 .. "\n      already conforms (" .. why .. ") - left untouched"
    end
  end

  local is_looped, audible_iter, loop_diag = AnalyzeLoop(item, take, len)

  if is_looped then
    if not CONFIG.preserve_loops then
      return "skip", line1 .. "\n      loops its source and preserve_loops = false"
    end
    if start_offs > 0.0005 then
      return "skip", line1 ..
        "\n      looped item with a take offset (split loop piece): not safe to" ..
        "\n      rebuild automatically - glue it manually first if needed"
    end
  end

  local rebuild_size = is_looped and audible_iter or len

  local notes, ccs, texts, dropped = SnapshotEvents(take, pos)

  local file_data, bpm_file, eot_ticks =
    BuildBlankSMF(lbpm, lnum, lden, rebuild_size, R)
  local f = io.open(temp_path, "wb")
  if not f then return "error", line1 .. "\n      cannot write temp file" end
  f:write(file_data)
  f:close()

  local loopsrc = reaper.GetMediaItemInfo_Value(item, "B_LOOPSRC")
  local imute   = reaper.GetMediaItemInfo_Value(item, "D_MUTE")
  local ivol    = reaper.GetMediaItemInfo_Value(item, "D_VOL")
  local icol    = reaper.GetMediaItemInfo_Value(item, "I_CUSTOMCOLOR")
  local _, take_name = reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
  take_name = take_name or ""

  local _, track_name = reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
  local auto_mode = reaper.GetTrackAutomationMode(track)

  reaper.SetOnlyTrackSelected(track)
  reaper.Main_OnCommand(40289, 0)                 -- Item: Unselect all items
  reaper.SetEditCurPos(pos, false, false)
  reaper.InsertMedia(temp_path, 0)

  local new_item = reaper.GetSelectedMediaItem(0, 0)
  if not new_item or reaper.GetMediaItemTrack(new_item) ~= track then
    reaper.SetTrackAutomationMode(track, auto_mode)
    return "error", line1 .. "\n      InsertMedia failed (no item on the target track)"
  end
  ctx.final_item = new_item

  reaper.SetMediaItemInfo_Value(new_item, "C_BEATATTACHMODE", 0)
  reaper.SetMediaItemInfo_Value(new_item, "D_POSITION", pos)
  reaper.SetMediaItemInfo_Value(new_item, "D_LENGTH", rebuild_size)
  reaper.SetMediaItemInfo_Value(new_item, "B_LOOPSRC", 0)

  local sws = reaper.NamedCommandLookup("_BR_ME_TOGGLE_IGNORE_TEMPO_PO_START")
  if sws ~= 0 then reaper.Main_OnCommand(sws, 0) end

  reaper.Main_OnCommand(40401, 0)   -- convert active take MIDI to in-project

  local final_item = new_item
  if CONFIG.use_glue then
    reaper.Main_OnCommand(41588, 0) -- glue items, ignoring time selection
    local glued = reaper.GetSelectedMediaItem(0, 0)
    if ptr_ok(glued) and reaper.GetMediaItemTrack(glued) == track then
      final_item = glued
    end
  end
  ctx.final_item = final_item

  reaper.SetMediaItemInfo_Value(final_item, "C_BEATATTACHMODE", 0)
  reaper.SetMediaItemInfo_Value(final_item, "D_POSITION", pos)
  reaper.SetMediaItemInfo_Value(final_item, "D_LENGTH", rebuild_size)
  reaper.SetMediaItemInfo_Value(final_item, "D_MUTE", imute)
  reaper.SetMediaItemInfo_Value(final_item, "D_VOL", ivol)
  reaper.SetMediaItemInfo_Value(final_item, "I_CUSTOMCOLOR", icol)
  -- the fresh item plays at rate 1.0: any rate compensation of the
  -- original has been absorbed by re-baking at the local tempo and
  -- re-timing the notes through their audible positions

  local final_take = reaper.GetActiveTake(final_item)
  if not final_take then
    reaper.DeleteTrackMediaItem(track, final_item)
    ctx.final_item = nil
    reaper.SetTrackAutomationMode(track, auto_mode)
    return "error", line1 .. "\n      rebuilt item has no take"
  end
  reaper.GetSetMediaItemTakeInfo_String(final_take, "P_NAME", take_name, true)

  local final_grid = TakeGridBPM(final_take)
  local src = reaper.GetMediaItemTake_Source(final_take)
  local src_len = src and reaper.GetMediaSourceLength(src) or 0

  local failed = InjectEvents(final_take, notes, ccs, texts)
  if failed > 0 then
    reaper.DeleteTrackMediaItem(track, final_item)
    ctx.final_item = nil
    reaper.SetTrackAutomationMode(track, auto_mode)
    return "error", line1 .. string.format(
      "\n      event injection failed for %d events (original item left untouched)", failed)
  end

  -- verify audible positions (before the grid snap)
  local verify_msg, verify_bad = "", false
  if #notes == 0 then
    verify_msg = "empty item (blank rebuild only)"
  else
    local final_times = {}
    local _, notecnt2 = reaper.MIDI_CountEvts(final_take)
    for i = 0, (notecnt2 or 0) - 1 do
      local ok, sel, mute, s, e = reaper.MIDI_GetNote(final_take, i)
      if ok then
        local ts = reaper.MIDI_GetProjTimeFromPPQPos(final_take, s)
        local te = reaper.MIDI_GetProjTimeFromPPQPos(final_take, e)
        if ts and te then final_times[#final_times + 1] = { ts, te } end
      end
    end
    local function cmp(a, b)
      if a[1] ~= b[1] then return a[1] < b[1] end
      return a[2] < b[2]
    end
    table.sort(final_times, cmp)
    local orig_times = {}
    for _, n in ipairs(notes) do orig_times[#orig_times + 1] = { n.ts, n.te } end
    table.sort(orig_times, cmp)

    if #final_times ~= #orig_times then
      verify_msg = string.format(
        "WARNING: note count changed (%d -> %d)", #orig_times, #final_times)
      verify_bad = true
    else
      local max_drift = 0.0
      for i = 1, #orig_times do
        local d = math.abs(final_times[i][1] - orig_times[i][1])
        local d2 = math.abs(final_times[i][2] - orig_times[i][2])
        if d2 > d then d = d2 end
        if d > max_drift then max_drift = d end
      end
      if max_drift > 0.005 then
        verify_msg = string.format(
          "WARNING: max note drift %.1f ms", max_drift * 1000.0)
        verify_bad = true
      else
        verify_msg = string.format(
          "verified: all %d notes within %.2f ms (before grid snap)",
          #orig_times, max_drift * 1000.0)
      end
    end
  end

  -- grid snap
  local quant_msg = "grid snap: off"
  if CONFIG.quantize ~= "off" then
    local g, grid_src
    if CONFIG.quantize == "grid" and reaper.MIDI_GetGrid then
      local qn = reaper.MIDI_GetGrid(final_take)
      if qn and qn > 0 then g, grid_src = qn * R, "editor grid" end
    end
    if not g then g, grid_src = CONFIG.grid_qn * R, "config" end
    if g < 1 then g = 1 end

    local _, notecnt3, cccnt3 = reaper.MIDI_CountEvts(final_take)
    local moved_notes, moved_ccs, max_shift = 0, 0, 0.0

    for i = 0, (notecnt3 or 0) - 1 do
      local ok, sel, mute, s, e, chan, pitch, vel = reaper.MIDI_GetNote(final_take, i)
      if ok then
        local ns = SnapToGrid(s, g)
        local ne
        if CONFIG.quantize_lengths then
          ne = SnapToGrid(e, g)
        else
          ne = e + (ns - s)
        end
        if ne > eot_ticks then ne = eot_ticks end
        if ne <= ns then ne = math.min(ns + g, eot_ticks) end
        if ne <= ns then ne = ns + 1 end
        local d = math.abs(ns - s)
        local d2 = math.abs(ne - e)
        if d2 > d then d = d2 end
        if d > max_shift then max_shift = d end
        if d > 0 then
          moved_notes = moved_notes + 1
          reaper.MIDI_SetNote(final_take, i, sel, mute, ns, ne, chan, pitch, vel)
        end
      end
    end

    if CONFIG.quantize_cc then
      for i = 0, (cccnt3 or 0) - 1 do
        local ok, sel, mute, ppq, chanmsg, chan, m2, m3 = reaper.MIDI_GetCC(final_take, i)
        if ok then
          local np = SnapToGrid(ppq, g)
          local d = math.abs(np - ppq)
          if d > max_shift then max_shift = d end
          if d > 0 then
            moved_ccs = moved_ccs + 1
            reaper.MIDI_SetCC(final_take, i, sel, mute, np, chanmsg, chan, m2, m3)
          end
        end
      end
    end

    if reaper.MIDI_Sort then reaper.MIDI_Sort(final_take) end

    quant_msg = string.format(
      "grid snap: %s (%s) | %d notes + %d CC moved | max shift %.1f ticks (%.2f ms)",
      GridLabel(g / R), grid_src, moved_notes, moved_ccs, max_shift,
      max_shift * (60.0 / bpm_file) / R * 1000.0)
  end

  -- restore looping
  local loopsrc_msg
  if is_looped then
    reaper.SetMediaItemInfo_Value(final_item, "D_LENGTH", len)
    reaper.SetMediaItemInfo_Value(final_item, "B_LOOPSRC", 1)
    loopsrc_msg = string.format("on (%.2f iterations, partial %.3fs)",
                                len / audible_iter, len % audible_iter)
  elseif loopsrc == 1 and src_len > 0 and src_len >= (len - 0.05) then
    reaper.SetMediaItemInfo_Value(final_item, "B_LOOPSRC", 1)
    loopsrc_msg = "on"
  else
    reaper.SetMediaItemInfo_Value(final_item, "B_LOOPSRC", 0)
    loopsrc_msg = "off"
  end

  reaper.DeleteTrackMediaItem(track, item)

  local _, track_name_now = reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
  if track_name_now ~= track_name then
    reaper.GetSetMediaTrackInfo_String(track, "P_NAME", track_name, true)
  end
  reaper.SetTrackAutomationMode(track, auto_mode)
  if reaper.MarkProjectDirty then reaper.MarkProjectDirty() end

  -- hard-failure conditions -> "error" state (always printed, even silent)
  local hard_fail = verify_bad
  local hard_lines = ""
  if final_grid and math.abs(final_grid - lbpm) > CONFIG.tolerance then
    hard_fail = true
    hard_lines = hard_lines .. string.format(
      "\n      ERROR: final take grid is %.3f BPM, expected %.3f - tempo bake did not stick",
      final_grid, lbpm)
  end
  local loop_verified_line = ""
  if is_looped then
    if src_len > 0.05 and math.abs(src_len - audible_iter) > 0.05 then
      hard_fail = true
      hard_lines = hard_lines .. string.format(
        "\n      ERROR: rebuilt source is %.3fs but one iteration should be %.3fs" ..
        " - the restored looping has wrong boundaries", src_len, audible_iter)
    else
      loop_verified_line = string.format(
        "\n      loop verified: rebuilt source %.3fs = one iteration", src_len)
    end
  end

  -- soft notes -> verbose only
  local notes_txt = ""
  if math.abs(eff_rate - 1.0) > CONFIG.tolerance then
    notes_txt = notes_txt .. string.format(
      "\n      rate normalized: %.4f -> 1.0000 (baked ~%.3f -> %.3f BPM)",
      eff_rate, old_bpm / eff_rate, final_grid or lbpm)
  end
  if loopsrc == 1 and not is_looped then
    notes_txt = notes_txt ..
      "\n      note: B_LOOPSRC was on but the loop analysis said 'not looped'"
  end
  if dropped > 0 then
    notes_txt = notes_txt .. string.format(
      "\n      note: %d events map before this item's start and were not carried" ..
      " over (take offset %.3fs - split/loop piece sharing its source with a" ..
      " neighbor; this item's own playback is unchanged)", dropped, start_offs)
  end

  local line2 = string.format(
      "      blank rebuild%s: final grid %s, source %.3fs, EoT %d ticks @ %.3f BPM",
      CONFIG.use_glue and "" or " (no glue)",
      final_grid and string.format("%.3f BPM", final_grid) or "?",
      src_len, eot_ticks, bpm_file)
  local line3 = string.format(
      "      injected: %d notes, %d CC, %d text/sysex | item %.3fs, loopsrc %s | %s",
      #notes, #ccs, #texts, len, loopsrc_msg, verify_msg)

  local msg = line1 .. "\n      " .. loop_diag .. "\n" .. line2 .. "\n" ..
              line3 .. "\n      " .. quant_msg .. loop_verified_line ..
              notes_txt .. hard_lines

  if hard_fail then return "error", msg end
  return "ok", msg
end

-- ================= PATH B: insert blank local item =================

-- orig_track may be nil: a new track is spawned at the end of the track
-- list and used as the insert target (repository fallback conventions)
local function InsertBlankLocalItem(orig_track, sel_start, sel_end, R, temp_path,
                                    default_auto_mode, ctx)
  local track = orig_track
  local spawned = nil
  if not track then
    spawned = SpawnTrackAtEnd()
    if not spawned then
      return false, "could not create a new track for the insert"
    end
    track = spawned
    ctx.spawned_track = spawned
  end
  reaper.SetOnlyTrackSelected(track)

  local item_len = sel_end - sel_start
  local lbpm, lnum, lden = GetLocalTempoAtTime(sel_start)

  local original_auto = reaper.GetTrackAutomationMode(track)
  local _, track_name_orig = reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
  track_name_orig = track_name_orig or ""
  local name_was_empty = (track_name_orig == "")

  local file_data, bpm_file, eot_ticks =
    BuildBlankSMF(lbpm, lnum, lden, item_len, R)
  local f = io.open(temp_path, "wb")
  if not f then return false, "cannot write temp file" end
  f:write(file_data)
  f:close()

  reaper.Main_OnCommand(40289, 0)                 -- Item: Unselect all items
  reaper.SetEditCurPos(sel_start, false, false)
  reaper.InsertMedia(temp_path, 0)

  local imported = reaper.GetSelectedMediaItem(0, 0)
  if not imported then
    reaper.SetTrackAutomationMode(track, original_auto)
    return false, "InsertMedia failed (no item created)"
  end
  ctx.inserted_item = imported

  local actual_track = reaper.GetMediaItemTrack(imported)
  local is_new_track = (spawned ~= nil) or (actual_track ~= track)

  reaper.SetMediaItemInfo_Value(imported, "C_BEATATTACHMODE", 0)
  reaper.SetMediaItemInfo_Value(imported, "D_POSITION", sel_start)
  reaper.SetMediaItemInfo_Value(imported, "D_LENGTH", item_len)

  local sws = reaper.NamedCommandLookup("_BR_ME_TOGGLE_IGNORE_TEMPO_PO_START")
  if sws ~= 0 then reaper.Main_OnCommand(sws, 0) end

  reaper.Main_OnCommand(40401, 0)   -- convert active take MIDI to in-project
  if CONFIG.use_glue then
    reaper.Main_OnCommand(41588, 0) -- glue items, ignoring time selection
  end

  local final = reaper.GetSelectedMediaItem(0, 0)
  if not ptr_ok(final) then final = imported end
  ctx.inserted_item = final

  reaper.SetMediaItemInfo_Value(final, "C_BEATATTACHMODE", 0)
  reaper.SetMediaItemInfo_Value(final, "D_POSITION", sel_start)
  reaper.SetMediaItemInfo_Value(final, "D_LENGTH", item_len)
  reaper.SetMediaItemInfo_Value(final, "B_LOOPSRC", 1)  -- edge-drag looping

  local final_take = reaper.GetActiveTake(final)
  if not final_take then
    return false, "inserted item has no take (?)"
  end

  -- naming + automation (repository conventions)
  local track_idx = math.floor(reaper.GetMediaTrackInfo_Value(actual_track, "IP_TRACKNUMBER"))
  local idx_str = string.format("%02d", track_idx)
  local take_name, extra
  if is_new_track then
    take_name = string.format("%s-MIDI", idx_str)
    reaper.GetSetMediaTrackInfo_String(actual_track, "P_NAME", "", true)
    reaper.SetTrackAutomationMode(actual_track, default_auto_mode)
    extra = spawned and " (new track spawned)" or " (new fallback track)"
  elseif name_was_empty then
    take_name = string.format("%s-MIDI", idx_str)
    reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", true)
  else
    take_name = string.format("%s-%s-MIDI", idx_str, track_name_orig)
  end
  reaper.GetSetMediaItemTakeInfo_String(final_take, "P_NAME", take_name, true)

  if not is_new_track then
    reaper.SetTrackAutomationMode(track, original_auto)
  elseif orig_track and orig_track ~= actual_track then
    reaper.SetTrackAutomationMode(orig_track, original_auto)
  end

  -- verify the bake (hard failure if wrong)
  local grid = TakeGridBPM(final_take)
  if grid and math.abs(grid - lbpm) > CONFIG.tolerance then
    return false, string.format(
      "inserted item's baked grid is %.3f BPM, expected %.3f", grid, lbpm)
  end

  ctx.short = string.format(
    "inserted blank item @ %.3fs len %.3fs @ %.3f BPM (%d/%d)%s",
    sel_start, item_len, lbpm, lnum, lden, extra or "")

  return true, string.format(
    "inserted blank item @ %.3fs len %.3fs @ %.3f BPM (%d/%d)" ..
    " | take \"%s\"%s | baked grid %s",
    sel_start, item_len, lbpm, lnum, lden, take_name, extra or "",
    grid and string.format("%.3f BPM", grid) or "?")
end

-- ================= main =================

local function Main()
  local needed = { "MIDI_GetProjTimeFromPPQPos", "MIDI_GetPPQPosFromProjTime",
    "MIDI_CountEvts", "MIDI_GetNote", "MIDI_SetNote", "MIDI_InsertNote",
    "MIDI_GetCC", "MIDI_SetCC", "MIDI_InsertCC", "MIDI_SetCCShape",
    "MIDI_GetTextSysexEvt", "MIDI_InsertTextSysexEvt", "MIDI_Sort",
    "InsertMedia", "FindTempoTimeSigMarker", "GetTempoTimeSigMarker",
    "GetMediaItemTake_Source", "GetMediaSourceLength",
    "TimeMap2_GetDividedBpmAtTime", "GetSet_LoopTimeRange", "ValidatePtr",
    "SetMediaItemSelected" }
  for _, fn in ipairs(needed) do
    if not reaper[fn] then
      reaper.MB("This REAPER build is missing API function: " .. fn, "Local BPM Unified", 0)
      return
    end
  end

  if CONFIG.quantize ~= "off" and CONFIG.quantize ~= "tick"
     and CONFIG.quantize ~= "grid" then CONFIG.quantize = "grid" end

  -- capture invocation-time context BEFORE anything touches state
  local n_items = reaper.CountSelectedMediaItems(0)
  local sel_start, sel_end = ReadTimeSelection()
  local insert_track = reaper.GetSelectedTrack(0, 0)

  if n_items == 0 and not sel_start then
    reaper.MB("Select MIDI items to rebuild, and/or set a time selection\n" ..
              "to insert a new blank MIDI item with the local tempo.",
              "Local BPM Unified", 0)
    return
  end

  local R, have_sws, default_auto_mode = 960, false, 0
  if reaper.SNM_GetIntConfigVar then
    have_sws = true
    local v = reaper.SNM_GetIntConfigVar("miditicksperqn", 960)
    if v and v > 0 then R = v end
    local m = reaper.SNM_GetIntConfigVar("launchnewtrkmode", 0)
    if m and m >= 0 then default_auto_mode = m end
  end
  R = clamp(math.floor(R), 96, 32767)

  local temp_path
  do
    local stamp = tostring(os.time()) .. "_" .. tostring(math.floor(os.clock() * 1000))
    local cand = { reaper.GetResourcePath() .. "/temp_localbpm_" .. stamp .. ".mid" }
    local env = os.getenv("TEMP") or os.getenv("TMPDIR") or os.getenv("TMP") or "/tmp"
    cand[#cand + 1] = env .. "/temp_localbpm_" .. stamp .. ".mid"
    for _, p in ipairs(cand) do
      local f = io.open(p, "wb")
      if f then f:close() temp_path = p break end
    end
  end
  if not temp_path then
    reaper.MB("Could not find a writable folder for the temp MIDI file.", "Local BPM Unified", 0)
    return
  end

  local items = {}
  for i = 0, n_items - 1 do items[#items + 1] = reaper.GetSelectedMediaItem(0, i) end
  local sel_tracks = {}
  for i = 0, reaper.CountSelectedTracks(0) - 1 do
    sel_tracks[#sel_tracks + 1] = reaper.GetSelectedTrack(0, i)
  end
  local cursor = reaper.GetCursorPosition()

  if CONFIG.verbose then
    if reaper.ClearConsole then reaper.ClearConsole() end
    reaper.ShowConsoleMsg("Local BPM unified: rebuild selected items + insert blank local item\n")
    reaper.ShowConsoleMsg(string.format(
      "PPQ %d | SWS %s | glue: %s (required) | skip conforming: %s (meter: %s," ..
      " rate normalization: %s) | quantize: %s | insert w/o track: %s (spawns new track)\n",
      R, have_sws and "found" or "NOT found",
      CONFIG.use_glue and "on" or "OFF (!!)",
      CONFIG.skip_if_conforms and "yes" or "no",
      CONFIG.check_meter and "on" or "off",
      CONFIG.normalize_playrate and "on" or "off",
      CONFIG.quantize,
      CONFIG.insert_when_no_track_selected and "yes" or "no"))
    reaper.ShowConsoleMsg(string.format(
      "invocation: %d selected item(s), time selection %s\n\n",
      n_items, sel_start and string.format("%.3fs..%.3fs", sel_start, sel_end) or "none"))
  end

  reaper.PreventUIRefresh(1)
  reaper.Undo_BeginBlock()

  -- clear the time selection so neither path's InsertMedia can see it
  reaper.GetSet_LoopTimeRange(true, false, 0, 0, false)

  ---------- PHASE 1: rebuild selected items ----------
  local fixed, conformed, skipped, errors = 0, 0, 0, 0
  local results = {}

  for i, item in ipairs(items) do
    local tag = string.format("[A%d/%d] ", i, #items)
    local ctx = {}
    local ok, state, msg = pcall(ProcessItem, item, R, temp_path, ctx)
    if not ok then
      errors = errors + 1
      results[i] = ptr_ok(ctx.final_item) and ctx.final_item
                 or (ptr_ok(item) and item or nil)
      err(tag .. "ERROR: " .. tostring(state) .. "\n")
    elseif state == "error" then
      errors = errors + 1
      results[i] = ptr_ok(ctx.final_item) and ctx.final_item
                 or (ptr_ok(item) and item or nil)
      err(tag .. "ERROR: " .. tostring(msg) .. "\n")
    elseif state == "ok" then
      fixed = fixed + 1
      results[i] = ptr_ok(ctx.final_item) and ctx.final_item
                 or (ptr_ok(item) and item or nil)
      log(tag .. (msg or "rebuilt") .. "\n")
    elseif state == "same" then
      conformed = conformed + 1
      results[i] = ptr_ok(item) and item or nil
      log(tag .. (msg or "already conforms") .. "\n")
    else
      skipped = skipped + 1
      results[i] = ptr_ok(item) and item or nil
      log(tag .. "skipped: " .. tostring(msg) .. "\n")
    end
  end

  -- restore the ORIGINAL track selection (or clear it entirely when
  -- nothing was selected) so Phase B targets the right track - or spawns
  -- a new one - never a track Phase A happened to leave selected
  if #sel_tracks > 0 then
    reaper.SetOnlyTrackSelected(sel_tracks[1])
    for j = 2, #sel_tracks do reaper.SetTrackSelected(sel_tracks[j], true) end
  else
    for t = 0, reaper.CountTracks(0) - 1 do
      reaper.SetTrackSelected(reaper.GetTrack(0, t), false)
    end
  end

  ---------- PHASE 2: insert blank local item ----------
  local inserted = 0
  local insert_msg = "no time selection"
  local ictx = {}
  if sel_start and sel_end then
    if not insert_track and not CONFIG.insert_when_no_track_selected then
      insert_msg = "time selection present but no track selected - skipped"
    else
      local pok, succ, msg = pcall(InsertBlankLocalItem, insert_track,
                                   sel_start, sel_end, R, temp_path,
                                   default_auto_mode, ictx)
      if not pok then
        insert_msg = "ERROR: " .. tostring(succ)
        err("[B] ERROR: " .. tostring(succ) .. "\n")
      elseif succ then
        inserted = 1
        insert_msg = ictx.short or tostring(msg)
        log("[B] " .. tostring(msg) .. "\n")
      else
        insert_msg = "ERROR: " .. tostring(msg)
        err("[B] ERROR: " .. tostring(msg) .. "\n")
      end
    end
  end

  ---------- restore environment ----------
  reaper.SetEditCurPos(cursor, false, false)

  if sel_start and sel_end then
    if inserted > 0 and CONFIG.consume_selection_after_insert then
      reaper.GetSet_LoopTimeRange(true, false, 0, 0, false)
    else
      reaper.GetSet_LoopTimeRange(true, false, sel_start, sel_end, false)
    end
  end

  -- final track selection: the spawned track (if one was created) stays
  -- selected; otherwise the original selection is restored
  if ictx.spawned_track and tptr_ok(ictx.spawned_track) then
    reaper.SetOnlyTrackSelected(ictx.spawned_track)
  elseif #sel_tracks > 0 then
    reaper.SetOnlyTrackSelected(sel_tracks[1])
    for j = 2, #sel_tracks do reaper.SetTrackSelected(sel_tracks[j], true) end
  else
    for t = 0, reaper.CountTracks(0) - 1 do
      reaper.SetTrackSelected(reaper.GetTrack(0, t), false)
    end
  end

  reaper.Main_OnCommand(40289, 0)
  for i = 1, #results do
    if results[i] then reaper.SetMediaItemSelected(results[i], true) end
  end
  if ictx.inserted_item and ptr_ok(ictx.inserted_item) then
    reaper.SetMediaItemSelected(ictx.inserted_item, true)
  end

  pcall(os.remove, temp_path)

  reaper.Undo_EndBlock("Local BPM unified: rebuild MIDI items + insert blank local item", -1)
  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()

  log(string.format(
    "\nPhase A (rebuild): %d rebuilt, %d conformed (untouched), %d skipped, %d errors.\n",
    fixed, conformed, skipped, errors))
  log(string.format("Phase B (insert): %s\n", insert_msg))
end

Main()