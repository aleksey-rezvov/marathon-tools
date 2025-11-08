#!/usr/bin/env bash
# ===============================================================
# marathon_render.sh — Two-phase pipeline: analyze, render, debug
#
# Modes:
#   analyze <input_dir> <work_dir> [--from HH:MM:SS] [--dur SECS]
#     - Scan .mov/.MOV files in input_dir (sorted)
#     - For files that overlap the optional [from, from+dur) window:
#         * ffprobe duration
#         * vidstabdetect per file -> work/trf/*.trf  (FULL file, no trimming)
#     - Build plan.csv / plan.json with GLOBAL timeline:
#         index,file,transform,duration,start,end
#       where start/end are seconds from the beginning of shooting.
#       With --from/--dur only overlapping files are included,
#       but start/end stay global.
#
#   render <work_dir> <output_mp4> [--from HH:MM:SS] [--dur SECS]
#     - Read plan.csv (global timeline)
#     - --from/--dur are in same global coords
#     - For each segment:
#         trim -> vidstabtransform -> unsharp -> optional scale
#         audio -> mono 48k
#     - Concatenate, add watermark once, encode H.264/H.265.
#
#   debug <input_dir> <work_dir> <split_output_mp4> [--from HH:MM:SS] [--dur SECS]
#     - Self-contained test on a window (no plan.csv):
#         * find overlapping fragments
#         * vidstabdetect on that window only -> *.debug.trf
#         * outputs:
#             1) split_output_mp4         : split-screen (left=orig, right=stab, with logo)
#             2) split_output_mp4_orig    : original-only
#             3) split_output_mp4_stab    : stabilized-only
#
# All code & comments in English.
# ===============================================================

set -euo pipefail
export LC_ALL=C

# =================== Configuration (env overrides) ===================

# PNG watermark path (recommend ~200–400px wide, non-HDR)
LOGO="${LOGO:-/home/arezvov/Pictures/funkcio-title.png}"

# vidstabdetect: camera shake level (1–10); 8–10 for running/handheld
SHAKINESS="${SHAKINESS:-10}"

# vidstabdetect: analysis accuracy (1–15); higher = better, slower
ACCURACY="${ACCURACY:-15}"

# vidstabtransform: stabilization smoothing; 25–40 typical for running
SMOOTH="${SMOOTH:-35}"

# vidstabtransform: auto zoom to hide borders; 3–8 typical
ZOOM="${ZOOM:-1}"

# Post-stabilization unsharp filter; reduce if footage is noisy
UNSHARP="${UNSHARP:-5:5:0.8:3:3:0.4}"

# Output resolution; "1920:-2" for 1080p, empty to keep native
SCALE="${SCALE:-1920:-2}"

# Video codec: h264 (compat, faster) or h265 (smaller, slower)
CODEC="${CODEC:-h264}"

# H.264 quality (lower = better); 18–24 typical, 20–22 recommended
CRF_H264="${CRF_H264:-22}"

# H.265 quality (lower = better); 18–26 typical, 22–24 recommended
CRF_H265="${CRF_H265:-24}"

# Encoder speed/efficiency; slow/medium for final, fast/veryfast for debug
PRESET="${PRESET:-slow}"

# Max video bitrate (VBV); 8–12M good for 1080p YouTube-style
MAXRATE="${MAXRATE:-8M}"

# VBV buffer size; usually ~2x MAXRATE
BUFSIZE="${BUFSIZE:-16M}"

# AAC audio bitrate; 128k speech, 160–192k richer ambience
AUDIO_BR="${AUDIO_BR:-128k}"

# 1 = recompute .trf files in analyze; 0 = reuse existing transforms
FORCE="${FORCE:-0}"

# CSV render plan filename in work_dir
PLAN_CSV="${PLAN_CSV:-plan.csv}"

# JSON render plan filename in work_dir (for inspection/tools)
PLAN_JSON="${PLAN_JSON:-plan.json}"

# Subdirectory in work_dir for stabilization .trf files
TRF_DIRNAME="${TRF_DIRNAME:-trf}"

# ====================================================================

fatal(){ echo "Error: $*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage:
  $(basename "$0") analyze <input_dir> <work_dir> [--from HH:MM:SS] [--dur SECS]
  $(basename "$0") render  <work_dir> <output_mp4> [--from HH:MM:SS] [--dur SECS]
  $(basename "$0") debug   <input_dir> <work_dir> <split_output_mp4> [--from HH:MM:SS] [--dur SECS]

Notes:
  - analyze + render share a GLOBAL timeline (seconds from start of first clip).
  - For a specific window:
      analyze ... --from T --dur D
      render  ... --from T --dur D
EOF
}

