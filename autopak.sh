#!/bin/bash

# X-Seti - March23 2024 - AutoPak - Advanced Archive Repackaging Tool
# Version: 1.0

# Weird comments, "Me" to trying to find the missing "fi", I kept the comments in so others can learn.

# Default settings
RECURSIVE=false
DELETE_ORIGINAL=false
ARCHIVER="7z"
TARGET_DIR=""
DRY_RUN=false
QUIET=false
PARALLEL_JOBS=1
COMPRESSION_LEVEL=""
BACKUP_ORIGINAL=false
VERIFY_ARCHIVES=false
RESUME=false
CONFIG_FILE="$HOME/.autopak.conf"
INCLUDE_PATTERN=""
EXCLUDE_PATTERN=""
MIN_SIZE=0
MAX_SIZE=0
CPU_LIMIT=0  # 0 = no limit, 10 = 10%, 90 = 90%
NICE_LEVEL=0  # Process priority adjustment
SCAN_ONLY=false  # Only scan and report what would be done
EXTRACT_MULTIPART=false  # Extract multi-part archives to separate folders
REPAIR_CORRUPTED=false   # Attempt to repair corrupted RAR files before processing
KEEP_BROKEN_FILES=false  # Keep broken/partial files during extraction

# Statistics and progress tracking
TOTAL_FILES=0
PROCESSED_FILES=0
FAILED_FILES=()
SKIPPED_FILES=()
FAILED_JOBS=()  # Detailed failure tracking
START_TIME=$(date +%s)
ORIGINAL_SIZE=0
REPACKED_SIZE=0
SCAN_RESULTS=()  # Array to store scan results
CURRENT_PHASE=""  # Track current operation phase

# Logging
LOGFILE="/tmp/autopack_$(date +%Y%m%d_%H%M%S).log"
RESUME_FILE="/tmp/autopak_resume_$(basename "$0")_$$.state"
SCAN_CACHE_FILE="/tmp/autopak_scan_$(basename "$0")_$$.cache"
CPULIMIT_PID=""  # PID of cpulimit process if running

# Signal handling
cleanup_and_exit() {
    echo -e "\n🛑 Interrupted! Cleaning up..."
    [[ -d "$WORK_DIR" ]] && rm -rf "$WORK_DIR"
    [[ -f "$RESUME_FILE" ]] && rm -f "$RESUME_FILE"
    [[ -f "$SCAN_CACHE_FILE" ]] && rm -f "$SCAN_CACHE_FILE"
    
    # Kill any background CPU limiting processes
    if [[ -n "$CPULIMIT_PID" ]]; then
        kill "$CPULIMIT_PID" 2>/dev/null
    fi #1
    
    # Show partial statistics
    local end_time=$(date +%s)
    local duration=$((end_time - START_TIME))
    echo "⏱️ Partial run time: ${duration}s"
    echo "📊 Files processed: $PROCESSED_FILES/$TOTAL_FILES"
    echo "📋 Current phase: $CURRENT_PHASE"
    
    exit 130
} #closed cleanup_and_exit

trap cleanup_and_exit INT TERM

# Load configuration
load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
        [[ ! "$QUIET" == true ]] && echo "📋 Loaded config from: $CONFIG_FILE"
    fi #1
} #closed load_config

# Save configuration
save_config() {
    cat > "$CONFIG_FILE" << EOF
# AutoPak Configuration
ARCHIVER="$ARCHIVER"
COMPRESSION_LEVEL="$COMPRESSION_LEVEL"
PARALLEL_JOBS=$PARALLEL_JOBS
VERIFY_ARCHIVES=$VERIFY_ARCHIVES
BACKUP_ORIGINAL=$BACKUP_ORIGINAL
CPU_LIMIT=$CPU_LIMIT
NICE_LEVEL=$NICE_LEVEL
EXTRACT_MULTIPART=$EXTRACT_MULTIPART
REPAIR_CORRUPTED=$REPAIR_CORRUPTED
KEEP_BROKEN_FILES=$KEEP_BROKEN_FILES
EOF
    echo "💾 Configuration saved to: $CONFIG_FILE"
} #closed save_config

# CPU management functions
setup_cpu_limiting() {
    if (( CPU_LIMIT > 0 )); then
        if command -v cpulimit &> /dev/null; then
            [[ ! "$QUIET" == true ]] && echo "🔧 Setting CPU limit to ${CPU_LIMIT}%"
            cpulimit -l "$CPU_LIMIT" -p $$ &
            CPULIMIT_PID=$!
        else
            echo "⚠️ cpulimit not found, CPU limiting disabled"
            echo "Install with: sudo apt-get install cpulimit"
        fi #1
    fi #2
    
    if (( NICE_LEVEL != 0 )); then
        [[ ! "$QUIET" == true ]] && echo "🔧 Setting process priority (nice level: $NICE_LEVEL)"
        renice "$NICE_LEVEL" $ >/dev/null 2>&1
    fi #1
} #closed setup_cpu_limiting

# Advanced progress display
show_detailed_progress() {
    local current=$1
    local total=$2
    local filename="$3"
    local operation="$4"
    local size="$5"
    
    if [[ "$QUIET" == true ]]; then
        return
    fi #1
    
    local percent=$((current * 100 / total))
    local bar_length=40
    local filled_length=$((percent * bar_length / 100))
    
    local bar=""
    for ((i=0; i<filled_length; i++)); do bar+="█"; done
    for ((i=filled_length; i<bar_length; i++)); do bar+="░"; done
    
    local eta=""
    if (( current > 0 )); then
        local elapsed=$(($(date +%s) - START_TIME))
        local rate=$((current * 1000 / elapsed))  # files per second * 1000
        if (( rate > 0 )); then
            local remaining=$((total - current))
            local eta_seconds=$((remaining * 1000 / rate))
            local eta_min=$((eta_seconds / 60))
            local eta_sec=$((eta_seconds % 60))
            eta=" ETA: ${eta_min}m${eta_sec}s"
        fi #1
    fi #2
    
    printf "\r[$bar] %d%% (%d/%d) %s %s %s%s" \
           "$percent" "$current" "$total" "$operation" \
           "$(basename "$filename")" "$size" "$eta"
} #closed show_detailed_progress

