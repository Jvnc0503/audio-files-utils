#!/usr/bin/env bash

set -eo pipefail

# ==============================================================================
# CUE + FLAC Album Splitter (Pure FFmpeg)
# Slices CUE/FLAC images sample-accurately, embeds full Vorbis comment metadata,
# encodes with maximum FLAC compression (Level 12), and tags album ReplayGain.
# ==============================================================================

# --- Dependency Check ---
DEPENDENCIES=(ffmpeg ffprobe metaflac awk parallel iconv file)
for cmd in "${DEPENDENCIES[@]}"; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "Error: Required dependency '$cmd' is not installed or not in PATH." >&2
        exit 1
    fi
done

# --- Usage & Validation ---
usage() {
    cat <<EOF
Usage: $(basename "$0") <album.cue> [album.flac]

Arguments:
  <album.cue>   Path to the CUE sheet.
  [album.flac]  (Optional) Path to the FLAC audio file. If omitted, the script
                auto-detects it from the CUE sheet or directory.

Environment Variables:
  COMPRESSION_LEVEL    FLAC compression level (default: 12; range: 0-12)
  JOBS                 Number of parallel split jobs (default: 6)
  FFMPEG_THREADS       Decoder threads per job (default: 2)
EOF
    exit 1
}

if [[ $# -lt 1 ]] || [[ "$1" == "-h" ]] || [[ "$1" == "--help" ]]; then
    usage
fi

CUE_FILE="$(realpath "$1")"
if [[ ! -f "$CUE_FILE" ]]; then
    echo "Error: CUE file '$CUE_FILE' not found." >&2
    exit 1
fi

CUE_DIR="$(dirname "$CUE_FILE")"

# --- Runtime Configuration ---
export COMPRESSION_LEVEL="${COMPRESSION_LEVEL:-12}"
export JOBS="${JOBS:-6}"
export FFMPEG_THREADS="${FFMPEG_THREADS:-2}"

# --- 1. Normalize Encoding & Strip CRLF / BOM ---
normalize_cue() {
    local file="$1"
    if file -b "$file" | grep -qi "utf-16"; then
        iconv -f UTF-16 -t UTF-8 "$file" 2>/dev/null || cat "$file"
    else
        cat "$file"
    fi | tr -d '\r' | sed '1s/^\xEF\xBB\xBF//'
}

# --- 2. CUE Sheet Parsing via AWK ---
PARSED_MANIFEST="$(normalize_cue "$CUE_FILE" | awk '
BEGIN {
    track_count = 0
    current_track = 0
    album_artist = ""
    album_title = ""
    genre = ""
    date = ""
    disc = ""
    audio_file = ""
}
{
    sub(/\r$/, "")
    sub(/^[ \t]+/, "")
    sub(/[ \t]+$/, "")
    u = toupper($0)
}
u ~ /^REM[ \t]+GENRE[ \t]+/ {
    val = $0
    sub(/^[^ \t]+[ \t]+[^ \t]+[ \t]+/, "", val)
    gsub(/^"|"$/, "", val)
    if (genre == "") genre = val
    next
}
u ~ /^REM[ \t]+(DATE|YEAR)[ \t]+/ {
    val = $0
    sub(/^[^ \t]+[ \t]+[^ \t]+[ \t]+/, "", val)
    gsub(/^"|"$/, "", val)
    if (date == "") date = val
    next
}
u ~ /^REM[ \t]+DISCNUMBER[ \t]+/ {
    val = $0
    sub(/^[^ \t]+[ \t]+[^ \t]+[ \t]+/, "", val)
    gsub(/^"|"$/, "", val)
    if (disc == "") disc = val
    next
}
u ~ /^PERFORMER[ \t]+/ {
    val = $0
    sub(/^[^ \t]+[ \t]+/, "", val)
    gsub(/^"|"$/, "", val)
    if (current_track == 0) {
        if (album_artist == "") album_artist = val
    } else {
        track_artist[current_track] = val
    }
    next
}
u ~ /^TITLE[ \t]+/ {
    val = $0
    sub(/^[^ \t]+[ \t]+/, "", val)
    gsub(/^"|"$/, "", val)
    if (current_track == 0) {
        if (album_title == "") album_title = val
    } else {
        track_title[current_track] = val
    }
    next
}
u ~ /^FILE[ \t]+/ {
    val = $0
    sub(/^[^ \t]+[ \t]+/, "", val)
    sub(/[ \t]+[^ \t]+$/, "", val)
    gsub(/^"|"$/, "", val)
    if (audio_file == "") audio_file = val
    next
}
u ~ /^TRACK[ \t]+[0-9]+/ {
    current_track++
    match($0, /[0-9]+/)
    track_num[current_track] = substr($0, RSTART, RLENGTH)
    track_count = current_track
    next
}
u ~ /^INDEX[ \t]+00[ \t]+/ {
    val = $0
    sub(/^[^ \t]+[ \t]+[^ \t]+[ \t]+/, "", val)
    split(val, ts, ":")
    sec = (ts[1] * 60) + ts[2] + (ts[3] / 75.0)
    track_idx00[current_track] = sec
    next
}
u ~ /^INDEX[ \t]+01[ \t]+/ {
    val = $0
    sub(/^[^ \t]+[ \t]+[^ \t]+[ \t]+/, "", val)
    split(val, ts, ":")
    sec = (ts[1] * 60) + ts[2] + (ts[3] / 75.0)
    track_idx01[current_track] = sec
    next
}
END {
    print "META:FILE=" audio_file
    print "META:ALBUM=" album_title
    print "META:ALBUMARTIST=" album_artist
    print "META:GENRE=" genre
    print "META:DATE=" date
    print "META:DISCNUMBER=" disc
    print "META:TRACKTOTAL=" track_count

    for (i = 1; i <= track_count; i++) {
        if (i == 1 && (1 in track_idx00) && track_idx00[1] < track_idx01[1]) {
            start_t = track_idx00[1]
        } else if (i in track_idx01) {
            start_t = track_idx01[i]
        } else {
            start_t = 0
        }

        if (i < track_count) {
            end_t = (i+1 in track_idx01) ? track_idx01[i+1] : ""
        } else {
            end_t = ""
        }

        art = (i in track_artist) ? track_artist[i] : album_artist
        tit = (i in track_title) ? track_title[i] : sprintf("Track %02d", track_num[i])
        num = track_num[i]

        gsub(/\t/, " ", tit)
        gsub(/\t/, " ", art)

        printf "TRACK\t%s\t%s\t%s\t%.6f\t%s\n", num, tit, art, start_t, (end_t != "" ? sprintf("%.6f", end_t) : "")
    }
}')"

# --- 3. Extract & Sanitize Metadata ---
get_meta() {
    grep "^META:$1=" <<< "$PARSED_MANIFEST" | head -n 1 | cut -d'=' -f2- | tr -d '\r\n'
}

export ALBUM_TITLE="$(get_meta "ALBUM")"
export ALBUM_ARTIST="$(get_meta "ALBUMARTIST")"
export GENRE="$(get_meta "GENRE")"
export DATE="$(get_meta "DATE")"
export DISCNUMBER="$(get_meta "DISCNUMBER")"
export TRACKTOTAL="$(get_meta "TRACKTOTAL")"
CUE_AUDIO_FILE="$(get_meta "FILE")"

if [[ -z "$TRACKTOTAL" ]] || [[ "$TRACKTOTAL" -eq 0 ]]; then
    echo "Error: Failed to parse any tracks from CUE sheet: $CUE_FILE" >&2
    exit 1
fi

# --- 4. Resolve Target Audio File ---
if [[ $# -ge 2 ]]; then
    FLAC_FILE="$(realpath "$2")"
elif [[ -n "$CUE_AUDIO_FILE" ]] && [[ -f "$CUE_DIR/$CUE_AUDIO_FILE" ]]; then
    FLAC_FILE="$CUE_DIR/$CUE_AUDIO_FILE"
elif [[ -n "$CUE_AUDIO_FILE" ]] && [[ -f "$CUE_DIR/${CUE_AUDIO_FILE%.*}.flac" ]]; then
    FLAC_FILE="$CUE_DIR/${CUE_AUDIO_FILE%.*}.flac"
elif [[ -f "${CUE_FILE%.cue}.flac" ]]; then
    FLAC_FILE="${CUE_FILE%.cue}.flac"
else
    shopt -s nullglob
    POSSIBLE_FLACS=("$CUE_DIR"/*.flac)
    shopt -u nullglob
    if [[ ${#POSSIBLE_FLACS[@]} -eq 1 ]]; then
        FLAC_FILE="${POSSIBLE_FLACS[0]}"
    else
        echo "Error: Could not automatically resolve source .flac file." >&2
        echo "Please specify the audio file path as the second argument." >&2
        exit 1
    fi
fi

if [[ ! -f "$FLAC_FILE" ]]; then
    echo "Error: Audio file '$FLAC_FILE' does not exist." >&2
    exit 1
fi
export FLAC_FILE

# --- 5. Resolve Output Directory (NTFS/FAT Safe) ---
clean_name() {
    local str="$1"
    # Remove CR, LF, and control characters
    str="$(printf '%s' "$str" | tr -d '\r\n' | tr -cd '[:print:]')"
    # Replace illegal filesystem characters: / \ : * ? " < > |
    str="${str//[\/\\:\*\?\"<>|]/-}"
    # Strip leading/trailing spaces and trailing dots (forbidden on NTFS/exFAT)
    str="$(printf '%s' "$str" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:].]*$//')"
    printf '%s' "$str"
}
export -f clean_name

SAFE_ARTIST="$(clean_name "${ALBUM_ARTIST:-Unknown Artist}")"
SAFE_ALBUM="$(clean_name "${ALBUM_TITLE:-Unknown Album}")"

if [[ -n "$ALBUM_ARTIST" ]] && [[ -n "$ALBUM_TITLE" ]]; then
    DEST_SUBDIR="${SAFE_ARTIST} - ${SAFE_ALBUM}"
elif [[ -n "$ALBUM_TITLE" ]]; then
    DEST_SUBDIR="${SAFE_ALBUM}"
else
    DEST_SUBDIR="$(basename "${CUE_FILE%.cue}")_split"
fi

export OUTPUT_DIR="$CUE_DIR/$DEST_SUBDIR"
mkdir -p -- "$OUTPUT_DIR"

echo "Source CUE:   $(basename "$CUE_FILE")"
echo "Source Audio: $(basename "$FLAC_FILE")"
echo "Destination:  $DEST_SUBDIR"
echo "Splitting $TRACKTOTAL tracks with FFmpeg (Compression Level $COMPRESSION_LEVEL)..."

# --- 6. FFmpeg Splitting Engine ---
split_track() {
    set -eo pipefail

    local num="$(printf '%s' "$1" | tr -d '\r\n')"
    local title="$(printf '%s' "$2" | tr -d '\r\n')"
    local artist="$(printf '%s' "$3" | tr -d '\r\n')"
    local start_sec="$(printf '%s' "$4" | tr -d '\r\n')"
    local end_sec="$(printf '%s' "$5" | tr -d '\r\n')"

    local pad_num
    printf -v pad_num "%02d" "$((10#$num))"

    local safe_title
    safe_title="$(clean_name "$title")"

    local output_file="$OUTPUT_DIR/${pad_num} - ${safe_title}.flac"

    local time_args=()
    if [[ -n "$end_sec" ]]; then
        local duration
        duration="$(awk -v s="$start_sec" -v e="$end_sec" 'BEGIN { printf "%.6f", e - s }')"
        time_args=(-ss "$start_sec" -t "$duration")
    else
        time_args=(-ss "$start_sec")
    fi

    ffmpeg -y -threads "$FFMPEG_THREADS" -hide_banner -loglevel error \
        "${time_args[@]}" -i "$FLAC_FILE" \
        -c:a flac -compression_level "$COMPRESSION_LEVEL" \
        -metadata title="$title" \
        -metadata artist="$artist" \
        -metadata album="$ALBUM_TITLE" \
        -metadata album_artist="$ALBUM_ARTIST" \
        -metadata track="${pad_num}/${TRACKTOTAL}" \
        ${DATE:+-metadata date="$DATE"} \
        ${GENRE:+-metadata genre="$GENRE"} \
        ${DISCNUMBER:+-metadata disc="$DISCNUMBER"} \
        "$output_file"
}
export -f split_track

# --- 7. Parallel Execution ---
grep '^TRACK'$'\t' <<< "$PARSED_MANIFEST" | cut -f2- | \
    parallel --colsep '\t' -j "$JOBS" --bar split_track {1} {2} {3} {4} {5}

# --- 8. ReplayGain Embedding ---
echo "--- Calculating and Embedding ReplayGain ---"
shopt -s nullglob
SPLIT_FLACS=("$OUTPUT_DIR"/*.flac)
shopt -u nullglob

if [[ ${#SPLIT_FLACS[@]} -gt 0 ]]; then
    metaflac --add-replay-gain "${SPLIT_FLACS[@]}"
fi

echo "-------------------------------------------------------"
echo "Process Finished Successfully!"
echo "Destination: $OUTPUT_DIR"
echo "-------------------------------------------------------"