ensure_tools() {
  command -v ffmpeg  >/dev/null || fatal "ffmpeg not found"
  command -v ffprobe >/dev/null || fatal "ffprobe not found"
}

collect_mov_files() {
  local dir="$1"
  find "$dir" -maxdepth 1 -type f \( -iname '*.mov' -o -iname '*.MOV' \) -print0 \
    | sort -z | tr '\0' '\n'
}

# =================== Numeric helpers ===================
to_seconds() {
  awk -F: '
    function f(x){return x+0}
    {
      if (NF==3)      printf("%.6f\n", f($1)*3600+f($2)*60+f($3));
      else if (NF==2) printf("%.6f\n", f($1)*60+f($2));
      else            printf("%.6f\n", f($1));
    }' <<<"$1"
}

float_add(){ awk -v a="$1" -v b="$2" 'BEGIN{printf("%.6f\n",a+b)}'; }
float_sub(){ awk -v a="$1" -v b="$2" 'BEGIN{printf("%.6f\n",a-b)}'; }
float_min(){ awk -v a="$1" -v b="$2" 'BEGIN{printf("%.6f\n",(a<b)?a:b)}'; }
float_max(){ awk -v a="$1" -v b="$2" 'BEGIN{printf("%.6f\n",(a>b)?a:b)}'; }
float_gt(){ awk -v a="$1" -v b="$2" 'BEGIN{exit !(a>b)}'; }

# =================== Filters / encoding helpers ===================
filter_stab_chain() {
  local trf_path="$1"
  local chain="vidstabtransform=input=${trf_path}:smoothing=${SMOOTH}:zoom=${ZOOM}:optzoom=1:crop=black"
  chain="${chain},unsharp=${UNSHARP}"
  if [[ -n "${SCALE}" ]]; then
    chain="${chain},scale=${SCALE}"
  fi
  echo "${chain}"
}

filter_orig_chain() {
  local start="$1"
  local dur="$2"
  local chain="trim=start=${start}:duration=${dur},setpts=PTS-STARTPTS"
  if [[ -n "${SCALE}" ]]; then
    chain="${chain},scale=${SCALE}"
  fi
  echo "${chain}"
}

encode_args() {
  case "${CODEC}" in
    h264)
      echo "-c:v libx264 -preset ${PRESET} -crf ${CRF_H264} -maxrate ${MAXRATE} -bufsize ${BUFSIZE} -g 240 -pix_fmt yuv420p"
      ;;
    h265|hevc)
      echo "-c:v libx265 -preset ${PRESET} -crf ${CRF_H265} -tag:v hvc1 -pix_fmt yuv420p -x265-params keyint=240:min-keyint=24:bframes=6:rc-lookahead=40"
      ;;
    *)
      fatal "Unknown CODEC='${CODEC}'. Use h264 or h265."
      ;;
  esac
}

# =================== Common helper functions ===================

# Parse --from/--dur arguments
# Returns via stdout: WINDOWED WIN_FROM WIN_DUR WIN_TO
parse_window_args() {
  local WINDOWED=0 WIN_FROM="" WIN_DUR="" WIN_TO=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --from) WIN_FROM="$(to_seconds "$2")"; WINDOWED=1; shift 2;;
      --dur)  WIN_DUR="$(to_seconds "$2")";  WINDOWED=1; shift 2;;
      *) fatal "Unknown window arg: $1";;
    esac
  done
  if [[ "$WINDOWED" -eq 1 ]]; then
    [[ -n "$WIN_FROM" && -n "$WIN_DUR" ]] || fatal "Both --from and --dur are required in window mode"
    WIN_TO="$(float_add "$WIN_FROM" "$WIN_DUR")"
  fi
  printf 'WINDOWED=%s\n' "$WINDOWED"
  printf 'WIN_FROM=%s\n' "$WIN_FROM"
  printf 'WIN_DUR=%s\n' "$WIN_DUR"
  printf 'WIN_TO=%s\n' "$WIN_TO"
}