# RAR repair functionality
repair_rar_file() {
    local rar_file="$1"
    local repair_dir="$2"
    local repaired_file=""
    
    [[ ! "$QUIET" == true ]] && echo "🔧 Attempting to repair: $(basename "$rar_file")"
    
    # Create repair directory if it doesn't exist
    mkdir -p "$repair_dir"
    
    # Method 1: Try WinRAR/RAR repair command
    if command -v rar &> /dev/null; then
        local repair_output="$repair_dir/rebuilt.$(basename "$rar_file")"
        if rar r -y "$rar_file" "$repair_output" >/dev/null 2>&1; then
            if [[ -f "$repair_output" ]]; then
                [[ ! "$QUIET" == true ]] && echo "✅ RAR repair successful using 'rar r' command"
                echo "$repair_output"
                return 0
            fi #3
        fi #2
    fi #1
    
    # Method 2: Try recovery volume reconstruction if .rev files exist
    if is_multipart_rar "$rar_file"; then
        local first_part=$(get_multipart_first_part "$rar_file")
        local dir_name=$(dirname "$first_part")
        
        # Check for .rev files
        if ls "$dir_name"/*.rev &>/dev/null; then
            [[ ! "$QUIET" == true ]] && echo "🔄 Found recovery volumes, attempting reconstruction..."
            
            # Copy all parts and rev files to repair directory
            cp "$dir_name"/*.part*.rar "$repair_dir"/ 2>/dev/null || true
            cp "$dir_name"/*.r[0-9]* "$repair_dir"/ 2>/dev/null || true
            cp "$dir_name"/*.part[0-9]* "$repair_dir"/ 2>/dev/null || true
            cp "$dir_name"/*.rev "$repair_dir"/ 2>/dev/null || true
            
            # Remove corrupted parts to force reconstruction
            rm -f "$repair_dir/$(basename "$rar_file")" 2>/dev/null
            
            # Try reconstruction
            local repair_first_part="$repair_dir/$(basename "$first_part")"
            if command -v rar &> /dev/null; then
                if rar rc -y "$repair_first_part" >/dev/null 2>&1; then
                    # Check if the original file was reconstructed
                    local reconstructed="$repair_dir/$(basename "$rar_file")"
                    if [[ -f "$reconstructed" ]]; then
                        [[ ! "$QUIET" == true ]] && echo "✅ RAR reconstruction successful using recovery volumes"
                        echo "$reconstructed"
                        return 0
                    fi #5
                fi #4
            fi #3
        fi #2
    fi #1
    
    # Method 3: Try 7-Zip repair (limited capability)
    if command -v 7z &> /dev/null; then
        local temp_extract="$repair_dir/7z_temp_extract"
        mkdir -p "$temp_extract"
        
        # Try to extract what we can with 7z
        if 7z x -y -o"$temp_extract" "$rar_file" >/dev/null 2>&1; then
            # Check if we got any files
            if [[ "$(ls -A "$temp_extract")" ]]; then
                [[ ! "$QUIET" == true ]] && echo "✅ Partial repair successful using 7-Zip extraction"
                echo "$temp_extract"
                return 0
            fi #3
        fi #2
        rm -rf "$temp_extract"
    fi #1
    
    # Method 4: Force extraction with keep broken files
    if $KEEP_BROKEN_FILES; then
        local broken_extract="$repair_dir/broken_extract"
        mkdir -p "$broken_extract"
        
        if command -v unrar &> /dev/null; then
            # Try unrar with keep broken files equivalent
            if unrar x -kb -y "$rar_file" "$broken_extract/" >/dev/null 2>&1; then
                if [[ "$(ls -A "$broken_extract")" ]]; then
                    [[ ! "$QUIET" == true ]] && echo "⚠️ Partial extraction successful (broken files kept)"
                    echo "$broken_extract"
                    return 0
                fi #4
            fi #3
        fi #2
        
        rm -rf "$broken_extract"
    fi #1
    
    [[ ! "$QUIET" == true ]] && echo "❌ RAR repair failed: $(basename "$rar_file")"
    return 1
} #closed repair_rar_file

# Check if RAR file appears corrupted
is_rar_corrupted() {
    local rar_file="$1"
    
    # Quick test with unrar
    if command -v unrar &> /dev/null; then
        if ! unrar t "$rar_file" >/dev/null 2>&1; then
            return 0  # Corrupted
        fi #2
    fi #1
    
    # Quick test with 7z
    if command -v 7z &> /dev/null; then
        if ! 7z t "$rar_file" >/dev/null 2>&1; then
            return 0  # Corrupted
        fi #2
    fi #1
    
    return 1  # Not corrupted or cannot test
} #closed is_rar_corrupted
is_multipart_rar() {
    local file="$1"
    # Check for various multi-part RAR naming conventions
    if [[ "$file" =~ \.(part[0-9]+\.rar|r[0-9]+)$ ]] || [[ "$file" =~ \.part[0-9]+$ ]]; then
        return 0
    fi #1
    return 1
} #closed is_multipart_rar

# Get the first part of a multi-part RAR archive
get_multipart_first_part() {
    local file="$1"
    local dir=$(dirname "$file")
    local basename=$(basename "$file")
    
    # Try different naming patterns
    if [[ "$basename" =~ ^(.*)\.part[0-9]+\.rar$ ]]; then
        # Format: archive.part01.rar, archive.part02.rar, etc.
        local base_name="${BASH_REMATCH[1]}"
        local first_part="$dir/${base_name}.part01.rar"
        [[ ! -f "$first_part" ]] && first_part="$dir/${base_name}.part001.rar"
        [[ ! -f "$first_part" ]] && first_part="$dir/${base_name}.part1.rar"
    elif [[ "$basename" =~ ^(.*)\.r[0-9]+$ ]]; then
        # Format: archive.rar, archive.r00, archive.r01, etc.
        local base_name="${BASH_REMATCH[1]}"
        local first_part="$dir/${base_name}.rar"
    elif [[ "$basename" =~ ^(.*)\.part[0-9]+$ ]]; then
        # Format: archive.part01, archive.part02, etc.
        local base_name="${BASH_REMATCH[1]}"
        local first_part="$dir/${base_name}.part01"
        [[ ! -f "$first_part" ]] && first_part="$dir/${base_name}.part001"
        [[ ! -f "$first_part" ]] && first_part="$dir/${base_name}.part1"
    else
        first_part="$file"
    fi #1
    
    echo "$first_part"
} #closed get_multipart_first_part

# File scanning with detailed information gathering
scan_files() {
    CURRENT_PHASE="Scanning files"
    [[ ! "$QUIET" == true ]] && echo "🔍 Phase 1: Scanning and analyzing files..."
    
    # Check if we have a cached scan
    if [[ -f "$SCAN_CACHE_FILE" ]] && $RESUME; then
        [[ ! "$QUIET" == true ]] && echo "📋 Loading cached scan results..."
        source "$SCAN_CACHE_FILE"
        return
    fi #1
    
    local counter=0
    local scan_start_time=$(date +%s)
    
    # Build find options for recursion
    local FIND_OPTS=()
    $RECURSIVE || FIND_OPTS+=(-maxdepth 1)
    
    # Get all potential files first
    local temp_files=()
    readarray -t temp_files < <(find "$TARGET_DIR" "${FIND_OPTS[@]}" -type f \( \
        -iname '*.zip' -o -iname '*.rar' -o -iname '*.7z' -o -iname '*.exe' -o \
        -iname '*.tar' -o -iname '*.tar.gz' -o -iname '*.tgz' -o -iname '*.tar.bz2' -o \
        -iname '*.tar.xz' -o -iname '*.tar.zst' -o -iname '*.gz' -o -iname '*.xz' -o \
        -iname '*.bz2' -o -iname '*.lz' -o -iname '*.lzh' -o -iname '*.lha' -o \
        -iname '*.cab' -o -iname '*.iso' -o -iname '*.img' -o -iname '*.dd' -o \
        -iname '*.deb' -o -iname '*.pkg' -o -iname '*.pac' -o -iname '*.pp' -o \
        -iname '*.ace' -o -iname '*.arj' -o -iname '*.z' -o -iname '*.Z' -o \
        -iname '*.r[0-9]*' -o -iname '*.part[0-9]*' \
        \) -print)
    
    local total_found=${#temp_files[@]}
    [[ ! "$QUIET" == true ]] && echo "📁 Found $total_found potential archive files"
    
    # Track processed multi-part archives to avoid duplicates
    local processed_multipart=()
    
    # Analyze each file
    SCAN_RESULTS=()
    for file in "${temp_files[@]}"; do
        ((counter++))
        
        local basename=$(basename "$file")
        local size=$(get_file_size "$file")
        local size_formatted=$(format_size "$size")
        
        [[ ! "$QUIET" == true ]] && show_detailed_progress "$counter" "$total_found" "$basename" "Scanning" "$size_formatted"
        
        # Apply filters
        local should_process=true
        local skip_reason=""
        
        # Check if this is a multi-part RAR and if we've already processed the set
        if is_multipart_rar "$file"; then
            local first_part=$(get_multipart_first_part "$file")
            
            # Check if we've already processed this multi-part set
            local already_processed=false
            for processed in "${processed_multipart[@]}"; do
                if [[ "$processed" == "$first_part" ]]; then
                    already_processed=true
                    break
                fi #3
            done
            
            if [[ "$already_processed" == true ]]; then
                should_process=false
                skip_reason="part of already processed multi-part archive"
            elif [[ "$file" != "$first_part" ]]; then
                should_process=false
                skip_reason="not first part of multi-part archive"
            else
                # This is the first part of a new multi-part set
                processed_multipart+=("$first_part")
            fi #2
        fi #1
        
        # Size filtering
        if [[ "$should_process" == true ]]; then
            if (( MIN_SIZE > 0 && size < MIN_SIZE )); then
                should_process=false
                skip_reason="too small"
            elif (( MAX_SIZE > 0 && size > MAX_SIZE )); then
                should_process=false
                skip_reason="too large"
            fi #2
        fi #1
        
        # Pattern filtering
        if [[ "$should_process" == true && -n "$INCLUDE_PATTERN" ]] && [[ ! "$basename" =~ $INCLUDE_PATTERN ]]; then
            should_process=false
            skip_reason="doesn't match include pattern"
        fi #1
        
        if [[ "$should_process" == true && -n "$EXCLUDE_PATTERN" ]] && [[ "$basename" =~ $EXCLUDE_PATTERN ]]; then
            should_process=false
            skip_reason="matches exclude pattern"
        fi #1
        
        # Skip already repacked files
        if [[ "$should_process" == true && "$file" =~ _repacked(\.new[0-9]*)?\.([7z|zip|tar\.(gz|xz|zst)|tar])$ ]]; then
            should_process=false
            skip_reason="already repacked"
        fi #1
        
        # Check if already processed (resume)
        if [[ "$should_process" == true ]] && $RESUME && is_already_processed "$file"; then
            should_process=false
            skip_reason="already processed"
        fi #1
        
        # Store scan result
        if [[ "$should_process" == true ]]; then
            SCAN_RESULTS+=("$file|$size|process")
            TOTAL_FILES=$((TOTAL_FILES + 1))
            ORIGINAL_SIZE=$((ORIGINAL_SIZE + size))
        else
            SCAN_RESULTS+=("$file|$size|skip|$skip_reason")
            SKIPPED_FILES+=("$file")
        fi #1
    done ##1
    
    # Cache scan results
    {
        echo "SCAN_RESULTS=("
        printf "'%s'\n" "${SCAN_RESULTS[@]}"
        echo ")"
        echo "TOTAL_FILES=$TOTAL_FILES"
        echo "ORIGINAL_SIZE=$ORIGINAL_SIZE"
        echo "SKIPPED_FILES=("
        printf "'%s'\n" "${SKIPPED_FILES[@]}"
        echo ")"
    } > "$SCAN_CACHE_FILE"
    
    local scan_duration=$(($(date +%s) - scan_start_time))
    [[ ! "$QUIET" == true ]] && echo -e "\n✅ Scan completed in ${scan_duration}s"
    [[ ! "$QUIET" == true ]] && echo "📊 Files to process: $TOTAL_FILES"
    [[ ! "$QUIET" == true ]] && echo "📊 Files to skip: ${#SKIPPED_FILES[@]}"
    [[ ! "$QUIET" == true ]] && echo "📊 Total size to process: $(format_size "$ORIGINAL_SIZE")"
} #closed scan_files

# Dependency checking
check_dependencies() {
    local missing_deps=()
    local optional_deps=()
    
    # Essential tools
    for cmd in find tar gzip; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_deps+=("$cmd")
        fi #1
    done ##1
    
    # Archiver-specific dependencies
    case "$ARCHIVER" in
        7z) [[ ! $(command -v 7z) ]] && missing_deps+=("p7zip-full") ;;
        zip) [[ ! $(command -v zip) ]] && missing_deps+=("zip") ;;
        zstd) [[ ! $(command -v zstd) ]] && missing_deps+=("zstd") ;;
        xz) [[ ! $(command -v xz) ]] && missing_deps+=("xz-utils") ;;
    esac
    
    # Optional tools for extraction
    for cmd in unrar unzip lha cabextract dpkg-deb zstd xz unace arj unarj uncompress; do
        if ! command -v "$cmd" &> /dev/null; then
            optional_deps+=("$cmd")
        fi #1
    done ##1
    
    if (( ${#missing_deps[@]} )); then
        echo "❌ Missing required dependencies:"
        printf "  • %s\n" "${missing_deps[@]}"
        
        # Detect package manager and show appropriate install command
        if command -v apt-get &> /dev/null; then
            echo "Install with: sudo apt-get install ${missing_deps[*]}"
        elif command -v pacman &> /dev/null; then
            echo "Install with: sudo pacman -S ${missing_deps[*]}"
        elif command -v yum &> /dev/null; then
            echo "Install with: sudo yum install ${missing_deps[*]}"
        elif command -v dnf &> /dev/null; then
            echo "Install with: sudo dnf install ${missing_deps[*]}"
        elif command -v zypper &> /dev/null; then
            echo "Install with: sudo zypper install ${missing_deps[*]}"
        elif command -v emerge &> /dev/null; then
            echo "Install with: sudo emerge ${missing_deps[*]}"
        elif command -v brew &> /dev/null; then
            echo "Install with: brew install ${missing_deps[*]}"
        else
            echo "Install using your system's package manager: ${missing_deps[*]}"
        fi #2
        exit 1
    fi #1
    
    if (( ${#optional_deps[@]} )) && [[ ! "$QUIET" == true ]]; then
        echo "⚠️ Optional dependencies missing (some formats may not be supported):"
        printf "  • %s\n" "${optional_deps[@]}"
    fi #1
} #closed check_dependencies

# Check available disk space
check_disk_space() {
    local target_dir="$1"
    local required_space_mb=$2
    
    local available_space=$(df -BM "$target_dir" | awk 'NR==2 {print $4}' | sed 's/M//')
    
    if (( available_space < required_space_mb )); then
        echo "❌ Insufficient disk space. Required: ${required_space_mb}MB, Available: ${available_space}MB"
        exit 1
    fi #1
} #closed check_disk_space

# Estimate required space
estimate_space_needed() {
    local total_size=0
    
    # Build find options for recursion
    local FIND_OPTS=()
    $RECURSIVE || FIND_OPTS+=(-maxdepth 1)
    
    while IFS= read -r -d '' file; do
        [[ -f "$file" ]] && total_size=$((total_size + $(stat -c%s "$file")))
    done < <(find "$TARGET_DIR" "${FIND_OPTS[@]}" -type f \( \
        -iname '*.zip' -o -iname '*.rar' -o -iname '*.7z' -o -iname '*.exe' -o \
        -iname '*.tar' -o -iname '*.tar.gz' -o -iname '*.tgz' -o -iname '*.tar.bz2' -o \
        -iname '*.tar.xz' -o -iname '*.tar.zst' -o -iname '*.gz' -o -iname '*.xz' -o \
        -iname '*.bz2' -o -iname '*.lz' -o -iname '*.lzh' -o -iname '*.lha' -o \
        -iname '*.cab' -o -iname '*.iso' -o -iname '*.img' -o -iname '*.dd' -o \
        -iname '*.deb' -o -iname '*.pkg' -o -iname '*.pac' -o -iname '*.pp' -o \
        -iname '*.ace' -o -iname '*.arj' -o -iname '*.z' -o -iname '*.Z' -o \
        -iname '*.r[0-9]*' -o -iname '*.part[0-9]*' \
        \) -print0) ##1
    
    # Estimate 150% of original size needed for temporary space
    echo $((total_size * 15 / 10 / 1024 / 1024))
} #closed estimate_space_needed

# Progress indicator
show_progress() {
    local current=$1
    local total=$2
    local filename="$3"
    
    if [[ "$QUIET" == true ]]; then
        return
    fi #1
    
    local percent=$((current * 100 / total))
    local bar_length=30
    local filled_length=$((percent * bar_length / 100))
    
    local bar=""
    for ((i=0; i<filled_length; i++)); do bar+="█"; done
    for ((i=filled_length; i<bar_length; i++)); do bar+="░"; done
    
    printf "\r[%s] %d%% (%d/%d) %s" "$bar" "$percent" "$current" "$total" "$filename"
} #closed show_progress

# Verify archive integrity
verify_archive() {
    local archive="$1"
    local archiver="$2"
    
    case "$archiver" in
        7z) 7z t "$archive" >/dev/null 2>&1 ;;
        zip) zip -T "$archive" >/dev/null 2>&1 ;;
        zstd|xz|gz|tar) tar -tf "$archive" >/dev/null 2>&1 ;;
        *) return 0 ;;  # Skip verification for unknown formats
    esac
} #closed verify_archive

# Get file size in bytes
get_file_size() {
    stat -c%s "$1" 2>/dev/null || echo "0"
} #closed get_file_size

# Format file size
format_size() {
    local size=$1
    if (( size < 1024 )); then
        echo "${size}B"
    elif (( size < 1048576 )); then
        echo "$((size / 1024))KB"
    elif (( size < 1073741824 )); then
        echo "$((size / 1048576))MB"
    else
        echo "$((size / 1073741824))GB"
    fi #1
} #closed format_size

# Calculate compression ratio
calc_compression_ratio() {
    local original=$1
    local compressed=$2
    
    if (( original == 0 )); then
        echo "0%"
        return
    fi #1
    
    local ratio=$((100 - (compressed * 100 / original)))
    echo "${ratio}%"
} #closed calc_compression_ratio

# Resume functionality
save_resume_state() {
    local processed_file="$1"
    echo "$processed_file" >> "$RESUME_FILE"
} #closed save_resume_state

is_already_processed() {
    local file="$1"
    [[ -f "$RESUME_FILE" ]] && grep -Fxq "$file" "$RESUME_FILE"
} #closed is_already_processed

# Generate output filename
generate_output_filename() {
    local base_name="$1"
    local extension="$2"
    local new_archive="${base_name}_repacked.${extension}"
    
    if [[ -e "$new_archive" ]]; then
        local i=1
        while [[ -e "${base_name}_repacked.new${i}.${extension}" ]]; do
            ((i++))
        done ##1
        new_archive="${base_name}_repacked.new${i}.${extension}"
    fi #1
    echo "$new_archive"
} #closed generate_output_filename

# Help function
show_help() {
    cat << EOF
Usage: $0 [OPTIONS] <directory>

AutoPak - Advanced Archive Repackaging Tool v1.0

OPTIONS:
    -r, --recursive           Process directories recursively
    -d, --delete-original     Delete original files after repacking
    -b, --backup-original     Create backup of original files before processing
    -n, --dry-run            Show what would be done without actually doing it
    -q, --quiet              Suppress non-essential output
    -v, --verify             Verify repacked archives before deleting originals
    -j, --jobs N             Number of parallel jobs (default: 1)
    -a, --arch ARCHIVER      Set archiver (7z|zip|zstd|xz|gz|tar) [default: 7z]
    -c, --compression LEVEL  Set compression level (0-9, archiver dependent)
    -i, --include PATTERN    Include files matching pattern
    -e, --exclude PATTERN    Exclude files matching pattern
    -m, --min-size SIZE      Minimum file size to process (e.g., 1M, 100K)
    -M, --max-size SIZE      Maximum file size to process (e.g., 1G, 500M)
    -R, --resume             Resume from previous interrupted run
    -C, --config FILE        Use specific configuration file
    -s, --save-config        Save current options as default configuration
    --cpu-limit PERCENT      Limit CPU usage to percentage (10, 50, 90, etc.)
    --nice-level N           Set process priority (-20 to 19, negative = higher priority)
    --scan-only              Only scan files and show what would be processed
    --extract-multipart      Extract multi-part archives to separate folders
    --repair-corrupted       Attempt to repair corrupted RAR files before processing
    --keep-broken-files      Keep broken/partial files during extraction
    -h, --help               Show this help message

SIZE FORMATS:
    Sizes can be specified with suffixes: K (KB), M (MB), G (GB)
    Examples: 100K, 50M, 2G

REPAIR AND RECOVERY:
    --repair-corrupted       Try to repair corrupted RAR files automatically
    --keep-broken-files      Extract partial data from damaged archives
    The script can use recovery volumes (.rev files) if available
    Multiple repair methods: WinRAR repair, 7-Zip extraction, recovery volumes

MULTI-PART RAR SUPPORT:
    The script automatically detects and handles multi-part RAR archives:
    - Formats: archive.part01.rar, archive.r00/r01, archive.part1
    - Only processes the first part, extracts complete archive
    - Use --extract-multipart to extract to individual folders

EXAMPLES:
    $0 /path/to/archives                        # Basic usage
    $0 -r -d -j 4 /path/to/archives            # Recursive, delete, 4 parallel jobs
    $0 --arch zip --compression 6 /path/to/dir  # Use zip with level 6 compression
    $0 -i "*.old.*" -e "*.backup.*" /path       # Include/exclude patterns
    $0 --min-size 1M --max-size 100M /path      # Size filtering
    $0 --verify --backup-original /path         # Safe mode with verification
    $0 --cpu-limit 10 --nice-level 10 /path     # Background processing (10% CPU)
    $0 --extract-multipart /path                # Extract multi-part RARs to folders
    $0 --scan-only /path                        # Preview what would be processed
    $0 --resume /path                           # Resume interrupted job

SUPPORTED FORMATS:
    Input:  zip, rar, 7z, exe, tar, tar.gz, tgz, tar.bz2, tar.xz, tar.zst,
            gz, xz, bz2, lz, lzh, lha, cab, iso, img, dd, deb, pkg, pac, pp,
            ace, arj, z, Z (compress), multi-part RAR (part01.rar, r00/r01, etc.)
    Output: 7z, zip, zstd, xz, gz, tar

EOF
} #closed show_help

# Parse size argument
parse_size() {
    local size_str="$1"
    local size_num="${size_str%[KMG]}"
    local size_unit="${size_str: -1}"
    
    case "$size_unit" in
        K) echo $((size_num * 1024)) ;;
        M) echo $((size_num * 1024 * 1024)) ;;
        G) echo $((size_num * 1024 * 1024 * 1024)) ;;
        *) echo "$size_str" ;;
    esac # size_unit
} #closed parse_size

# Parse arguments
parse_arguments() {
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            -r|--recursive) RECURSIVE=true ;;
            -d|--delete-original) DELETE_ORIGINAL=true ;;
            -b|--backup-original) BACKUP_ORIGINAL=true ;;
            -n|--dry-run) DRY_RUN=true ;;
            -q|--quiet) QUIET=true ;;
            -v|--verify) VERIFY_ARCHIVES=true ;;
            -R|--resume) RESUME=true ;;
            -s|--save-config) save_config; exit 0 ;;
            --scan-only) SCAN_ONLY=true ;;
            --extract-multipart) EXTRACT_MULTIPART=true ;;
            --repair-corrupted) REPAIR_CORRUPTED=true ;;
            --keep-broken-files) KEEP_BROKEN_FILES=true ;;
            --cpu-limit)
                shift
                CPU_LIMIT="$1"
                if ! [[ "$CPU_LIMIT" =~ ^[0-9]+$ ]] || (( CPU_LIMIT < 1 || CPU_LIMIT > 100 )); then
                    echo "❌ Invalid CPU limit: $CPU_LIMIT (must be 1-100)"
                    exit 1
                fi #1
                ;;
            --nice-level)
                shift
                NICE_LEVEL="$1"
                if ! [[ "$NICE_LEVEL" =~ ^-?[0-9]+$ ]] || (( NICE_LEVEL < -20 || NICE_LEVEL > 19 )); then
                    echo "❌ Invalid nice level: $NICE_LEVEL (must be -20 to 19)"
                    exit 1
                fi #1
                ;;
            -j|--jobs)
                shift
                PARALLEL_JOBS="$1"
                if ! [[ "$PARALLEL_JOBS" =~ ^[0-9]+$ ]] || (( PARALLEL_JOBS < 1 )); then
                    echo "❌ Invalid job count: $PARALLEL_JOBS"
                    exit 1
                fi #1
                ;;
            -a|--arch)
                shift
                ARCHIVER="$1"
                ;;
            -c|--compression)
                shift
                COMPRESSION_LEVEL="$1"
                ;;
            -i|--include)
                shift
                INCLUDE_PATTERN="$1"
                ;;
            -e|--exclude)
                shift
                EXCLUDE_PATTERN="$1"
                ;;
            -m|--min-size)
                shift
                MIN_SIZE=$(parse_size "$1")
                ;;
            -M|--max-size)
                shift
                MAX_SIZE=$(parse_size "$1")
                ;;
            -C|--config)
                shift
                CONFIG_FILE="$1"
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            -*)
                echo "❌ Unknown option: $1"
                echo "Use -h or --help for usage information"
                exit 1
                ;;
            *)
                TARGET_DIR="$1"
                ;;
        esac # in "$1"
        shift
    done ##1
} #closed parse_arguments

# Initialize logging
init_logging() {
    if [[ ! "$QUIET" == true ]]; then
        exec > >(tee -a "$LOGFILE") 2>&1
    else
        exec 2>> "$LOGFILE"
    fi #1
} #closed init_logging

# Main processing function
process_archive() {
    local FILE="$1"
    local current_num="$2"
    local total_num="$3"
    
    # Check if already processed (resume functionality)
    if $RESUME && is_already_processed "$FILE"; then
        [[ ! "$QUIET" == true ]] && echo "⏩ Already processed: $(basename "$FILE")"
        return 0
    fi #1
    
    local BASENAME=$(basename "$FILE")
    local EXT="${BASENAME##*.}"
    local STRIPPED_NAME="${BASENAME%.*}"
    local TMP_DIR="$WORK_DIR/${STRIPPED_NAME}_$$_$current_num"
    local original_size=$(get_file_size "$FILE")
    
    # Size filtering
    if (( MIN_SIZE > 0 && original_size < MIN_SIZE )); then
        [[ ! "$QUIET" == true ]] && echo "⏩ Skipping (too small): $BASENAME"
        SKIPPED_FILES+=("$FILE")
        return 0
    fi #1
    
    if (( MAX_SIZE > 0 && original_size > MAX_SIZE )); then
        [[ ! "$QUIET" == true ]] && echo "⏩ Skipping (too large): $BASENAME"
        SKIPPED_FILES+=("$FILE")
        return 0
    fi #1
    
    # Pattern filtering
    if [[ -n "$INCLUDE_PATTERN" ]] && [[ ! "$BASENAME" =~ $INCLUDE_PATTERN ]]; then
        [[ ! "$QUIET" == true ]] && echo "⏩ Skipping (not matching include pattern): $BASENAME"
        SKIPPED_FILES+=("$FILE")
        return 0
    fi #1
    
    if [[ -n "$EXCLUDE_PATTERN" ]] && [[ "$BASENAME" =~ $EXCLUDE_PATTERN ]]; then
        [[ ! "$QUIET" == true ]] && echo "⏩ Skipping (matching exclude pattern): $BASENAME"
        SKIPPED_FILES+=("$FILE")
        return 0
    fi #1
    
    # Skip already repacked files
    if [[ "$FILE" =~ _repacked(\.new[0-9]*)?\.([7z|zip|tar\.(gz|xz|zst)|tar])$ ]]; then
        [[ ! "$QUIET" == true ]] && echo "⏩ Skipping already repacked: $BASENAME"
        SKIPPED_FILES+=("$FILE")
        return 0
    fi #1
    
    mkdir -p "$TMP_DIR"
    
    [[ ! "$QUIET" == true ]] && show_progress "$current_num" "$total_num" "$BASENAME"
    [[ ! "$QUIET" == true ]] && echo -e "\n➡️ Processing: $BASENAME ($(format_size "$original_size"))"

    # Create backup if requested
    if $BACKUP_ORIGINAL && [[ ! "$DRY_RUN" == true ]]; then
        local backup_file="${FILE}.backup"
        cp "$FILE" "$backup_file"
        [[ ! "$QUIET" == true ]] && echo "💾 Created backup: $backup_file"
    fi #1

    # Special handling for multi-part archives and repair
    local EXTRACT_SUCCESS=true
    local is_multipart=false
    local multipart_folder=""
    local repair_attempted=false
    local using_repaired=false
    local current_file="$FILE"
    
    # Check if repair is needed and attempt it
    if $REPAIR_CORRUPTED && [[ "$EXT" =~ ^(rar|r[0-9]+|part[0-9]+)$ ]]; then
        if is_rar_corrupted "$FILE"; then
            [[ ! "$QUIET" == true ]] && echo "⚠️ Corrupted RAR detected: $(basename "$FILE")"
            local repair_dir="$TMP_DIR/repair_temp"
            local repaired_file=$(repair_rar_file "$FILE" "$repair_dir")
            
            if [[ -n "$repaired_file" && -e "$repaired_file" ]]; then
                if [[ -d "$repaired_file" ]]; then
                    # Repaired content is in a directory (broken extraction)
                    [[ ! "$QUIET" == true ]] && echo "✅ Using repaired content from: $(basename "$repaired_file")"
                    TMP_DIR="$repaired_file"
                    repair_attempted=true
                    using_repaired=true
                    EXTRACT_SUCCESS=true
                else
                    # Repaired file is a new archive
                    [[ ! "$QUIET" == true ]] && echo "✅ Using repaired archive: $(basename "$repaired_file")"
                    current_file="$repaired_file"
                    repair_attempted=true
                    using_repaired=true
                fi #4
            else
                [[ ! "$QUIET" == true ]] && echo "❌ RAR repair failed, will attempt normal extraction"
                repair_attempted=true
            fi #3
        fi #2
    fi #1
    
    # Skip extraction if we already have repaired content in TMP_DIR
    if [[ "$using_repaired" == true && -d "$TMP_DIR" && "$(ls -A "$TMP_DIR")" ]]; then
        EXTRACT_SUCCESS=true
    else
        # Check if this is a multi-part RAR and handle accordingly
        if is_multipart_rar "$current_file"; then
            is_multipart=true
            local first_part=$(get_multipart_first_part "$current_file")
            
            if $EXTRACT_MULTIPART; then
                # Create a dedicated folder for multi-part extraction
                local archive_name="${BASENAME%.*}"
                # Remove part numbers from folder name
                archive_name=$(echo "$archive_name" | sed -E 's/\.(part[0-9]+|r[0-9]+|part[0-9]+)$//')
                multipart_folder="$TMP_DIR/${archive_name}_extracted"
                mkdir -p "$multipart_folder"
                [[ ! "$QUIET" == true ]] && echo "📁 Extracting multi-part RAR to: $(basename "$multipart_folder")"
                
                # Extract using the first part
                if $KEEP_BROKEN_FILES; then
                    unrar x -kb -inul "$first_part" "$multipart_folder/" 2>/dev/null || \
                    7z x -bd -y -o"$multipart_folder" "$first_part" >/dev/null 2>&1 || \
                    EXTRACT_SUCCESS=false
                else
                    unrar x -inul "$first_part" "$multipart_folder/" 2>/dev/null || \
                    7z x -bd -y -o"$multipart_folder" "$first_part" >/dev/null 2>&1 || \
                    EXTRACT_SUCCESS=false
                fi #4 -1
                
                # Set extraction directory to the multipart folder
                TMP_DIR="$multipart_folder"
            else
                # Standard extraction to temporary directory
                [[ ! "$QUIET" == true ]] && echo "📦 Processing multi-part RAR: $BASENAME"
                if $KEEP_BROKEN_FILES; then
                    unrar x -kb -inul "$first_part" "$TMP_DIR/" 2>/dev/null || \
                    7z x -bd -y -o"$TMP_DIR" "$first_part" >/dev/null 2>&1 || \
                    EXTRACT_SUCCESS=false
                else
                    unrar x -inul "$first_part" "$TMP_DIR/" 2>/dev/null || \
                    7z x -bd -y -o"$TMP_DIR" "$first_part" >/dev/null 2>&1 || \
                    EXTRACT_SUCCESS=false
                fi #4 -2
            fi #3 -1
        else
            # Standard extraction handler for non-multipart archives
            case "$EXT" in
                zip) 
                    # Try multiple unzip methods for better compatibility with old/damaged ZIP files
                    unzip -qq "$current_file" -d "$TMP_DIR" 2>/dev/null || \
                    unzip -j -qq "$current_file" -d "$TMP_DIR" 2>/dev/null || \
                    7z x -bd -y -o"$TMP_DIR" "$current_file" >/dev/null 2>&1 || \
                    EXTRACT_SUCCESS=false
                    ;;
                rar) 
                    if $KEEP_BROKEN_FILES; then
                        unrar x -kb -inul "$current_file" "$TMP_DIR/" 2>/dev/null || \
                        7z x -bd -y -o"$TMP_DIR" "$current_file" >/dev/null 2>&1 || \
                        EXTRACT_SUCCESS=false
                    else
                        unrar x -inul "$current_file" "$TMP_DIR/" 2>/dev/null || \
                        7z x -bd -y -o"$TMP_DIR" "$current_file" >/dev/null 2>&1 || \
                        EXTRACT_SUCCESS=false
                    fi #4 -3
                    ;;
            7z|exe) 
                7z x -bd -y -o"$TMP_DIR" "$FILE" >/dev/null 2>&1 || EXTRACT_SUCCESS=false
                ;;
            tar) 
                tar -xf "$FILE" -C "$TMP_DIR" 2>/dev/null || EXTRACT_SUCCESS=false
                ;;
            tgz|gz) 
                if [[ "$BASENAME" == *.tar.gz ]] || [[ "$BASENAME" == *.tgz ]]; then
                    tar -xzf "$FILE" -C "$TMP_DIR" 2>/dev/null || EXTRACT_SUCCESS=false
                else
                    gunzip -c "$FILE" > "$TMP_DIR/${STRIPPED_NAME}" 2>/dev/null || EXTRACT_SUCCESS=false
                fi #3 -2
                ;;
            xz) 
                if [[ "$BASENAME" == *.tar.xz ]]; then
                    tar -xJf "$FILE" -C "$TMP_DIR" 2>/dev/null || EXTRACT_SUCCESS=false
                else
                    unxz -c "$FILE" > "$TMP_DIR/${STRIPPED_NAME}" 2>/dev/null || EXTRACT_SUCCESS=false
                fi #3 -3
                ;;
            bz2) 
                if [[ "$BASENAME" == *.tar.bz2 ]]; then
                    tar -xjf "$FILE" -C "$TMP_DIR" 2>/dev/null || EXTRACT_SUCCESS=false
                else
                    bunzip2 -c "$FILE" > "$TMP_DIR/${STRIPPED_NAME}" 2>/dev/null || EXTRACT_SUCCESS=false
                fi #3 -4
                ;;
            zst) 
                if [[ "$BASENAME" == *.tar.zst ]]; then
                    tar --use-compress-program=unzstd -xf "$FILE" -C "$TMP_DIR" 2>/dev/null || EXTRACT_SUCCESS=false
                else
                    zstd -d -c "$FILE" > "$TMP_DIR/${STRIPPED_NAME}" 2>/dev/null || EXTRACT_SUCCESS=false
                fi #3 -5
                ;;
            lzh|lha) 
                lha xqf "$FILE" "$TMP_DIR" 2>/dev/null || \
                lhasa x "$FILE" -C "$TMP_DIR" 2>/dev/null || \
                7z x -bd -y -o"$TMP_DIR" "$FILE" >/dev/null 2>&1 || \
                EXTRACT_SUCCESS=false
                ;;
            cab) 
                cabextract -d "$TMP_DIR" "$FILE" >/dev/null 2>&1 || \
                7z x -bd -y -o"$TMP_DIR" "$FILE" >/dev/null 2>&1 || \
                EXTRACT_SUCCESS=false
                ;;
            iso|img|dd)
                7z x -bd -y -o"$TMP_DIR" "$FILE" >/dev/null 2>&1 || EXTRACT_SUCCESS=false
                ;;
            deb)
                dpkg-deb -x "$FILE" "$TMP_DIR" 2>/dev/null || \
                (ar x "$FILE" 2>/dev/null && \
                tar -xf data.tar.* -C "$TMP_DIR" 2>/dev/null) || \
                EXTRACT_SUCCESS=false
                ;;
            pkg|pac|pp)
                7z x -bd -y -o"$TMP_DIR" "$FILE" >/dev/null 2>&1 || EXTRACT_SUCCESS=false
                ;;
            ace)
                # ACE archive support - try multiple methods
                if command -v unace &> /dev/null; then
                    unace x "$FILE" "$TMP_DIR/" 2>/dev/null || EXTRACT_SUCCESS=false
                elif command -v 7z &> /dev/null; then
                    7z x -bd -y -o"$TMP_DIR" "$FILE" >/dev/null 2>&1 || EXTRACT_SUCCESS=false
                else
                    [[ ! "$QUIET" == true ]] && echo "⚠️ ACE support requires 'unace' or 7z with ACE plugin"
                    EXTRACT_SUCCESS=false
                fi #3 -6
                ;;
            arj)
                # ARJ archive support
                if command -v arj &> /dev/null; then
                    arj x "$FILE" "$TMP_DIR/" 2>/dev/null || EXTRACT_SUCCESS=false
                elif command -v unarj &> /dev/null; then
                    unarj x "$FILE" "$TMP_DIR/" 2>/dev/null || EXTRACT_SUCCESS=false
                elif command -v 7z &> /dev/null; then
                    7z x -bd -y -o"$TMP_DIR" "$FILE" >/dev/null 2>&1 || EXTRACT_SUCCESS=false
                else
                    [[ ! "$QUIET" == true ]] && echo "⚠️ ARJ support requires 'arj', 'unarj', or 7z with ARJ plugin"
                    EXTRACT_SUCCESS=false
                fi #3 -7
                ;;
            z|Z)
                # Unix compress (.Z) and pack (.z) format support
                if command -v uncompress &> /dev/null; then
                    uncompress -c "$FILE" > "$TMP_DIR/${STRIPPED_NAME}" 2>/dev/null || EXTRACT_SUCCESS=false
                elif command -v gzip &> /dev/null; then
                    # gzip can sometimes handle .Z files
                    gzip -dc "$FILE" > "$TMP_DIR/${STRIPPED_NAME}" 2>/dev/null || EXTRACT_SUCCESS=false
                elif command -v 7z &> /dev/null; then
                    7z x -bd -y -o"$TMP_DIR" "$FILE" >/dev/null 2>&1 || EXTRACT_SUCCESS=false
                else
                    [[ ! "$QUIET" == true ]] && echo "⚠️ Compress format support requires 'uncompress', 'gzip', or 7z"
                    EXTRACT_SUCCESS=false
                fi #3 -8
                ;;
            r[0-9]*|part[0-9]*)
                # Handle remaining multi-part files that weren't caught earlier
                local first_part=$(get_multipart_first_part "$FILE")
                unrar x -inul "$first_part" "$TMP_DIR/" 2>/dev/null || \
                7z x -bd -y -o"$TMP_DIR" "$first_part" >/dev/null 2>&1 || \
                EXTRACT_SUCCESS=false
                ;;
            *)
                [[ ! "$QUIET" == true ]] && echo "❓ Unsupported extension: $EXT"
                EXTRACT_SUCCESS=false
                ;;
        esac # in "$EXT"
        fi #2
    fi #1 - was missing

    if [[ "$EXTRACT_SUCCESS" != true ]]; then
        [[ ! "$QUIET" == true ]] && echo "❌ Failed to extract: $BASENAME"
        FAILED_FILES+=("$FILE")
        rm -rf "$TMP_DIR"
        [[ -n "$multipart_folder" && -d "$multipart_folder" ]] && rm -rf "$multipart_folder"
        return 1
    fi #1

    # Check if extraction resulted in any files
    if [[ ! "$(ls -A "$TMP_DIR")" ]]; then
        [[ ! "$QUIET" == true ]] && echo "❌ Empty archive: $BASENAME"
        FAILED_FILES+=("$FILE")
        rm -rf "$TMP_DIR"
        [[ -n "$multipart_folder" && -d "$multipart_folder" ]] && rm -rf "$multipart_folder"
        return 1
    fi #1

    # For multi-part extraction mode, we're done - just leave the extracted folder
    if $EXTRACT_MULTIPART && [[ "$is_multipart" == true ]]; then
        [[ ! "$QUIET" == true ]] && echo "✅ Multi-part archive extracted to: $(basename "$TMP_DIR")"
        save_resume_state "$FILE"
        PROCESSED_FILES=$((PROCESSED_FILES + 1))
        return 0
    fi #1

    # Determine output filename
    local NEW_ARCHIVE
    case "$ARCHIVER" in
        7z) NEW_ARCHIVE=$(generate_output_filename "${FILE%.*}" "7z") ;;
        zip) NEW_ARCHIVE=$(generate_output_filename "${FILE%.*}" "zip") ;;
        zstd) NEW_ARCHIVE=$(generate_output_filename "${FILE%.*}" "tar.zst") ;;
        xz) NEW_ARCHIVE=$(generate_output_filename "${FILE%.*}" "tar.xz") ;;
        gz) NEW_ARCHIVE=$(generate_output_filename "${FILE%.*}" "tar.gz") ;;
        tar) NEW_ARCHIVE=$(generate_output_filename "${FILE%.*}" "tar") ;;
    esac # in "$ARCHIVER"

    if $DRY_RUN; then
        [[ ! "$QUIET" == true ]] && echo "💡 Would repack: $BASENAME → $(basename "$NEW_ARCHIVE")"
        if $DELETE_ORIGINAL; then
            [[ ! "$QUIET" == true ]] && echo "💡 Would delete original: $BASENAME"
        fi #2 -1
    else
        [[ ! "$QUIET" == true ]] && echo "📦 Repacking to: $(basename "$NEW_ARCHIVE")"
        local REPACK_SUCCESS=true
        
        # Set compression level
        local comp_opts=""
        if [[ -n "$COMPRESSION_LEVEL" ]]; then
            case "$ARCHIVER" in
                7z) comp_opts="-mx=$COMPRESSION_LEVEL" ;;
                zip) comp_opts="-$COMPRESSION_LEVEL" ;;
                zstd) comp_opts="-$COMPRESSION_LEVEL" ;;
                xz) comp_opts="-$COMPRESSION_LEVEL" ;;
                gz) comp_opts="-$COMPRESSION_LEVEL" ;;
            esac
        fi #2 -2
        
        case "$ARCHIVER" in
            7z)
                7z a -t7z ${comp_opts:-"-mx=9"} -m0=lzma2 "$NEW_ARCHIVE" "$TMP_DIR"/* >/dev/null 2>&1 || REPACK_SUCCESS=false
                ;;
            zip)
                (cd "$TMP_DIR" && zip -r ${comp_opts:-"-9"} -q "$NEW_ARCHIVE" * 2>/dev/null) || REPACK_SUCCESS=false
                ;;
            zstd)
                tar -C "$TMP_DIR" -cf - . | zstd ${comp_opts:-"-19"} -T0 -o "$NEW_ARCHIVE" 2>/dev/null || REPACK_SUCCESS=false
                ;;
            xz)
                tar -C "$TMP_DIR" -cf - . | xz ${comp_opts:-"-9"} -c > "$NEW_ARCHIVE" 2>/dev/null || REPACK_SUCCESS=false
                ;;
            gz)
                tar -C "$TMP_DIR" -c${comp_opts:-"z"}f "$NEW_ARCHIVE" . 2>/dev/null || REPACK_SUCCESS=false
                ;;
            tar)
                tar -C "$TMP_DIR" -cf "$NEW_ARCHIVE" . 2>/dev/null || REPACK_SUCCESS=false
                ;;
        esac # in "$ARCHIVER"

        if [[ "$REPACK_SUCCESS" != true ]]; then
            [[ ! "$QUIET" == true ]] && echo "❌ Failed to repack: $BASENAME"
            FAILED_FILES+=("$FILE")
            rm -rf "$TMP_DIR"
            [[ -n "$multipart_folder" && -d "$multipart_folder" ]] && rm -rf "$multipart_folder"
            return 1
        fi #2 -3

        # Verify repacked archive if requested
        if $VERIFY_ARCHIVES; then
            if ! verify_archive "$NEW_ARCHIVE" "$ARCHIVER"; then
                [[ ! "$QUIET" == true ]] && echo "❌ Archive verification failed: $(basename "$NEW_ARCHIVE")"
                FAILED_FILES+=("$FILE")
                rm -f "$NEW_ARCHIVE"
                rm -rf "$TMP_DIR"
                [[ -n "$multipart_folder" && -d "$multipart_folder" ]] && rm -rf "$multipart_folder"
                return 1
            fi
            [[ ! "$QUIET" == true ]] && echo "✅ Archive verified: $(basename "$NEW_ARCHIVE")"
        fi #2 -4

        # Calculate and display compression statistics
        local new_size=$(get_file_size "$NEW_ARCHIVE")
        local compression_ratio=$(calc_compression_ratio "$original_size" "$new_size")
        
        REPACKED_SIZE=$((REPACKED_SIZE + new_size))
        
        [[ ! "$QUIET" == true ]] && echo "📊 Size: $(format_size "$original_size") → $(format_size "$new_size") (${compression_ratio} compression)"

        # Handle original file
        if $DELETE_ORIGINAL; then
            [[ ! "$QUIET" == true ]] && echo "🗑️ Deleting original: $BASENAME"
            rm -f "$FILE"
            
            # For multi-part RAR files, also delete the related parts
            if [[ "$is_multipart" == true ]]; then
                local dir=$(dirname "$FILE")
                local basename_no_ext=$(basename "$FILE")
                
                # Remove different multi-part file patterns
                if [[ "$basename_no_ext" =~ ^(.*)\.part[0-9]+\.rar$ ]]; then
                    local base_name="${BASH_REMATCH[1]}"
                    rm -f "$dir/${base_name}".part*.rar 2>/dev/null
                    [[ ! "$QUIET" == true ]] && echo "🗑️ Deleted multi-part RAR set: ${base_name}.part*.rar"
                elif [[ "$basename_no_ext" =~ ^(.*)\.rar$ ]]; then
                    local base_name="${BASH_REMATCH[1]}"
                    rm -f "$dir/${base_name}".r[0-9]* 2>/dev/null
                    [[ ! "$QUIET" == true ]] && echo "🗑️ Deleted multi-part RAR set: ${base_name}.r*"
                elif [[ "$basename_no_ext" =~ ^(.*)\.part[0-9]+$ ]]; then
                    local base_name="${BASH_REMATCH[1]}"
                    rm -f "$dir/${base_name}".part[0-9]* 2>/dev/null
                    [[ ! "$QUIET" == true ]] && echo "🗑️ Deleted multi-part set: ${base_name}.part*"
                fi #4
            fi #3
        fi #2
    fi #1

    # Clean up temporary directory
    rm -rf "$TMP_DIR"
    [[ -n "$multipart_folder" && -d "$multipart_folder" ]] && rm -rf "$multipart_folder"
    
    # Save resume state
    save_resume_state "$FILE"
    
    PROCESSED_FILES=$((PROCESSED_FILES + 1))
    [[ ! "$QUIET" == true ]] && echo "✅ Done: $BASENAME"
    
    return 0
} #closed process_archive

# Export function for use in parallel processing
export -f process_archive
export -f get_file_size
export -f format_size
export -f calc_compression_ratio
export -f verify_archive
export -f generate_output_filename
export -f save_resume_state
export -f is_already_processed
export -f is_multipart_rar
export -f get_multipart_first_part
export -f repair_rar_file
export -f is_rar_corrupted

# Main execution
main() {
    # Save original argument count before parsing
    local original_arg_count=$#

    # Load configuration first
    load_config

    # Parse command line arguments (these override config)
    parse_arguments "$@"

    # Initialize logging
    init_logging

    # Validate inputs - handle different error scenarios
    # Case 1: No arguments at all - show help
    if [[ $original_arg_count -eq 0 ]]; then
        show_help
        exit 1
    fi

    # Case 2: Directory not specified but other options given
    if [[ -z "$TARGET_DIR" ]]; then
        echo "❌ Error: No directory specified"
        echo "💡 Usage: $(basename "$0") [OPTIONS] <directory>"
        exit 1
    fi

    # Case 3: Directory specified but doesn't exist
    if [[ ! -d "$TARGET_DIR" ]]; then
        echo "❌ Error: Directory '$TARGET_DIR' doesn't exist or is not accessible"
        echo "💡 Please check the path and try again"
        exit 1
    fi

    # Validate archiver
    case "$ARCHIVER" in
        7z|zip|zstd|xz|gz|tar) ;;
        *) echo "❌ Invalid archiver: $ARCHIVER"; exit 2 ;;
    esac # in "$ARCHIVER"

    # Check dependencies
    check_dependencies

    # Setup CPU management
    setup_cpu_limiting

    # Setup work directory
    WORK_DIR="/tmp/autopack_tmp_$"
    mkdir -p "$WORK_DIR"

    # Phase 1: Scan and analyze files
    scan_files
    
    # Early exit for scan-only mode
    if $SCAN_ONLY; then
        echo
        echo "📋 Scan Results Summary:"
        echo "========================"
        echo "📁 Total files found: $((TOTAL_FILES + ${#SKIPPED_FILES[@]}))"
        echo "✅ Files to process: $TOTAL_FILES"
        echo "⏩ Files to skip: ${#SKIPPED_FILES[@]}"
        echo "📊 Total size to process: $(format_size "$ORIGINAL_SIZE")"
        
        if (( ${#SKIPPED_FILES[@]} > 0 )) && [[ ! "$QUIET" == true ]]; then
            echo
            echo "⏩ Skipped files:"
            for result in "${SCAN_RESULTS[@]}"; do
                IFS='|' read -r file size action reason <<< "$result"
                if [[ "$action" == "skip" ]]; then
                    echo "  • $(basename "$file") ($(format_size "$size")) - $reason"
                fi
            done
        fi #2
        
        echo
        echo "💡 Use without --scan-only to process these files"
        cleanup_and_exit
        return
    fi #1

    if (( TOTAL_FILES == 0 )); then
        echo "❌ No archive files to process after filtering"
        exit 1
    fi #1

    # Check disk space
    if [[ ! "$DRY_RUN" == true ]]; then
        local estimated_space=$(estimate_space_needed)
        check_disk_space "$TARGET_DIR" "$estimated_space"
    fi #1

    # Display configuration
    if [[ ! "$QUIET" == true ]]; then
        echo
        echo "📋 Processing Configuration:"
        echo "============================="
        echo "🔍 Target directory: $TARGET_DIR"
        echo "📦 Archiver: $ARCHIVER"
        echo "🔄 Recursive: $RECURSIVE"
        echo "🗑️ Delete original: $DELETE_ORIGINAL"
        echo "💾 Backup original: $BACKUP_ORIGINAL"
        echo "✅ Verify archives: $VERIFY_ARCHIVES"
        echo "📁 Extract multi-part: $EXTRACT_MULTIPART"
        echo "🔧 Repair corrupted: $REPAIR_CORRUPTED"
        echo "🛠️ Keep broken files: $KEEP_BROKEN_FILES"
        echo "💡 Dry run: $DRY_RUN"
        echo "🔇 Quiet mode: $QUIET"
        echo "⚡ Parallel jobs: $PARALLEL_JOBS"
        [[ $CPU_LIMIT -gt 0 ]] && echo "🔧 CPU limit: ${CPU_LIMIT}%"
        [[ $NICE_LEVEL -ne 0 ]] && echo "🔧 Nice level: $NICE_LEVEL"
        [[ -n "$COMPRESSION_LEVEL" ]] && echo "📊 Compression level: $COMPRESSION_LEVEL"
        [[ -n "$INCLUDE_PATTERN" ]] && echo "🎯 Include pattern: $INCLUDE_PATTERN"
        [[ -n "$EXCLUDE_PATTERN" ]] && echo "🚫 Exclude pattern: $EXCLUDE_PATTERN"
        [[ $MIN_SIZE -gt 0 ]] && echo "📏 Min size: $(format_size "$MIN_SIZE")"
        [[ $MAX_SIZE -gt 0 ]] && echo "📏 Max size: $(format_size "$MAX_SIZE")"
        echo "📝 Log file: $LOGFILE"
        echo "📁 Files to process: $TOTAL_FILES"
        echo "📊 Total size: $(format_size "$ORIGINAL_SIZE")"
        echo
    fi #1

    # Phase 2: Process files
    CURRENT_PHASE="Processing files"
    [[ ! "$QUIET" == true ]] && echo "🔄 Phase 2: Processing archive files..."
    
    # Create processing queue from scan results
    local processing_queue=()
    for result in "${SCAN_RESULTS[@]}"; do
        IFS='|' read -r file size action reason <<< "$result"
        if [[ "$action" == "process" ]]; then
            processing_queue+=("$file")
        fi #1
    done

    # Process files
    if (( PARALLEL_JOBS > 1 )); then
        # Parallel processing using xargs with proper environment
        printf '%s\n' "${processing_queue[@]}" | \
        WORK_DIR="$WORK_DIR" \
        ARCHIVER="$ARCHIVER" \
        COMPRESSION_LEVEL="$COMPRESSION_LEVEL" \
        DELETE_ORIGINAL="$DELETE_ORIGINAL" \
        BACKUP_ORIGINAL="$BACKUP_ORIGINAL" \
        VERIFY_ARCHIVES="$VERIFY_ARCHIVES" \
        EXTRACT_MULTIPART="$EXTRACT_MULTIPART" \
        REPAIR_CORRUPTED="$REPAIR_CORRUPTED" \
        KEEP_BROKEN_FILES="$KEEP_BROKEN_FILES" \
        DRY_RUN="$DRY_RUN" \
        QUIET="$QUIET" \
        RESUME="$RESUME" \
        RESUME_FILE="$RESUME_FILE" \
        MIN_SIZE="$MIN_SIZE" \
        MAX_SIZE="$MAX_SIZE" \
        INCLUDE_PATTERN="$INCLUDE_PATTERN" \
        EXCLUDE_PATTERN="$EXCLUDE_PATTERN" \
        SKIPPED_FILES="$SKIPPED_FILES" \
        FAILED_FILES="$FAILED_FILES" \
        PROCESSED_FILES="$PROCESSED_FILES" \
        REPACKED_SIZE="$REPACKED_SIZE" \
        xargs -P "$PARALLEL_JOBS" -I {} bash -c 'process_archive "{}" 1 '"$TOTAL_FILES"
    else
        # Sequential processing
        local counter=0
        for file in "${processing_queue[@]}"; do
            ((counter++))
            process_archive "$file" "$counter" "$TOTAL_FILES"
        done ##1
    fi #1

    # Cleanup
    rm -rf "$WORK_DIR"
    [[ -f "$RESUME_FILE" ]] && rm -f "$RESUME_FILE"
    [[ -f "$SCAN_CACHE_FILE" ]] && rm -f "$SCAN_CACHE_FILE"

    # Stop CPU limiting if active
    if [[ -n "$CPULIMIT_PID" ]]; then
        kill "$CPULIMIT_PID" 2>/dev/null
    fi #1

    # Final statistics
    local end_time=$(date +%s)
    local duration=$((end_time - START_TIME))
    local hours=$((duration / 3600))
    local minutes=$(((duration % 3600) / 60))
    local seconds=$((duration % 60))
    
    echo
    echo "📋 Final Summary:"
    echo "===================="
    echo "📁 Total files found: $((TOTAL_FILES + ${#SKIPPED_FILES[@]}))"
    echo "✅ Successfully processed: $PROCESSED_FILES"
    echo "❌ Failed: ${#FAILED_FILES[@]}"
    echo "⏩ Skipped: ${#SKIPPED_FILES[@]}"
    
    if (( PROCESSED_FILES > 0 )) && [[ ! "$DRY_RUN" == true ]]; then
        echo "📊 Original total size: $(format_size "$ORIGINAL_SIZE")"
        echo "📊 Repacked total size: $(format_size "$REPACKED_SIZE")"
        local total_ratio=$(calc_compression_ratio "$ORIGINAL_SIZE" "$REPACKED_SIZE")
        echo "📊 Overall compression: $total_ratio"
        local space_saved=$((ORIGINAL_SIZE - REPACKED_SIZE))
        echo "💾 Space saved: $(format_size "$space_saved")"
    fi #1
    
    printf "⏱️ Total time: "
    if (( hours > 0 )); then
        printf "%dh " "$hours"
    fi #1
    if (( minutes > 0 )); then
        printf "%dm " "$minutes"
    fi #1
    printf "%ds\n" "$seconds"
    
    if (( ${#FAILED_FILES[@]} )); then
        echo
        echo "⚠️ Failed files:"
        printf "  • %s\n" "${FAILED_FILES[@]}"
    fi #1
    
    if (( ${#SKIPPED_FILES[@]} )) && [[ ! "$QUIET" == true ]]; then
        echo
        echo "⏩ Skipped files:"
        printf "  • %s\n" "${SKIPPED_FILES[@]}"
    fi #1

    echo
    echo "📝 Complete log saved to: $LOGFILE"

    # Exit with error code if any files failed
    if (( ${#FAILED_FILES[@]} )); then
        exit 1
    fi #1
} #closed main

fatal_error() {
    echo "❌ Error: $1"
    [[ -n "$2" ]] && echo "💡 $2"
    exit 1
} #1

# Call main function with all arguments
main "$@"
