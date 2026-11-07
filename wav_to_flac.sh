#!/bin/bash

# --- Check for Dependencies ---
for cmd in ffmpeg parallel metaflac; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "Error: $cmd is not installed."
        exit 1
    fi
done

# --- Usage Check & Directory Setup ---
INPUT_DIR="${1:-.}"

if [ ! -d "$INPUT_DIR" ]; then
    echo "Error: Directory '$INPUT_DIR' does not exist."
    echo "Usage: $0 [path_to_folder_containing_audio]"
    exit 1
fi

# Export paths so subshells (parallel) can read them natively
export INPUT_DIR=$(realpath "$INPUT_DIR")
export OUTPUT_DIR="$INPUT_DIR/Converted_FLAC"

echo "--- Locating WAV and FLAC files and starting Batch Conversion ---"
mkdir -p "$OUTPUT_DIR"

# Count files (case-insensitive for both .wav and .flac)
FILE_COUNT=$(find "$INPUT_DIR" -maxdepth 1 \( -iname "*.wav" -o -iname "*.flac" \) | wc -l)
if [ "$FILE_COUNT" -eq 0 ]; then
    echo "Error: No .wav or .flac files found in '$INPUT_DIR'."
    exit 1
fi

echo "Found $FILE_COUNT files. Converting/Re-encoding to FLAC using maximum compression..."

# --- The Conversion Function ---
do_convert() {
    local input_file="$1"
    local base_name=$(basename "${input_file%.*}")
    local output_file="$OUTPUT_DIR/$base_name.flac"

    echo "Processing: $base_name"

    # EXPLANATION OF FFMPEG FLAGS:
    # -y                  : Overwrite output files without asking.
    # -c:a flac           : Use the FLAC audio codec.
    # -compression_level 12 : Maximum compression (standard FLAC CLI max is 8, FFmpeg goes to 12).
    #                       If the input is already a FLAC, this forces a re-encode to ensure
    #                       maximum compression optimization is uniformly applied.
    ffmpeg -hide_banner -loglevel error -y -i "$input_file" \
    -c:a flac -compression_level 12 "$output_file"
}

export -f do_convert

# --- Execute Parallel ---
# The escaped parentheses \( ... \) group the OR (-o) condition so -maxdepth applies to both.
find "$INPUT_DIR" -maxdepth 1 \( -iname "*.wav" -o -iname "*.flac" \) -print0 | parallel -0 do_convert {}

echo "--- Analyzing Audio and Applying ReplayGain ---"

# --- ReplayGain Album Detection Logic ---
apply_rg_to_list() {
    local list_file="$1"
    local type="$2"
    local flac_files=()

    echo "Detected $type: $(basename "$list_file"). Parsing for album grouping..."

    if [ "$type" == "CUE" ]; then
        while read -r line; do
            local audio_name=$(echo "$line" | grep -i '^FILE' | awk -F '"' '{print $2}')
            if [ -n "$audio_name" ]; then
                local base_name=$(basename "${audio_name%.*}")
                if [ -f "$OUTPUT_DIR/$base_name.flac" ]; then
                    flac_files+=("$OUTPUT_DIR/$base_name.flac")
                fi
            fi
        done < "$list_file"

    elif [ "$type" == "M3U" ]; then
        while read -r line; do
            if [[ -n "$line" && "$line" != \#* ]]; then
                local base_name=$(basename "${line%.*}")
                if [ -f "$OUTPUT_DIR/$base_name.flac" ]; then
                    flac_files+=("$OUTPUT_DIR/$base_name.flac")
                fi
            fi
        done < <(tr -d '\r' < "$list_file")
    fi

    if [ ${#flac_files[@]} -gt 0 ]; then
        echo "Applying ReplayGain to ${#flac_files[@]} files mapped from the $type playlist..."
        metaflac --add-replay-gain "${flac_files[@]}"
        return 0
    else
        echo "Warning: Could not map $type entries to the generated FLAC files."
        return 1
    fi
}

RG_APPLIED=0

# Search for the first available .cue or .m3u file in the input directory
CUE_FILE=$(find "$INPUT_DIR" -maxdepth 1 -iname "*.cue" | head -n 1)
M3U_FILE=$(find "$INPUT_DIR" -maxdepth 1 -iname "*.m3u" | head -n 1)

# Priority: CUE -> M3U -> Folder Scan
if [ -n "$CUE_FILE" ]; then
    apply_rg_to_list "$CUE_FILE" "CUE" && RG_APPLIED=1
elif [ -n "$M3U_FILE" ]; then
    apply_rg_to_list "$M3U_FILE" "M3U" && RG_APPLIED=1
fi

# Fallback mechanism
if [ "$RG_APPLIED" -eq 0 ]; then
    echo "No valid CUE/M3U mapping found. Treating all converted files as a single album..."
    metaflac --add-replay-gain "$OUTPUT_DIR"/*.flac
fi

echo "-------------------------------------------------------"
echo "Process Finished!"
echo "Your maximally compressed FLAC files are in: $OUTPUT_DIR"
echo "-------------------------------------------------------"