# Calculate overlap between file and window
# Args: file_start file_end window_start window_end
# Returns via stdout: OVERLAP_START OVERLAP_END OVERLAP_DUR LOCAL_START HAS_OVERLAP
calculate_window_overlap() {
  local fstart="$1" fend="$2" wstart="$3" wend="$4"
  local os oe od ls has_overlap=0
  
  os=$(float_max "$fstart" "$wstart")
  oe=$(float_min "$fend" "$wend")
  od=$(float_sub "$oe" "$os")
  ls=$(float_sub "$os" "$fstart")
  
  if float_gt "$od" "0.000001"; then
    has_overlap=1
  fi
  
  printf 'OVERLAP_START=%s\n' "$os"
  printf 'OVERLAP_END=%s\n' "$oe"
  printf 'OVERLAP_DUR=%s\n' "$od"
  printf 'LOCAL_START=%s\n' "$ls"
  printf 'HAS_OVERLAP=%s\n' "$has_overlap"
}

# Run vidstabdetect on FULL file (no trimming)
run_vidstabdetect_full() {
  local input_file="$1" trf_file="$2"
  ffmpeg -hide_banner -nostdin -stats -loglevel info -progress pipe:2 \
    -fflags +genpts+discardcorrupt -err_detect ignore_err \
    -i "$input_file" \
    -vf "vidstabdetect=shakiness=${SHAKINESS}:accuracy=${ACCURACY}:result=${trf_file}" \
    -f null - >/dev/null
}

# Run vidstabdetect on window only (with -ss/-t trim)
run_vidstabdetect_window() {
  local input_file="$1" trf_file="$2" start_time="$3" duration="$4"
  ffmpeg -hide_banner -nostdin -stats -loglevel info -progress pipe:2 \
    -fflags +genpts+discardcorrupt -err_detect ignore_err \
    -ss "$start_time" -t "$duration" \
    -i "$input_file" \
    -vf "vidstabdetect=shakiness=${SHAKINESS}:accuracy=${ACCURACY}:result=${trf_file}" \
    -f null - >/dev/null
}

# =================== analyze ===================
cmd_analyze() {
  local in_dir="$1" work="$2"; shift 2
  ensure_tools
  mkdir -p "${work}/${TRF_DIRNAME}"

  local WINDOWED WIN_FROM WIN_DUR WIN_TO
  local win_info
  win_info="$(parse_window_args "$@")"
  while IFS= read -r line; do
    case "$line" in
      WINDOWED=*|WIN_FROM=*|WIN_DUR=*|WIN_TO=*)
        eval "$line"
        ;;
    esac
  done <<< "$win_info"

  local filelist
  filelist=$(mktemp)
  collect_mov_files "${in_dir}" > "${filelist}"
  [[ -s "${filelist}" ]] || fatal "No .mov files in ${in_dir}"

  local plan_csv="${work}/${PLAN_CSV}"
  local plan_json="${work}/${PLAN_JSON}"

  : > "${plan_csv}"
  echo "index,file,transform,duration,start,end" >> "${plan_csv}"

  echo "[" > "${plan_json}"
  local idx=0
  local t0="0.000000"
  local first_json=1
  local any_included=0

  while IFS= read -r f; do
    [[ -n "$f" ]] || continue

    local dur t1
    dur=$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$f" | head -n1 || echo "0")
    dur=$(to_seconds "${dur}")
    t1=$(float_add "$t0" "$dur")

    local include=1
    if [[ "$WINDOWED" -eq 1 ]]; then
      local overlap_info HAS_OVERLAP
      overlap_info="$(calculate_window_overlap "$t0" "$t1" "$WIN_FROM" "$WIN_TO")"
      while IFS= read -r line; do
        [[ "$line" =~ ^HAS_OVERLAP= ]] && eval "$line"
      done <<< "$overlap_info"
      if [[ "$HAS_OVERLAP" != "1" ]]; then
        include=0
      fi
    fi

    if [[ "$include" -eq 1 ]]; then
      any_included=1
      local base trf
      base=$(basename "$f")
      
      if [[ "$WINDOWED" -eq 1 ]]; then
        # Window mode: create unique .trf name for this window
        local win_suffix
        win_suffix=$(printf "_w%.0f_%.0f" "$WIN_FROM" "$WIN_DUR")
        trf="${work}/${TRF_DIRNAME}/${base%.*}${win_suffix}.trf"
      else
        # Full mode: standard .trf name
        trf="${work}/${TRF_DIRNAME}/${base%.*}.trf"
      fi

      if [[ ! -s "${trf}" || "${FORCE}" == "1" ]]; then
        if [[ "$WINDOWED" -eq 1 ]]; then
          # Window mode: analyze only the overlapping part (FAST)
          local overlap_info2 LOCAL_START OVERLAP_DUR
          overlap_info2="$(calculate_window_overlap "$t0" "$t1" "$WIN_FROM" "$WIN_TO")"
          while IFS= read -r line; do
            case "$line" in
              LOCAL_START=*|OVERLAP_DUR=*)
                eval "$line"
                ;;
            esac
          done <<< "$overlap_info2"
          run_vidstabdetect_window "$f" "$trf" "$LOCAL_START" "$OVERLAP_DUR"
        else
          # Full mode: analyze entire file (SLOW but high quality)
          run_vidstabdetect_full "$f" "$trf"
        fi
      fi

      echo "${idx},${f},${trf},${dur},${t0},${t1}" >> "${plan_csv}"

      if [[ $first_json -eq 0 ]]; then echo "," >> "${plan_json}"; fi
      first_json=0
      printf '  {"index":%d,"file":%s,"transform":%s,"duration":%s,"start":%s,"end":%s}' \
        "${idx}" "$(printf '%s' "\"$f\"")" "$(printf '%s' "\"$trf\"")" \
        "${dur}" "${t0}" "${t1}" >> "${plan_json}"

      idx=$((idx+1))
    fi

    t0="$t1"

    if [[ "$WINDOWED" -eq 1 ]] && float_gt "$t0" "$WIN_TO"; then
      break
    fi
  done < "${filelist}"
  rm -f "${filelist}"

  if [[ "$WINDOWED" -eq 1 && "$any_included" -eq 0 ]]; then
    fatal "analyze window does not overlap any inputs"
  fi

  echo "" >> "${plan_json}"
  echo "]" >> "${plan_json}"

  if [[ "$WINDOWED" -eq 1 ]]; then
    echo "Analyze complete (window mode, global timeline preserved)."
  else
    echo "Analyze complete (full timeline)."
  fi
  echo "  Plan CSV : ${plan_csv}"
  echo "  Plan JSON: ${plan_json}"
  echo "  TRF dir  : ${work}/${TRF_DIRNAME}"
}

