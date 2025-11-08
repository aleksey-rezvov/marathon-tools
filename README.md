# marathon_render.sh

Two-phase FFmpeg pipeline for long marathon-style recordings:

- `analyze` — scan clips, compute per-file stabilization transforms, build timeline plan (supports optional window).
- `render` — use `plan.csv` to render final stabilized video (full or time window).
- `debug` — fast per-window check: split-screen (orig vs stab) + separate orig/stab clips.

All code and comments in the script are in English.

---

## Key environment variables

- `LOGO` — path to PNG watermark (default: `/home/arezvov/Pictures/funkcio-title.png`)
- `SHAKINESS` — `vidstabdetect` shakiness, 1–10 (default: `10`)
- `ACCURACY` — `vidstabdetect` accuracy, 1–15 (default: `15`)
- `SMOOTH` — `vidstabtransform` smoothing, typical 25–40 (default: `35`)
- `ZOOM` — stabilization zoom to hide borders (default: `1`)
- `UNSHARP` — sharpening filter (default: `5:5:0.8:3:3:0.4`)
- `SCALE` — output size, e.g. `1920:-2`, empty = keep source
- `CODEC` — `h264` or `h265` (default: `h264`)
- `CRF_H264` / `CRF_H265` — quality (lower = better), defaults `22` / `24`
- `PRESET` — encoder preset (`slow` final, `fast/veryfast` debug)
- `MAXRATE` / `BUFSIZE` — VBV settings (defaults: `8M` / `16M`)
- `AUDIO_BR` — AAC bitrate (default: `128k`)
- `FORCE` — `1` to recompute `.trf` in `analyze`, else reuse
- `PLAN_CSV` / `PLAN_JSON` — plan filenames in `work_dir`
- `TRF_DIRNAME` — transforms subdir (default: `trf`)

---

## 1. Analyze

### Full timeline (one-time before final render)

Analyzes **entire files** (slow but high quality):

```
./marathon_render.sh analyze \
  "/media/arezvov/2004-1014/VIDEO" \
  "/media/arezvov/arezvov_more/video/istanbul_marathon_2025/work"
```

Creates `.trf` files for full files.

### Windowed analyze (quick test, fast)

Analyzes **only the specified window** (fast):

```
./marathon_render.sh analyze \
  "/media/arezvov/2004-1014/VIDEO" \
  "/media/arezvov/arezvov_more/video/istanbul_marathon_2025/work_window_30m_5m" \
  --from 00:30:00 \
  --dur 300
```

Creates window-specific `.trf` files (e.g., `file_w1800_300.trf`). These can only be used with `render` for the **same window**.

---

## 2. Render (production)

Uses `PLAN_CSV` in `work_dir` created by `analyze`.

### Full marathon, H.264

```
LOGO="/home/arezvov/Pictures/funkcio-title.png" \
CRF_H264=22 PRESET=slow SCALE=1920:-2 \
./marathon_render.sh render \
  "/media/arezvov/arezvov_more/video/istanbul_marathon_2025/work" \
  "/media/arezvov/arezvov_more/video/istanbul_marathon_2025/marathon_full_stabilized_h264.mp4"
```

### Selected time window from full plan

Example: `00:30:00` + `300s` from the global timeline:

```
./marathon_render.sh render \
  "/media/arezvov/arezvov_more/video/istanbul_marathon_2025/work" \
  "/media/arezvov/arezvov_more/video/istanbul_marathon_2025/marathon_30m_5m.mp4" \
  --from 00:30:00 \
  --dur 300
```

---

## 3. Debug (per-window tuning)

Fast stabilization quality check on a small window. Analyzes **only the window** (like windowed analyze).

Produces three outputs:
- `*_split.mp4` — left: original, right: stabilized, with watermark.
- `*_split_orig.mp4` — original-only window.
- `*_split_stab.mp4` — stabilized-only window (same filters as `render`).

Example: 10s from `00:31:00`:

```
LOGO="/home/arezvov/Pictures/funkcio-title.png" \
./marathon_render.sh debug \
  "/media/arezvov/2004-1014/VIDEO" \
  "/media/arezvov/arezvov_more/video/istanbul_marathon_2025/work" \
  "/media/arezvov/arezvov_more/video/istanbul_marathon_2025/debug_31m00s_10s_split.mp4" \
  --from 00:31:00 \
  --dur 10
```

Creates `.debug.trf` files (separate from analyze). Use `debug` to dial in `SMOOTH`, `ZOOM`, `UNSHARP`, then run full `analyze` → `render`.
