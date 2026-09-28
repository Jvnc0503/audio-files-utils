#!/usr/bin/env bash

set -eo pipefail

# ==============================================================================
# SACD ISO to 24-bit FLAC Batch Transcoder
# Extracts DSD audio from SACD images, downsamples to linear PCM via SoX (VHQ),
# applies 24-bit TPDF dither, tags ReplayGain, and sorts into Artist - Album folders.
# ==============================================================================

# --- Dependency Check ---
DEPENDENCIES=(sacd_extract ffmpeg ffprobe sox parallel metaflac)
for cmd in "${DEPENDENCIES[@]}"; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "Error: Required dependency '$cmd' is not installed or not in PATH." >&2
        exit 1
    fi
done

# --- Usage & Validation ---
usage() {
    cat <<EOF
Usage: $(basename "$0") <file.iso|file.toc>

Arguments:
  <file.iso|file.toc>  Path to the SACD ISO image or TOC file to process.

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

INPUT_FILE="$1"
if [[ ! -f "$INPUT_FILE" ]]; then
    echo "Error: Input file '$INPUT_FILE' not found." >&2
    exit 1
fi

INPUT_FILE_ABS="$(realpath "$INPUT_FILE")"
INPUT_DIR="$(dirname "$INPUT_FILE_ABS")"

# --- Runtime Configuration ---
export SAMPLE_RATE="${SAMPLE_RATE:-44100}"
export JOBS="${JOBS:-6}"
export FFMPEG_THREADS="${FFMPEG_THREADS:-2}"
export OMP_NUM_THREADS="${OMP_NUM_THREADS:-2}"

# --- Setup Staging Directory & Cleanup Traps ---
TEMP_DSF_DIR="$(mktemp -d -p "$INPUT_DIR" .tmp_dsf_XXXXXX)"

cleanup() {
    if [[ -d "$TEMP_DSF_DIR" ]]; then
        echo "--- Cleaning up temporary files ---"
        rm -rf "$TEMP_DSF_DIR"
    fi
}
trap cleanup EXIT INT TERM

# --- 1. SACD Extraction ---
echo "--- Extracting Stereo DSF from SACD Image ---"
if ! sacd_extract -i "$INPUT_FILE_ABS" -s -2 -o "$TEMP_DSF_DIR" >/dev/null; then
    echo "Error: Extraction failed." >&2
    exit 1
fi

FILE_COUNT="$(find "$TEMP_DSF_DIR" -type f -name "*.dsf" | wc -l)"
if [[ "$FILE_COUNT" -eq 0 ]]; then
    echo "Error: No .dsf files produced by extractor." >&2
    exit 1
fi

# --- 2. Resolve Output Directory from Metadata ---
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

FIRST_DSF="$(find "$TEMP_DSF_DIR" -type f -name "*.dsf" | head -n 1)"
TAG_ARTIST="$(get_tag "artist" "$FIRST_DSF")"
TAG_ALBUM="$(get_tag "album" "$FIRST_DSF")"

# Replace slashes to prevent creating unintentional nested directories
TAG_ARTIST="${TAG_ARTIST//\//-}"
TAG_ALBUM="${TAG_ALBUM//\//-}"

# Fallback directory name: ISO filename without extension
DEFAULT_DIR_NAME="$(basename "${INPUT_FILE_ABS%.*}")"

if is_valid_tag "$TAG_ARTIST" && is_valid_tag "$TAG_ALBUM"; then
    DEST_SUBDIR="${TAG_ARTIST} - ${TAG_ALBUM}"
elif is_valid_tag "$TAG_ALBUM"; then
    DEST_SUBDIR="${TAG_ALBUM}"
elif is_valid_tag "$TAG_ARTIST"; then
    DEST_SUBDIR="${TAG_ARTIST} - ${DEFAULT_DIR_NAME}"
else
    DEST_SUBDIR="${DEFAULT_DIR_NAME}"
fi

export OUTPUT_DIR="$INPUT_DIR/$DEST_SUBDIR"
mkdir -p "$OUTPUT_DIR"

echo "Output Folder: $DEST_SUBDIR"
echo "Transcoding $FILE_COUNT tracks to ${SAMPLE_RATE}Hz / 24-bit FLAC using SoX VHQ..."

# --- 3. Transcoding Engine ---
do_convert() {
    local input_file="$1"
    local base_name
    base_name="$(basename "${input_file%.dsf}")"
    local output_file="$OUTPUT_DIR/$base_name.flac"

    ffmpeg -threads "$FFMPEG_THREADS" -hide_banner -loglevel error -i "$input_file" \
        -f sox - | \
        sox -t sox - -b 24 "$output_file" \
        rate -v -L "$SAMPLE_RATE" \
        dither
}
export -f do_convert

# --- 4. Parallel Processing ---
find "$TEMP_DSF_DIR" -type f -name "*.dsf" -print0 | parallel -0 -j "$JOBS" --bar do_convert {}

# --- 5. ReplayGain Tagging ---
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