# =================== render (production) ===================
build_render_graph() {
  # stdin: plan.csv
  local files=() trfs=() starts=() ends=()
  while IFS=, read -r index file trf dur start end; do
    [[ "$index" == "index" ]] && continue
    files+=("$file"); trfs+=("$trf"); starts+=("$start"); ends+=("$end")
  done

  local n="${#files[@]}"; [[ "$n" -ge 1 ]] || fatal "Empty plan"

  local sel_idx=() s_in=() d_in=()

  if [[ "${WINDOWED:-0}" == "1" ]]; then
    [[ -n "${WIN_FROM_S:-}" && -n "${WIN_DUR_S:-}" ]] || fatal "render: --from/--dur required"
    local w0="$WIN_FROM_S"
    local w1; w1=$(float_add "$WIN_FROM_S" "$WIN_DUR_S")

    for ((i=0;i<n;i++)); do
      local fstart="${starts[$i]}" fend="${ends[$i]}"
      local os; os=$(float_max "$fstart" "$w0")
      local oe; oe=$(float_min "$fend" "$w1")
      local od; od=$(float_sub "$oe" "$os")
      if float_gt "$od" "0.000001"; then
        local ls; ls=$(float_sub "$os" "$fstart")
        sel_idx+=("$i"); s_in+=("$ls"); d_in+=("$od")
      fi
    done
  else
    for ((i=0;i<n;i++)); do
      local fstart="${starts[$i]}" fend="${ends[$i]}"
      local ld; ld=$(float_sub "$fend" "$fstart")
      sel_idx+=("$i"); s_in+=("0.000000"); d_in+=("$ld")
    done
  fi

  local m="${#sel_idx[@]}"; [[ "$m" -ge 1 ]] || fatal "Selected window has zero overlap"

  local iargs=""
  for ((k=0;k<m;k++)); do
    iargs+=" $(printf '%q' "-i") $(printf '%q' "${files[${sel_idx[$k]}]}")"
  done
  iargs="${iargs# }"
  printf 'IARGS=%q\n' "${iargs}"
  printf 'WATERMARK_INPUT=%q\n' "${LOGO}"

  local fc=""
  for ((k=0;k<m;k++)); do
    local idx="${sel_idx[$k]}"
    local trf="${trfs[$idx]}"
    local ls="${s_in[$k]}"
    local ld="${d_in[$k]}"

    local vchain="trim=start=${ls}:duration=${ld},setpts=PTS-STARTPTS,$(filter_stab_chain "${trf}")"
    local achain="atrim=start=${ls}:duration=${ld},asetpts=PTS-STARTPTS,aformat=channel_layouts=mono,aresample=48000"

    fc+="${fc:+;}[${k}:v]${vchain}[vv${k}];[${k}:a]${achain}[aa${k}]"
  done

  fc+=";"
  for ((k=0;k<m;k++)); do fc+="[vv${k}][aa${k}]"; done
  fc+="concat=n=${m}:v=1:a=1[vcat][acat]"
  # watermark: logo is extra input at index m
  fc+=";[${m}:v]scale=min(300\\,iw):-1[wm];[vcat][wm]overlay=W-w-24:H-h-24:format=auto[vout]"

  printf 'FC=%q\n' "${fc}"
  printf 'VMAP=%q\n' "[vout]"
  printf 'AMAP=%q\n' "[acat]"
}

