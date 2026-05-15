#!/bin/bash

# --- Check for Dependencies ---
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
# 44100 or 88200 are recommended for DSD to maintain integer frequency families.
export SAMPLE_RATE=44100

# Export the output directory so subshells (parallel) can read it natively
export OUTPUT_DIR="$(pwd)/Converted_FLAC"

echo "--- Starting SACD Extraction ---"
# Extracting as DSF (Stereo only)
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

echo "Found $FILE_COUNT files. Converting to ${SAMPLE_RATE}Hz using SoX High-Precision Resampler..."

# --- The Conversion Function ---
do_convert() {
    local input_file="$1"
    local base_name=$(basename "${input_file%.dsf}")
    local output_file="$OUTPUT_DIR/$base_name.flac"

    echo "Processing: $base_name"

    # IMPROVEMENTS MADE HERE:
    # 1. Switched to 'soxr' resampler for superior math.
    # 2. 'precision=28' ensures 28-bit internal precision (virtually zero rounding error).
    # 3. 'cheby=1' enables a steep Chebyshev low-pass filter to wipe out DSD noise.
    # 4. Removed manual 'lowpass' filter as SoX handles it more accurately during resampling.
    ffmpeg -hide_banner -loglevel error -n -i "$input_file" \
    -af "aresample=resampler=soxr:osr=${SAMPLE_RATE}:dither_method=triangular:precision=28:cheby=1" \
    -c:a flac -sample_fmt s32 -bits_per_raw_sample 24 \
    -metadata disc="" -metadata DISCNUMBER="" "$output_file"
}

export -f do_convert

# --- Execute Parallel ---
find . -name "*.dsf" -print0 | parallel -0 do_convert {}

echo "--- Analyzing Audio and Applying ReplayGain ---"
metaflac --add-replay-gain "$OUTPUT_DIR"/*.flac

echo "-------------------------------------------------------"
echo "Process Finished!"
echo "Your high-fidelity 24-bit FLAC files are in: $OUTPUT_DIR"
echo "-------------------------------------------------------"
