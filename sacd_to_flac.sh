#!/usr/bin/env bash

set -eo pipefail

# ==============================================================================
# SACD ISO to 24-bit FLAC Batch Transcoder
# Extracts DSD audio from SACD images, downsamples to linear PCM via SoX (VHQ),
# applies 24-bit TPDF dither, tags ReplayGain, and sorts into Artist - Album folders.
# ==============================================================================

# --- Usage & Help ---
usage() {
    cat <<EOF
Usage: $(basename "$0") <file.iso|file.toc|folder_with_dsf>

Arguments:
  <input>              Path to an SACD image (.iso / .toc) or a folder containing .dsf files.

Environment Variables:
  SAMPLE_RATE          Target sampling rate (default: 44100; recommended: 44100 or 88200)
  JOBS                 Number of parallel conversion jobs (default: 6)
  FFMPEG_THREADS       Decoder threads per job (default: 2)
  OMP_NUM_THREADS      SoX OpenMP threads per job (default: 2)
EOF
    exit 1
}

if [[ $# -ne 1 ]] || [[ "$1" == "-h" ]] || [[ "$1" == "--help" ]]; then
    usage
fi

INPUT_TARGET="$1"
if [[ ! -e "$INPUT_TARGET" ]]; then
    echo "Error: Input '$INPUT_TARGET' does not exist." >&2
    exit 1
fi

INPUT_ABS="$(realpath "$INPUT_TARGET")"

# --- Determine Mode & Required Dependencies ---
if [[ -d "$INPUT_ABS" ]]; then
    MODE="DIR"
    BASE_DIR="$INPUT_ABS"
    DEPENDENCIES=(ffmpeg ffprobe sox parallel metaflac)
elif [[ -f "$INPUT_ABS" ]]; then
    MODE="ISO"
    BASE_DIR="$(dirname "$INPUT_ABS")"
    DEPENDENCIES=(sacd_extract ffmpeg ffprobe sox parallel metaflac)
else
    echo "Error: '$INPUT_TARGET' is not a valid file or directory." >&2
    exit 1
fi

# --- Dependency Check ---
for cmd in "${DEPENDENCIES[@]}"; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "Error: Required dependency '$cmd' is not installed or not in PATH." >&2
        exit 1
    fi
done

# --- Runtime Configuration ---
export SAMPLE_RATE="${SAMPLE_RATE:-44100}"
export JOBS="${JOBS:-6}"
export FFMPEG_THREADS="${FFMPEG_THREADS:-2}"
export OMP_NUM_THREADS="${OMP_NUM_THREADS:-2}"

# --- Setup Staging / Source Directory ---
if [[ "$MODE" == "ISO" ]]; then
    TEMP_DSF_DIR="$(mktemp -d -p "$BASE_DIR" .tmp_dsf_XXXXXX)"
    export TEMP_DSF_DIR
    WORKING_DSF_DIR="$TEMP_DSF_DIR"

    cleanup() {
        if [[ -n "${TEMP_DSF_DIR:-}" && -d "$TEMP_DSF_DIR" ]]; then
            echo "--- Cleaning up temporary files ---"
            rm -rf "$TEMP_DSF_DIR"
        fi
    }
    trap cleanup EXIT INT TERM

    echo "--- Extracting Stereo DSF from SACD Image ---"
    if ! sacd_extract -i "$INPUT_ABS" -s -2 -o "$WORKING_DSF_DIR" >/dev/null; then
        echo "Error: Extraction failed." >&2
        exit 1
    fi
else
    WORKING_DSF_DIR="$INPUT_ABS"
fi

# --- Verify DSF Files Exist ---
FILE_COUNT="$(find "$WORKING_DSF_DIR" -maxdepth 1 -type f -name "*.dsf" | wc -l)"
if [[ "$FILE_COUNT" -eq 0 ]]; then
    echo "Error: No .dsf files found in '$WORKING_DSF_DIR'." >&2
    exit 1
fi

# --- Metadata Extraction Functions ---
get_tag() {
    local tag_name="$1"
    local file="$2"
    ffprobe -v error -show_entries format_tags -of default=noprint_wrappers=1 "$file" 2>/dev/null | \
        awk -F'=' -v target="tag:${tag_name}" 'tolower($1) == tolower(target) { sub(/^[^=]*=/, ""); gsub(/^[ \t]+|[ \t]+$/, ""); print; exit }'
}

is_valid_tag() {
    local val="$1"
    local lower="${val,,}"
    if [[ -z "$val" || "$lower" == "unknown" || "$lower" == "unknown artist" || "$lower" == "unknown album" || "$lower" == "unknown album title" ]]; then
        return 1
    fi
    return 0
}

FIRST_DSF="$(find "$WORKING_DSF_DIR" -maxdepth 1 -type f -name "*.dsf" | head -n 1)"

TAG_ARTIST="$(get_tag "album_artist" "$FIRST_DSF")"
if ! is_valid_tag "$TAG_ARTIST"; then
    TAG_ARTIST="$(get_tag "artist" "$FIRST_DSF")"
fi
TAG_ALBUM="$(get_tag "album" "$FIRST_DSF")"

# Replace slashes to prevent nested directory creation
TAG_ARTIST="${TAG_ARTIST//\//-}"
TAG_ALBUM="${TAG_ALBUM//\//-}"

# Fallback directory naming
if [[ "$MODE" == "ISO" ]]; then
    DEFAULT_DIR_NAME="$(basename "${INPUT_ABS%.*}")"
else
    DEFAULT_DIR_NAME="$(basename "$INPUT_ABS")_FLAC"
fi

if is_valid_tag "$TAG_ARTIST" && is_valid_tag "$TAG_ALBUM"; then
    DEST_SUBDIR="${TAG_ARTIST} - ${TAG_ALBUM}"
elif is_valid_tag "$TAG_ALBUM"; then
    DEST_SUBDIR="${TAG_ALBUM}"
elif is_valid_tag "$TAG_ARTIST"; then
    DEST_SUBDIR="${TAG_ARTIST} - ${DEFAULT_DIR_NAME}"
else
    DEST_SUBDIR="${DEFAULT_DIR_NAME}"
fi

export OUTPUT_DIR="$BASE_DIR/$DEST_SUBDIR"
mkdir -p "$OUTPUT_DIR"

echo "Output Folder: $DEST_SUBDIR"
echo "Transcoding $FILE_COUNT tracks to ${SAMPLE_RATE}Hz / 24-bit FLAC using SoX VHQ..."

# --- Transcoding Engine ---
do_convert() {
    local input_file="$1"
    local base_name
    base_name="$(basename "${input_file%.dsf}")"
    local output_file="$OUTPUT_DIR/$base_name.flac"
    local temp_flac="$OUTPUT_DIR/$base_name.tmp.flac"

    # Step A: Transcode DSD audio to intermediate PCM FLAC via SoX
    ffmpeg -threads "$FFMPEG_THREADS" -hide_banner -loglevel error -i "$input_file" \
        -f sox - | \
        sox -t sox - -b 24 "$temp_flac" \
        rate -v -L "$SAMPLE_RATE" \
        dither

    # Step B: Remux audio stream and transfer original tags
    ffmpeg -y -threads "$FFMPEG_THREADS" -hide_banner -loglevel error \
        -i "$temp_flac" -i "$input_file" \
        -map 0:a -map_metadata 1 \
        -c copy "$output_file"

    # Step C: Cleanup temp transcode file
    rm -f "$temp_flac"
}
export -f do_convert

# --- Parallel Processing ---
find "$WORKING_DSF_DIR" -maxdepth 1 -type f -name "*.dsf" -print0 | parallel -0 -j "$JOBS" --bar do_convert {}

# --- ReplayGain Tagging ---
echo "--- Calculating and Embedding ReplayGain ---"
shopt -s nullglob
FLAC_FILES=("$OUTPUT_DIR"/*.flac)
shopt -u nullglob

if [[ ${#FLAC_FILES[@]} -gt 0 ]]; then
    metaflac --add-replay-gain "${FLAC_FILES[@]}"
fi

echo "-------------------------------------------------------"
echo "Process Finished Successfully!"
echo "Destination: $OUTPUT_DIR"
echo "-------------------------------------------------------"