cmd_render() {
  local work="$1" out="$2"; shift 2
  ensure_tools

  local plan_csv="${work}/${PLAN_CSV}"
  [[ -f "${plan_csv}" ]] || fatal "Missing plan: ${plan_csv}"
  [[ -f "${LOGO}"     ]] || fatal "Missing LOGO: ${LOGO}"

  # Parse window args using shared function
  local WINDOWED WIN_FROM WIN_DUR WIN_TO
  local win_info
  win_info="$(parse_window_args "$@")"
  while IFS= read -r line; do
    case "$line" in
      WINDOWED=*|WIN_FROM=*|WIN_DUR=*|WIN_TO=*)
        eval "$line"
        ;;
    esac
  done <<< "$win_info"
  
  # Rename for compatibility with build_render_graph
  local WIN_FROM_S="$WIN_FROM"
  local WIN_DUR_S="$WIN_DUR"

  local graph
  graph="$(
    WINDOWED="${WINDOWED}" WIN_FROM_S="${WIN_FROM_S:-}" WIN_DUR_S="${WIN_DUR_S:-}" \
    build_render_graph < "${plan_csv}"
  )"

  local IARGS="" WATERMARK_INPUT="" FC="" VMAP="" AMAP=""
  while IFS= read -r line; do
    case "$line" in
      IARGS=*|WATERMARK_INPUT=*|FC=*|VMAP=*|AMAP=*)
        eval "$line"
        ;;
    esac
  done <<< "${graph}"

  [[ -n "${IARGS}" && -n "${FC}" && -n "${VMAP}" && -n "${AMAP}" && -n "${WATERMARK_INPUT}" ]] \
    || fatal "Render graph incomplete"

  local enc; enc=$(encode_args)
  eval "set -- ${IARGS}"

  ffmpeg -hide_banner -nostdin -stats -loglevel info -progress pipe:2 \
    -fflags +genpts+discardcorrupt -err_detect ignore_err \
    "$@" -i "${WATERMARK_INPUT}" \
    -filter_complex "${FC}" \
    -map "${VMAP}" -map "${AMAP}" \
    ${enc} \
    -c:a aac -b:a "${AUDIO_BR}" \
    -movflags +faststart \
    "${out}"

  echo "Rendered: ${out}"
}

# =================== debug graph builders ===================

# plan_debug.csv: index,file,transform,duration,start,end
# start/end here are GLOBAL timeline coordinates (like analyze/render)

