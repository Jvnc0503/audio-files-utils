#!/bin/bash

# --- Check for Dependencies ---
# Added 'metaflac' to ensure ReplayGain works
for cmd in sacd_extract ffmpeg parallel metaflac; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "Error: $cmd is not installed."
        exit 1
    fi
done

# --- Usage Check ---
if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <filename.iso or filename.toc>"
    exit 1
fi

INPUT_FILE="$1"

# --- Configuration ---
# Set your desired output sample rate here (e.g., 44100, 88200, 96000, 176400)
export SAMPLE_RATE=44100

# Automatically calculate the Nyquist frequency for the lowpass filter
export LOWPASS=$((SAMPLE_RATE / 2))

# Export the output directory so subshells (parallel) can read it natively
export OUTPUT_DIR="$(pwd)/Converted_FLAC"

echo "--- Starting SACD Extraction ---"
sacd_extract -i "$INPUT_FILE" -s -2

if [ $? -ne 0 ]; then
    echo "Extraction failed."
    exit 1
fi

echo "--- Locating DSF files and starting Batch Conversion ---"
mkdir -p "$OUTPUT_DIR"

FILE_COUNT=$(find . -name "*.dsf" | wc -l)
if [ "$FILE_COUNT" -eq 0 ]; then
    echo "Error: No .dsf files found."
    exit 1
fi

echo "Found $FILE_COUNT files. Converting at ${SAMPLE_RATE}Hz (Lowpass: ${LOWPASS}Hz)..."

# --- The Conversion Function ---
do_convert() {
    local input_file="$1"

    # Extract base filename safely
    local base_name=$(basename "${input_file%.dsf}")

    # Read OUTPUT_DIR directly from the environment
    local output_file="$OUTPUT_DIR/$base_name.flac"

    echo "Processing: $base_name"

    # Execute FFmpeg with all variables strictly quoted
    # Note: Volume gain is intentionally omitted here to prevent clipping
    ffmpeg -hide_banner -loglevel error -n -i "$input_file" \
    -af "lowpass=${LOWPASS}, aresample=${SAMPLE_RATE}:dither_method=triangular" \
    -c:a flac -sample_fmt s32 -bits_per_raw_sample 24 \
    -metadata disc="" -metadata DISCNUMBER="" "$output_file"
}

# Export the function itself
export -f do_convert

# --- Execute Parallel ---
# Convert all DSF files to unclipped FLAC
find . -name "*.dsf" -print0 | parallel -0 do_convert {}

echo "--- Analyzing Audio and Applying ReplayGain ---"
# This analyzes all files together to write both TRACK and ALBUM gain tags
metaflac --add-replay-gain "$OUTPUT_DIR"/*.flac

echo "-------------------------------------------------------"
echo "Process Finished!"
echo "Your unclipped, ReplayGain-tagged 24-bit FLAC files are in: $OUTPUT_DIR"
echo "-------------------------------------------------------"