build_debug_split_graph() {
  # Expects WIN_FROM_G and WIN_TO_G to be set in environment
  local files=() trfs=() file_starts=() file_ends=()
  while IFS=, read -r index file trf dur start end; do
    [[ "$index" == "index" ]] && continue
    files+=("$file"); trfs+=("$trf"); file_starts+=("$start"); file_ends+=("$end")
  done
  local m="${#files[@]}"; [[ "$m" -ge 1 ]] || fatal "Empty debug plan"

  local iargs=""
  for ((k=0;k<m;k++)); do
    iargs+=" $(printf '%q' "-i") $(printf '%q' "${files[$k]}")"
  done
  iargs="${iargs# }"
  printf 'IARGS=%q\n' "${iargs}"
  printf 'WATERMARK_INPUT=%q\n' "${LOGO}"

  local fc=""
  for ((k=0;k<m;k++)); do
    local trf="${trfs[$k]}"
    local fstart="${file_starts[$k]}"
    local fend="${file_ends[$k]}"
    
    # Calculate overlap with window using shared function
    local overlap_info LOCAL_START OVERLAP_DUR
    overlap_info="$(calculate_window_overlap "$fstart" "$fend" "${WIN_FROM_G}" "${WIN_TO_G}")"
    while IFS= read -r line; do
      case "$line" in
        LOCAL_START=*|OVERLAP_DUR=*)
          eval "$line"
          ;;
      esac
    done <<< "$overlap_info"

    local ochain; ochain="$(filter_orig_chain "${LOCAL_START}" "${OVERLAP_DUR}")"
    local schain="trim=start=${LOCAL_START}:duration=${OVERLAP_DUR},setpts=PTS-STARTPTS,$(filter_stab_chain "${trf}")"

    fc+="${fc:+;}[${k}:v]${ochain}[olv${k}];"
    fc+="[${k}:v]${schain}[srv${k}];"
    fc+="[olv${k}][srv${k}]hstack=shortest=1[v${k}];"
    fc+="[${k}:a]atrim=start=${LOCAL_START}:duration=${OVERLAP_DUR},asetpts=PTS-STARTPTS,aformat=channel_layouts=mono,aresample=48000[a${k}]"
  done

  fc+=";"
  for ((k=0;k<m;k++)); do fc+="[v${k}][a${k}]"; done
  fc+="concat=n=${m}:v=1:a=1[vcat][acat]"
  # watermark: logo is extra input at index m
  fc+=";[${m}:v]scale=min(300\\,iw):-1[wm];[vcat][wm]overlay=W-w-24:H-h-24:format=auto[vout]"

  printf 'FC=%q\n' "${fc}"
  printf 'VMAP=%q\n' "[vout]"
  printf 'AMAP=%q\n' "[acat]"
}

build_debug_orig_graph() {
  # Expects WIN_FROM_G and WIN_TO_G to be set in environment
  local files=() file_starts=() file_ends=()
  while IFS=, read -r index file trf dur start end; do
    [[ "$index" == "index" ]] && continue
    files+=("$file"); file_starts+=("$start"); file_ends+=("$end")
  done
  local m="${#files[@]}"; [[ "$m" -ge 1 ]] || fatal "Empty debug plan"

  local iargs=""
  for ((k=0;k<m;k++)); do
    iargs+=" $(printf '%q' "-i") $(printf '%q' "${files[$k]}")"
  done
  iargs="${iargs# }"
  printf 'IARGS=%q\n' "${iargs}"

  local fc=""
  for ((k=0;k<m;k++)); do
    local fstart="${file_starts[$k]}"
    local fend="${file_ends[$k]}"
    
    # Calculate overlap with window using shared function
    local overlap_info LOCAL_START OVERLAP_DUR
    overlap_info="$(calculate_window_overlap "$fstart" "$fend" "${WIN_FROM_G}" "${WIN_TO_G}")"
    while IFS= read -r line; do
      case "$line" in
        LOCAL_START=*|OVERLAP_DUR=*)
          eval "$line"
          ;;
      esac
    done <<< "$overlap_info"
    
    local vchain; vchain="$(filter_orig_chain "${LOCAL_START}" "${OVERLAP_DUR}")"
    local achain="atrim=start=${LOCAL_START}:duration=${OVERLAP_DUR},asetpts=PTS-STARTPTS,aformat=channel_layouts=mono,aresample=48000"
    fc+="${fc:+;}[${k}:v]${vchain}[v${k}];[${k}:a]${achain}[a${k}]"
  done

  fc+=";"
  for ((k=0;k<m;k++)); do fc+="[v${k}][a${k}]"; done
  fc+="concat=n=${m}:v=1:a=1[vout][acat]"

  printf 'FC=%q\n' "${fc}"
  printf 'VMAP=%q\n' "[vout]"
  printf 'AMAP=%q\n' "[acat]"
}

build_debug_stab_graph() {
  # Expects WIN_FROM_G and WIN_TO_G to be set in environment
  local files=() trfs=() file_starts=() file_ends=()
  while IFS=, read -r index file trf dur start end; do
    [[ "$index" == "index" ]] && continue
    files+=("$file"); trfs+=("$trf"); file_starts+=("$start"); file_ends+=("$end")
  done
  local m="${#files[@]}"; [[ "$m" -ge 1 ]] || fatal "Empty debug plan"

  local iargs=""
  for ((k=0;k<m;k++)); do
    iargs+=" $(printf '%q' "-i") $(printf '%q' "${files[$k]}")"
  done
  iargs="${iargs# }"
  printf 'IARGS=%q\n' "${iargs}"

  local fc=""
  for ((k=0;k<m;k++)); do
    local trf="${trfs[$k]}"
    local fstart="${file_starts[$k]}"
    local fend="${file_ends[$k]}"
    
    # Calculate overlap with window using shared function
    local overlap_info LOCAL_START OVERLAP_DUR
    overlap_info="$(calculate_window_overlap "$fstart" "$fend" "${WIN_FROM_G}" "${WIN_TO_G}")"
    while IFS= read -r line; do
      case "$line" in
        LOCAL_START=*|OVERLAP_DUR=*)
          eval "$line"
          ;;
      esac
    done <<< "$overlap_info"
    
    local vchain="trim=start=${LOCAL_START}:duration=${OVERLAP_DUR},setpts=PTS-STARTPTS,$(filter_stab_chain "${trf}")"
    local achain="atrim=start=${LOCAL_START}:duration=${OVERLAP_DUR},asetpts=PTS-STARTPTS,aformat=channel_layouts=mono,aresample=48000"
    fc+="${fc:+;}[${k}:v]${vchain}[v${k}];[${k}:a]${achain}[a${k}]"
  done

  fc+=";"
  for ((k=0;k<m;k++)); do fc+="[v${k}][a${k}]"; done
  fc+="concat=n=${m}:v=1:a=1[vout][acat]"

  printf 'FC=%q\n' "${fc}"
  printf 'VMAP=%q\n' "[vout]"
  printf 'AMAP=%q\n' "[acat]"
}

# =================== debug (3 outputs) ===================
cmd_debug() {
  local in_dir="$1" work="$2" split_out="$3"; shift 3

  ensure_tools
  mkdir -p "${work}/${TRF_DIRNAME}"

  # Parse window args (required for debug)
  local WINDOWED WIN_FROM WIN_DUR WIN_TO
  local win_info
  win_info="$(parse_window_args "$@")"
  while IFS= read -r line; do
    case "$line" in
      WINDOWED=*|WIN_FROM=*|WIN_DUR=*|WIN_TO=*)
        eval "$line"
        ;;
    esac
  done <<< "$win_info"
  
  # Debug requires window
  [[ "$WINDOWED" -eq 1 ]] || fatal "debug: --from and --dur are required"
  
  local g_from="$WIN_FROM"
  local g_dur="$WIN_DUR"
  local g_to="$WIN_TO"

  local filelist
  filelist=$(mktemp)
  collect_mov_files "${in_dir}" > "${filelist}"
  [[ -s "${filelist}" ]] || fatal "No .mov files in ${in_dir}"

  local plan_csv="${work}/plan_debug.csv"
  : > "${plan_csv}"
  echo "index,file,transform,duration,start,end" >> "${plan_csv}"

  local idx=0
  local t0="0.000000"

  while IFS= read -r f; do
    [[ -n "$f" ]] || continue

    local dur_full t1
    dur_full=$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$f" | head -n1 || echo "0")
    dur_full=$(to_seconds "${dur_full}")
    t1=$(float_add "$t0" "$dur_full")

    # Check overlap with debug window
    local overlap_info HAS_OVERLAP LOCAL_START OVERLAP_DUR
    overlap_info="$(calculate_window_overlap "$t0" "$t1" "$g_from" "$g_to")"
    while IFS= read -r line; do
      case "$line" in
        HAS_OVERLAP=*|LOCAL_START=*|OVERLAP_DUR=*)
          eval "$line"
          ;;
      esac
    done <<< "$overlap_info"

    if [[ "$HAS_OVERLAP" == "1" ]]; then
      local base trf
      base=$(basename "$f")
      trf="${work}/${TRF_DIRNAME}/${base%.*}.debug.trf"

      # Analyze ONLY the window (FAST for debug)
      run_vidstabdetect_window "$f" "$trf" "$LOCAL_START" "$OVERLAP_DUR"

      # Store with GLOBAL timeline coordinates
      echo "${idx},${f},${trf},${dur_full},${t0},${t1}" >> "${plan_csv}"
      idx=$((idx+1))
    fi

    t0="$t1"
    if float_gt "$t0" "$g_to"; then
      break
    fi
  done < "${filelist}"
  rm -f "${filelist}"

  [[ $idx -ge 1 ]] || fatal "Window does not overlap any inputs"

  local split_dir split_name base_noext ext orig_out stab_out
  split_dir=$(dirname "$split_out")
  split_name=$(basename "$split_out")
  ext="${split_name##*.}"
  base_noext="${split_name%.*}"
  orig_out="${split_dir}/${base_noext}_orig.${ext}"
  stab_out="${split_dir}/${base_noext}_stab.${ext}"

  local enc; enc=$(encode_args)

  # 1) Split-screen
  local graph_s
  graph_s="$(WIN_FROM_G="$g_from" WIN_TO_G="$g_to" build_debug_split_graph < "${plan_csv}")"

  local IARGS="" WATERMARK_INPUT="" FC="" VMAP="" AMAP=""
  while IFS= read -r line; do
    case "$line" in
      IARGS=*|WATERMARK_INPUT=*|FC=*|VMAP=*|AMAP=*)
        eval "$line"
        ;;
    esac
  done <<< "${graph_s}"

  [[ -n "$IARGS" && -n "$WATERMARK_INPUT" && -n "$FC" && -n "$VMAP" && -n "$AMAP" ]] \
    || fatal "Debug split graph incomplete"

  eval "set -- ${IARGS}"

  ffmpeg -hide_banner -nostdin -stats -loglevel info -progress pipe:2 \
    -fflags +genpts+discardcorrupt -err_detect ignore_err \
    "$@" -i "${WATERMARK_INPUT}" \
    -filter_complex "${FC}" \
    -map "${VMAP}" -map "${AMAP}" \
    ${enc} \
    -c:a aac -b:a "${AUDIO_BR}" \
    -movflags +faststart \
    "${split_out}"

  echo "Debug split-screen: ${split_out}"

  # 2) Original-only
  local graph_o
  graph_o="$(WIN_FROM_G="$g_from" WIN_TO_G="$g_to" build_debug_orig_graph < "${plan_csv}")"

  IARGS=""; FC=""; VMAP=""; AMAP=""
  while IFS= read -r line; do
    case "$line" in
      IARGS=*|FC=*|VMAP=*|AMAP=*)
        eval "$line"
        ;;
    esac
  done <<< "${graph_o}"

  [[ -n "$IARGS" && -n "$FC" && -n "$VMAP" && -n "$AMAP" ]] \
    || fatal "Debug orig graph incomplete"

  eval "set -- ${IARGS}"

  ffmpeg -hide_banner -nostdin -stats -loglevel info -progress pipe:2 \
    -fflags +genpts+discardcorrupt -err_detect ignore_err \
    "$@" \
    -filter_complex "${FC}" \
    -map "${VMAP}" -map "${AMAP}" \
    ${enc} \
    -c:a aac -b:a "${AUDIO_BR}" \
    -movflags +faststart \
    "${orig_out}"

  echo "Debug original-only: ${orig_out}"

  # 3) Stabilized-only
  local graph_t
  graph_t="$(WIN_FROM_G="$g_from" WIN_TO_G="$g_to" build_debug_stab_graph < "${plan_csv}")"

  IARGS=""; FC=""; VMAP=""; AMAP=""
  while IFS= read -r line; do
    case "$line" in
      IARGS=*|FC=*|VMAP=*|AMAP=*)
        eval "$line"
        ;;
    esac
  done <<< "${graph_t}"

  [[ -n "$IARGS" && -n "$FC" && -n "$VMAP" && -n "$AMAP" ]] \
    || fatal "Debug stabilized graph incomplete"

  eval "set -- ${IARGS}"

  ffmpeg -hide_banner -nostdin -stats -loglevel info -progress pipe:2 \
    -fflags +genpts+discardcorrupt -err_detect ignore_err \
    "$@" \
    -filter_complex "${FC}" \
    -map "${VMAP}" -map "${AMAP}" \
    ${enc} \
    -c:a aac -b:a "${AUDIO_BR}" \
    -movflags +faststart \
    "${stab_out}"

  echo "Debug stabilized-only: ${stab_out}"
}

# =================== main ===================
main() {
  [[ $# -ge 1 ]] || { usage; exit 1; }
  case "$1" in
    analyze)
      [[ $# -ge 3 ]] || { usage; exit 1; }
      shift; cmd_analyze "$@"
      ;;
    render)
      [[ $# -ge 3 ]] || { usage; exit 1; }
      shift; cmd_render "$@"
      ;;
    debug)
      [[ $# -ge 4 ]] || { usage; exit 1; }
      shift; cmd_debug "$@"
      ;;
    *)
      usage; exit 1;;
  esac
}
main "$@"
