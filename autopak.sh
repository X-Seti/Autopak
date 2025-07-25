#!/bin/bash

# X-Seti - March23 2024 - AutoPak - Archive Repackaging Tool - Version: 1.0

# Default settings
RECURSIVE=false
DEL_ORG=false
ARC_R="7z"
TARG_DIR=""
DRY_RUN=false
QUIET=false
PAR_JOBS=1
COPN_LVL=""
BUP_ORG=false
VFY_ARCS=false
RESUME=false
CONF_F="$HOME/.autopak.conf"
INCL_PAT=""
EXCL_PAT=""
MIN_SIZE=0
MAX_SIZE=0
CPU_LIMIT=0  # 0 = no limit, 10 = 10%, 90 = 90%
NICE_LVL=0  # Process priority adjustment
SCN_ONLY=false  # Only scan and report what would be done
EXT_MULP=false  # Extract multi-part archives to separate folders
REP_CRPT=false   # Attempt to repair corrupted RAR files before processing
KP_BRKF=false  # Keep broken/partial files during extraction
IGN_CORR=false  # Continue processing even if archives are corrupted
SINGLE_FILE=false

# Statistics and progress
TOT_F=0
PROC_F=0
FAIL_F=()
SKP_FILS=()
F_JOBS=()  # failure tracking
S_TIME=$(date +%s)
O_SIZE=0
REP_SIZE=0
SC_RLTS=()  # Array to store scan results
C_PHSE=""  # Track current operation phase

# Logging
LOGFILE="/tmp/autopack_$(date +%Y%m%d_%H%M%S).log"
RSME_FIL="/tmp/autopak_resume_$(basename "$0")_$$.state"
S_CACHE="/tmp/autopak_scan_$(basename "$0")_$$.cache"
CPU_P=""  # PID of cpulimit process if running
WORK_DIR="$HOME/.autopak_tmp_$$"

# Signal handling
cleanup_and_exit() {
    echo -e "\n🛑 Interrupted! Cleaning up..."
    if [[ -d "$WORK_DIR" ]]; then
        chmod -R 755 "$WORK_DIR" 2>/dev/null
        rm -rf "$WORK_DIR"
    fi #2
    [[ -f "$RSME_FIL" ]] && rm -f "$RSME_FIL"
    [[ -f "$S_CACHE" ]] && rm -f "$S_CACHE"

    # Kill any background CPU limiting processes
    if [[ -n "$CPU_P" ]]; then
        kill "$CPU_P" 2>/dev/null
    fi #2

    # Show partial statistics
    local end_time=$(date +%s)
    local duration=$((end_time - S_TIME))
    echo "⏱️ Partial run time: ${duration}s"
    echo "📊 Files processed: $PROC_F/$TOT_F"
    echo "📋 Current phase: $C_PHSE"

    exit 130
} #closed cleanup_and_exit

trap cleanup_and_exit INT TERM

# Load configuration
load_config() {
    if [[ -f "$CONF_F" ]]; then
        source "$CONF_F"
        [[ ! "$QUIET" == true ]] && echo "📋 Loaded config from: $CONF_F"
    fi #1
} #closed load_config

# Save configuration
save_config() {
    cat > "$CONF_F" << EOF
# AutoPak Configuration
ARC_R="$ARC_R"
COPN_LVL="$COPN_LVL"
PAR_JOBS=$PAR_JOBS
VFY_ARCS=$VFY_ARCS
BUP_ORG=$BUP_ORG
CPU_LIMIT=$CPU_LIMIT
NICE_LVL=$NICE_LVL
EXT_MULP=$EXT_MULP
REP_CRPT=$REP_CRPT
KP_BRKF=$KP_BRKF
EOF
    echo "💾 Configuration saved to: $CONF_F"
} #closed save_config

# CPU management functions
setup_cpu_limiting() {
    if (( CPU_LIMIT > 0 )); then
        if command -v cpulimit &> /dev/null; then
            [[ ! "$QUIET" == true ]] && echo "🔧 Setting CPU limit to ${CPU_LIMIT}%"
            cpulimit -l "$CPU_LIMIT" -p $$ &
            CPU_P=$!
        else
            echo "⚠️ cpulimit not found, CPU limiting disabled"
            echo "Install with: sudo apt-get install cpulimit"
        fi #1
    fi #2
    
    if (( NICE_LVL != 0 )); then
        [[ ! "$QUIET" == true ]] && echo "🔧 Setting process priority (nice level: $NICE_LVL)"
        renice "$NICE_LVL" $$ >/dev/null 2>&1
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
        local elapsed=$(($(date +%s) - S_TIME))
        if (( elapsed > 0 )); then
            local rate=$((current * 1000 / elapsed))
            if (( rate > 0 )); then
                local remaining=$((total - current))
                local eta_seconds=$((remaining * 1000 / rate))
                local eta_min=$((eta_seconds / 60))
                local eta_sec=$((eta_seconds % 60))
                eta=" ETA: ${eta_min}m${eta_sec}s"
            fi #3
        fi #2
    fi #1

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
    if $KP_BRKF; then
        local brkext="$repair_dir/brkext"
        mkdir -p "$brkext"
        
        if command -v unrar &> /dev/null; then
            # Try unrar with keep broken files equivalent
            if unrar x -kb -y "$rar_file" "$brkext/" >/dev/null 2>&1; then
                if [[ "$(ls -A "$brkext")" ]]; then
                    [[ ! "$QUIET" == true ]] && echo "⚠️ Partial extraction successful (broken files kept)"
                    echo "$brkext"
                    return 0
                fi #4
            fi #3
        fi #2
        
        rm -rf "$brkext"
    fi #1
    
    [[ ! "$QUIET" == true ]] && echo "❌ RAR repair failed: $(basename "$rar_file")"
    return 1
} #closed repair_rar_file

# Check if RAR file appears corrupted
is_rar_corrupted() {
    local rar_file="$1"

    # For multi-part archives, test the first part instead of individual parts
    if is_multipart_rar "$rar_file"; then
        local first_part=$(get_multipart_first_part "$rar_file")
        rar_file="$first_part"
    fi #1

    # unrar
    if command -v unrar &> /dev/null; then
        if ! unrar t "$rar_file" >/dev/null 2>&1; then
            return 0  # Corrupted
        fi #2
    fi #1

    # 7z
    if command -v 7z &> /dev/null; then
        if ! 7z t "$rar_file" >/dev/null 2>&1; then
           return 0  # Corrupted
        fi #2
    fi #1

    return 1  # Not corrupted
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
        [[ ! -f "$first_part" ]] && first_part="$dir/${base_name}.part0001.rar"
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
        [[ ! -f "$first_part" ]] && first_part="$dir/${base_name}.part0001"
        [[ ! -f "$first_part" ]] && first_part="$dir/${base_name}.part1"
    else
        first_part="$file"
    fi #1

    echo "$first_part"
} #closed get_multipart_first_part

# File scanning with detailed info gathering
scan_files() {
    C_PHSE="Scanning files"
    [[ ! "$QUIET" == true ]] && echo "🔍 Phase 1: Scanning and analyzing files..."
    
    # Check if we have a cached scan
    if [[ -f "$S_CACHE" ]] && $RESUME; then
        [[ ! "$QUIET" == true ]] && echo "📋 Loading cached scan results..."
        source "$S_CACHE"
        return
    fi #1
    
    local counter=0
    local scan_S_TIME=$(date +%s)
    
    # Build find options for recursion
    local FIND_OPTS=()
    $RECURSIVE || FIND_OPTS+=(-maxdepth 1)
    
    # Get all potential files first
    local temp_files=()
    readarray -t temp_files < <(find "$TARG_DIR" "${FIND_OPTS[@]}" -type f \( \
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
    SC_RLTS=()
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
        if [[ "$should_process" == true && -n "$INCL_PAT" ]] && [[ ! "$basename" =~ $INCL_PAT ]]; then
            should_process=false
            skip_reason="doesn't match include pattern"
        fi #1
        
        if [[ "$should_process" == true && -n "$EXCL_PAT" ]] && [[ "$basename" =~ $EXCL_PAT ]]; then
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
            SC_RLTS+=("$file|$size|process")
            TOT_F=$((TOT_F + 1))
            O_SIZE=$((O_SIZE + size))
        else
            SC_RLTS+=("$file|$size|skip|$skip_reason")
            SKP_FILS+=("$file")
        fi #1
    done ##1
    
    # Cache scan results
    {
        echo "SC_RLTS=("
        printf "'%s'\n" "${SC_RLTS[@]}"
        echo ")"
        echo "TOT_F=$TOT_F"
        echo "O_SIZE=$O_SIZE"
        echo "SKP_FILS=("
        printf "'%s'\n" "${SKP_FILS[@]}"
        echo ")"
    } > "$S_CACHE"
    
    local scan_duration=$(($(date +%s) - scan_S_TIME))
    [[ ! "$QUIET" == true ]] && echo -e "\n✅ Scan completed in ${scan_duration}s"
    [[ ! "$QUIET" == true ]] && echo "📊 Files to process: $TOT_F"
    [[ ! "$QUIET" == true ]] && echo "📊 Files to skip: ${#SKP_FILS[@]}"
    [[ ! "$QUIET" == true ]] && echo "📊 Total size to process: $(format_size "$O_SIZE")"
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
    case "$ARC_R" in
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
    
    local available_space=$(df -BM "$target_dir" | awk 'NR==2 {gsub(/M/, "", $4); print $4+0}')
    
    if (( available_space < required_space_mb )); then
        echo "❌ Insufficient disk space. Required: ${required_space_mb}MB, Available: ${available_space}MB"
        exit 1
    fi #1
} #closed check_disk_space

# Estimate required space
estimate_space_needed() {
    local total_size=0
    local current_size=0

    # Build find options for recursion
    local FIND_OPTS=()
    $RECURSIVE || FIND_OPTS+=(-maxdepth 1)
    
    while IFS= read -r -d '' file; do
        #[[ -f "$file" ]] && total_size=$((total_size + $(stat -c%s "$file")))

        if [[ -f "$file" ]]; then
            current_size=$(stat -c%s "$file")
            if (( current_size > max_size )); then
                max_size=$current_size
            fi #2
        fi #1
    done < <(find "$TARG_DIR" "${FIND_OPTS[@]}" -type f \( \
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
    echo $((max_size * PAR_JOBS * 15 / 10 / 1024 / 1024))
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
    echo "$processed_file" >> "$RSME_FIL"
} #closed save_resume_state

is_already_processed() {
    local file="$1"
    [[ -f "$RSME_FIL" ]] && grep -Fxq "$file" "$RSME_FIL"
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
    -r, --recursive          Process directories recursively
    -d, --delete-original    Delete original files after repacking
    -b, --backup-original    Create backup of original files before processing
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
    -S, --single-file        Process a single file instead of directory
    --cpu-limit PERCENT      Limit CPU usage to percentage (10, 50, 90, etc.)
    --nice-level N           Set process priority (-20 to 19, negative = higher priority)
    --scan-only              Only scan files and show what would be processed
    --extract-multipart      Extract multi-part archives to separate folders
    --repair-corrupted       Attempt to repair corrupted RAR files before processing
    --keep-broken-files      Keep broken/partial files during extraction
    --ignore-corruption      Continue processing even if archives are corrupted
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
    - Formats: archive.part01.rar, archive.r000/r001, archive.part1
    - Only processes the first part, extracts complete archive
    - Use --extract-multipart to extract to individual folders

EXAMPLES:
    $0 /path/to/archives                        # Basic usage
    $0 -r -d -j 4 /path/to/archives             # Recursive, delete, 4 parallel jobs
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
            -d|--delete-original) DEL_ORG=true ;;
            -b|--backup-original) BUP_ORG=true ;;
            -n|--dry-run) DRY_RUN=true ;;
            -q|--quiet) QUIET=true ;;
            -v|--verify) VFY_ARCS=true ;;
            -R|--resume) RESUME=true ;;
            -s|--save-config) save_config; exit 0 ;;
            -S|--single-file) SINGLE_FILE=true ;;
            --scan-only) SCN_ONLY=true ;;
            --extract-multipart) EXT_MULP=true ;;
            --repair-corrupted) REP_CRPT=true ;;
            --keep-broken-files) KP_BRKF=true ;;
            --ignore-corruption) IGN_CORR=true ;;
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
                NICE_LVL="$1"
                if ! [[ "$NICE_LVL" =~ ^-?[0-9]+$ ]] || (( NICE_LVL < -20 || NICE_LVL > 19 )); then
                    echo "❌ Invalid nice level: $NICE_LVL (must be -20 to 19)"
                    exit 1
                fi #1
                ;;
            -j|--jobs)
                shift
                PAR_JOBS="$1"
                if ! [[ "$PAR_JOBS" =~ ^[0-9]+$ ]] || (( PAR_JOBS < 1 )); then
                    echo "❌ Invalid job count: $PAR_JOBS"
                    exit 1
                fi #1
                ;;
            -a|--arch)
                shift
                ARC_R="$1"
                ;;
            -c|--compression)
                shift
                COPN_LVL="$1"
                ;;
            -c*)
                # Handle -c9, -c6, etc. (no space)
                COPN_LVL="${1#-c}"
                ;;
            -i|--include)
                shift
                INCL_PAT="$1"
                ;;
            -e|--exclude)
                shift
                EXCL_PAT="$1"
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
                CONF_F="$1"
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
                TARG_DIR="$1"
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
    fi

    local BASENAME=$(basename "$FILE")
    local EXT="${BASENAME##*.}"
    local STRIPPED_NAME="${BASENAME%.*}"
    local TMP_DIR="$WORK_DIR/${STRIPPED_NAME}_$$_$current_num"
    local O_SIZE=$(get_file_size "$FILE")

    # Check if already processed (resume functionality)
    if $RESUME && is_already_processed "$FILE"; then
        [[ ! "$QUIET" == true ]] && echo "⏩ Already processed: $(basename "$FILE")"
        return 0
    fi #1
    
    local BASENAME=$(basename "$FILE")
    local EXT="${BASENAME##*.}"
    local STRIPPED_NAME="${BASENAME%.*}"
    local TMP_DIR="$WORK_DIR/${STRIPPED_NAME}_$$_$current_num"
    local O_SIZE=$(get_file_size "$FILE")
    
    # Size filtering
    if (( MIN_SIZE > 0 && O_SIZE < MIN_SIZE )); then
        [[ ! "$QUIET" == true ]] && echo "⏩ Skipping (too small): $BASENAME"
        SKP_FILS+=("$FILE")
        return 0
    fi #1
    
    if (( MAX_SIZE > 0 && O_SIZE > MAX_SIZE )); then
        [[ ! "$QUIET" == true ]] && echo "⏩ Skipping (too large): $BASENAME"
        SKP_FILS+=("$FILE")
        return 0
    fi #1
    
    # Pattern filtering
    if [[ -n "$INCL_PAT" ]] && [[ ! "$BASENAME" =~ $INCL_PAT ]]; then
        [[ ! "$QUIET" == true ]] && echo "⏩ Skipping (not matching include pattern): $BASENAME"
        SKP_FILS+=("$FILE")
        return 0
    fi #1
    
    if [[ -n "$EXCL_PAT" ]] && [[ "$BASENAME" =~ $EXCL_PAT ]]; then
        [[ ! "$QUIET" == true ]] && echo "⏩ Skipping (matching exclude pattern): $BASENAME"
        SKP_FILS+=("$FILE")
        return 0
    fi #1
    
    # Skip already repacked files
    if [[ "$FILE" =~ _repacked(\.new[0-9]*)?\.([7z|zip|tar\.(gz|xz|zst)|tar])$ ]]; then
        [[ ! "$QUIET" == true ]] && echo "⏩ Skipping already repacked: $BASENAME"
        SKP_FILS+=("$FILE")
        return 0
    fi #1
    
    mkdir -p "$TMP_DIR"
    
    [[ ! "$QUIET" == true ]] && show_progress "$current_num" "$total_num" "$BASENAME"
    [[ ! "$QUIET" == true ]] && echo -e "\n➡️ Processing: $BASENAME ($(format_size "$O_SIZE"))"

    # Create backup if requested
    if $BUP_ORG && [[ ! "$DRY_RUN" == true ]]; then
        local backup_file="${FILE}.backup"
        cp "$FILE" "$backup_file"
        [[ ! "$QUIET" == true ]] && echo "💾 Created backup: $backup_file"
    fi #1

    # Special handling for multi-part archives and repair
    local EXTR_SS=true
    local is_multipart=false
    local m_foldr=""
    local repair_attempted=false
    local using_repaired=false
    local current_file="$FILE"
    
    # Check if repair is needed and attempt it
    if $REP_CRPT && [[ "$EXT" =~ ^(rar|r[0-9]+)$ || "$BASENAME" =~ \.(part[0-9]+\.rar|part[0-9]+)$ ]]; then
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
                    EXTR_SS=true
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
        EXTR_SS=true
    else
        # Check if this is a multi-part RAR and handle accordingly
        if is_multipart_rar "$current_file"; then
            is_multipart=true
            local first_part=$(get_multipart_first_part "$current_file")
            
            if $EXT_MULP; then
                # Create a dedicated folder for multi-part extraction
                local archive_name="${BASENAME%.*}"
                # Remove part numbers from folder name
                archive_name=$(echo "$archive_name" | sed -E 's/\.(part[0-9]+|r[0-9]+|part[0-9]+)$//')
                m_foldr="$TMP_DIR/${archive_name}_extracted"
                mkdir -p "$m_foldr"
                [[ ! "$QUIET" == true ]] && echo "📁 Extracting multi-part RAR to: $(basename "$m_foldr")"
                
                # Extract using the first part
                if $KP_BRKF; then
                    unrar x -kb -inul "$first_part" "$m_foldr/" 2>/dev/null || \
                    7z x -bd -y -o"$m_foldr" "$first_part" >/dev/null 2>&1 || \
                    EXTR_SS=false
                else
                    unrar x -inul "$first_part" "$m_foldr/" 2>/dev/null || \
                    7z x -bd -y -o"$m_foldr" "$first_part" >/dev/null 2>&1 || \
                    EXTR_SS=false
                fi #4 -1
                
                # Set extraction directory to the multipart folder
                TMP_DIR="$m_foldr"
            else
                # Standard extraction to temporary directory
                [[ ! "$QUIET" == true ]] && echo "📦 Processing multi-part RAR: $BASENAME"
                if $KP_BRKF; then
                    unrar x -kb -inul "$first_part" "$TMP_DIR/" 2>/dev/null || \
                    7z x -bd -y -o"$TMP_DIR" "$first_part" >/dev/null 2>&1 || \
                    EXTR_SS=false
                else
                    unrar x -inul "$first_part" "$TMP_DIR/" 2>/dev/null || \
                    7z x -bd -y -o"$TMP_DIR" "$first_part" >/dev/null 2>&1 || \
                    EXTR_SS=false
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
                    EXTR_SS=false
                    ;;
                rar) 
                    if $KP_BRKF; then
                        unrar x -kb -inul "$current_file" "$TMP_DIR/" 2>/dev/null || \
                        7z x -bd -y -o"$TMP_DIR" "$current_file" >/dev/null 2>&1 || \
                        EXTR_SS=false
                    else
                        unrar x -inul "$current_file" "$TMP_DIR/" 2>/dev/null || \
                        7z x -bd -y -o"$TMP_DIR" "$current_file" >/dev/null 2>&1 || \
                        EXTR_SS=false
                    fi #4 -3
                    ;;
            7z|exe) 
                7z x -bd -y -o"$TMP_DIR" "$FILE" >/dev/null 2>&1 || EXTR_SS=false
                ;;
            tar) 
                tar -xf "$FILE" -C "$TMP_DIR" 2>/dev/null || EXTR_SS=false
                ;;
            tgz|gz) 
                if [[ "$BASENAME" == *.tar.gz ]] || [[ "$BASENAME" == *.tgz ]]; then
                    tar -xzf "$FILE" -C "$TMP_DIR" 2>/dev/null || EXTR_SS=false
                else
                    gunzip -c "$FILE" > "$TMP_DIR/${STRIPPED_NAME}" 2>/dev/null || EXTR_SS=false
                fi #3 -2
                ;;
            xz) 
                if [[ "$BASENAME" == *.tar.xz ]]; then
                    tar -xJf "$FILE" -C "$TMP_DIR" 2>/dev/null || EXTR_SS=false
                else
                    unxz -c "$FILE" > "$TMP_DIR/${STRIPPED_NAME}" 2>/dev/null || EXTR_SS=false
                fi #3 -3
                ;;
            bz2) 
                if [[ "$BASENAME" == *.tar.bz2 ]]; then
                    tar -xjf "$FILE" -C "$TMP_DIR" 2>/dev/null || EXTR_SS=false
                else
                    bunzip2 -c "$FILE" > "$TMP_DIR/${STRIPPED_NAME}" 2>/dev/null || EXTR_SS=false
                fi #3 -4
                ;;
            zst) 
                if [[ "$BASENAME" == *.tar.zst ]]; then
                    tar --use-compress-program=unzstd -xf "$FILE" -C "$TMP_DIR" 2>/dev/null || EXTR_SS=false
                else
                    zstd -d -c "$FILE" > "$TMP_DIR/${STRIPPED_NAME}" 2>/dev/null || EXTR_SS=false
                fi #3 -5
                ;;
            lzh|lha) 
                lha xqf "$FILE" "$TMP_DIR" 2>/dev/null || \
                lhasa x "$FILE" -C "$TMP_DIR" 2>/dev/null || \
                7z x -bd -y -o"$TMP_DIR" "$FILE" >/dev/null 2>&1 || \
                EXTR_SS=false
                ;;
            cab) 
                cabextract -d "$TMP_DIR" "$FILE" >/dev/null 2>&1 || \
                7z x -bd -y -o"$TMP_DIR" "$FILE" >/dev/null 2>&1 || \
                EXTR_SS=false
                ;;
            iso|img|dd)
                7z x -bd -y -o"$TMP_DIR" "$FILE" >/dev/null 2>&1 || EXTR_SS=false
                ;;
            deb)
                dpkg-deb -x "$FILE" "$TMP_DIR" 2>/dev/null || \
                (ar x "$FILE" 2>/dev/null && \
                tar -xf data.tar.* -C "$TMP_DIR" 2>/dev/null) || \
                EXTR_SS=false
                ;;
            pkg|pac|pp)
                7z x -bd -y -o"$TMP_DIR" "$FILE" >/dev/null 2>&1 || EXTR_SS=false
                ;;
            ace)
                # ACE archive support - try multiple methods
                if command -v unace &> /dev/null; then
                    unace x "$FILE" "$TMP_DIR/" 2>/dev/null || EXTR_SS=false
                elif command -v 7z &> /dev/null; then
                    7z x -bd -y -o"$TMP_DIR" "$FILE" >/dev/null 2>&1 || EXTR_SS=false
                else
                    [[ ! "$QUIET" == true ]] && echo "⚠️ ACE support requires 'unace' or 7z with ACE plugin"
                    EXTR_SS=false
                fi #3 -6
                ;;
            arj)
                # ARJ archive support
                if command -v arj &> /dev/null; then
                    arj x "$FILE" "$TMP_DIR/" 2>/dev/null || EXTR_SS=false
                elif command -v unarj &> /dev/null; then
                    unarj x "$FILE" "$TMP_DIR/" 2>/dev/null || EXTR_SS=false
                elif command -v 7z &> /dev/null; then
                    7z x -bd -y -o"$TMP_DIR" "$FILE" >/dev/null 2>&1 || EXTR_SS=false
                else
                    [[ ! "$QUIET" == true ]] && echo "⚠️ ARJ support requires 'arj', 'unarj', or 7z with ARJ plugin"
                    EXTR_SS=false
                fi #3 -7
                ;;
            z|Z)
                # Unix compress (.Z) and pack (.z) format support
                if command -v uncompress &> /dev/null; then
                    uncompress -c "$FILE" > "$TMP_DIR/${STRIPPED_NAME}" 2>/dev/null || EXTR_SS=false
                elif command -v gzip &> /dev/null; then
                    # gzip can sometimes handle .Z files
                    gzip -dc "$FILE" > "$TMP_DIR/${STRIPPED_NAME}" 2>/dev/null || EXTR_SS=false
                elif command -v 7z &> /dev/null; then
                    7z x -bd -y -o"$TMP_DIR" "$FILE" >/dev/null 2>&1 || EXTR_SS=false
                else
                    [[ ! "$QUIET" == true ]] && echo "⚠️ Compress format support requires 'uncompress', 'gzip', or 7z"
                    EXTR_SS=false
                fi #3 -8
                ;;
            r[0-9]*|part[0-9]*)
                # Handle remaining multi-part files that weren't caught earlier
                local first_part=$(get_multipart_first_part "$FILE")
                unrar x -inul "$first_part" "$TMP_DIR/" 2>/dev/null || \
                7z x -bd -y -o"$TMP_DIR" "$first_part" >/dev/null 2>&1 || \
                EXTR_SS=false
                ;;
            *)
                [[ ! "$QUIET" == true ]] && echo "❓ Unsupported extension: $EXT"
                EXTR_SS=false
                ;;
        esac # in "$EXT"
        fi #2
    fi #1 - was missing

    if [[ "$EXTR_SS" != true ]]; then
        if $IGN_CORR; then
            [[ ! "$QUIET" == true ]] && echo "⚠️ Extraction failed but continuing due to --ignore-corruption: $BASENAME"
            FAIL_F+=("$FILE")
            rm -rf "$TMP_DIR"
            [[ -n "$m_foldr" && -d "$m_foldr" ]] && rm -rf "$m_foldr"
            return 0  # Return success to continue processing
        else
            [[ ! "$QUIET" == true ]] && echo "❌ Failed to extract: $BASENAME"
            FAIL_F+=("$FILE")
            rm -rf "$TMP_DIR"
            [[ -n "$m_foldr" && -d "$m_foldr" ]] && rm -rf "$m_foldr"
            return 1  # Return failure to stop processing
        fi #2
    fi #1

    # Check if extraction resulted in any files
    if [[ ! "$(ls -A "$TMP_DIR")" ]]; then
        [[ ! "$QUIET" == true ]] && echo "❌ Empty archive: $BASENAME"
        FAIL_F+=("$FILE")
        rm -rf "$TMP_DIR"
        [[ -n "$m_foldr" && -d "$m_foldr" ]] && rm -rf "$m_foldr"
        return 1
    fi #1

    # For multi-part extraction mode, we're done - just leave the extracted folder
    if $EXT_MULP && [[ "$is_multipart" == true ]]; then
        [[ ! "$QUIET" == true ]] && echo "✅ Multi-part archive extracted to: $(basename "$TMP_DIR")"
        save_resume_state "$FILE"
        PROC_F=$((PROC_F + 1))
        return 0
    fi #1

    # Determine output filename
    local NEW_ARCHIVE
    case "$ARC_R" in
        7z) NEW_ARCHIVE=$(generate_output_filename "${FILE%.*}" "7z") ;;
        zip) NEW_ARCHIVE=$(generate_output_filename "${FILE%.*}" "zip") ;;
        zstd) NEW_ARCHIVE=$(generate_output_filename "${FILE%.*}" "tar.zst") ;;
        xz) NEW_ARCHIVE=$(generate_output_filename "${FILE%.*}" "tar.xz") ;;
        gz) NEW_ARCHIVE=$(generate_output_filename "${FILE%.*}" "tar.gz") ;;
        tar) NEW_ARCHIVE=$(generate_output_filename "${FILE%.*}" "tar") ;;
    esac # in "$ARC_R"

    if $DRY_RUN; then
        [[ ! "$QUIET" == true ]] && echo "💡 Would repack: $BASENAME → $(basename "$NEW_ARCHIVE")"
        if $DEL_ORG; then
            [[ ! "$QUIET" == true ]] && echo "💡 Would delete original: $BASENAME"
        fi #2 -1
    else
        [[ ! "$QUIET" == true ]] && echo "📦 Repacking to: $(basename "$NEW_ARCHIVE")"
        local REPACK_SUCCESS=true
        
        # Set compression level
        local comp_opts=""
        if [[ -n "$COPN_LVL" ]]; then
            case "$ARC_R" in
                7z) comp_opts="-mx=$COPN_LVL" ;;
                zip) comp_opts="-$COPN_LVL" ;;
                zstd) comp_opts="-$COPN_LVL" ;;
                xz) comp_opts="-$COPN_LVL" ;;
                gz) comp_opts="-$COPN_LVL" ;;
            esac
        fi #2 -2
        
        case "$ARC_R" in
            7z)
                (cd "$TMP_DIR" && 7z a -t7z ${comp_opts:-"-mx=9"} -m0=lzma2 "$NEW_ARCHIVE" * >/dev/null 2>&1) || REPACK_SUCCESS=false
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
        esac # in "$ARC_R"

        if [[ "$REPACK_SUCCESS" != true ]]; then
            [[ ! "$QUIET" == true ]] && echo "❌ Failed to repack: $BASENAME"
            FAIL_F+=("$FILE")
            rm -rf "$TMP_DIR"
            [[ -n "$m_foldr" && -d "$m_foldr" ]] && rm -rf "$m_foldr"
            return 1
        fi #2 -3

        # Verify repacked archive if requested
        if $VFY_ARCS; then
            if ! verify_archive "$NEW_ARCHIVE" "$ARC_R"; then
                [[ ! "$QUIET" == true ]] && echo "❌ Archive verification failed: $(basename "$NEW_ARCHIVE")"
                FAIL_F+=("$FILE")
                rm -f "$NEW_ARCHIVE"
                rm -rf "$TMP_DIR"
                [[ -n "$m_foldr" && -d "$m_foldr" ]] && rm -rf "$m_foldr"
                return 1
            fi
            [[ ! "$QUIET" == true ]] && echo "✅ Archive verified: $(basename "$NEW_ARCHIVE")"
        fi #2 -4

        # Calculate and display compression statistics
        local new_size=$(get_file_size "$NEW_ARCHIVE")
        local compression_ratio=$(calc_compression_ratio "$O_SIZE" "$new_size")
        
        REP_SIZE=$((REP_SIZE + new_size))
        
        [[ ! "$QUIET" == true ]] && echo "📊 Size: $(format_size "$O_SIZE") → $(format_size "$new_size") (${compression_ratio} compression)"

        # Handle original file
        if $DEL_ORG; then
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
    [[ -n "$m_foldr" && -d "$m_foldr" ]] && rm -rf "$m_foldr"
    
    # Save resume state
    save_resume_state "$FILE"
    
    PROC_F=$((PROC_F + 1))
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
export IGN_CORR

# Main execution
main() {
    # Save original argument count before parsing
    local original_arg_count=$#

    load_config
    parse_arguments "$@"
    init_logging

    if $SINGLE_FILE; then
        if [[ ! -f "$TARG_DIR" ]]; then
            echo "❌ Error: File '$TARG_DIR' doesn't exist or is not accessible"
            exit 1
        fi
        echo "🎯 Single file mode: $(basename "$TARG_DIR")"
        INCL_PAT="^$(basename "$TARG_DIR")$"
        TARG_DIR=$(dirname "$TARG_DIR")
    fi

    # Validate inputs - handle different error scenarios
    if [[ $original_arg_count -eq 0 ]]; then
        show_help
        exit 1
    fi

    if [[ -z "$TARG_DIR" ]]; then
        echo "❌ Error: No directory specified"
        echo "💡 Usage: $(basename "$0") [OPTIONS] <directory>"
        exit 1
    fi

    if [[ ! -d "$TARG_DIR" ]]; then
        echo "❌ Error: Directory '$TARG_DIR' doesn't exist or is not accessible"
        echo "💡 Please check the path and try again"
        exit 1
    fi

    # Validate archiver
    case "$ARC_R" in
        7z|zip|zstd|xz|gz|tar) ;;
        *) echo "❌ Invalid archiver: $ARC_R"; exit 2 ;;
    esac # in "$ARC_R"

    check_dependencies
    setup_cpu_limiting

    mkdir -p "$WORK_DIR"
    scan_files
    
    # Early exit for scan-only mode
    if $SCN_ONLY; then
        echo
        echo "📋 Scan Results Summary:"
        echo "========================"
        echo "📁 Total files found: $((TOT_F + ${#SKP_FILS[@]}))"
        echo "✅ Files to process: $TOT_F"
        echo "⏩ Files to skip: ${#SKP_FILS[@]}"
        echo "📊 Total size to process: $(format_size "$O_SIZE")"
        
        if (( ${#SKP_FILS[@]} > 0 )) && [[ ! "$QUIET" == true ]]; then
            echo
            echo "⏩ Skipped files:"
            for result in "${SC_RLTS[@]}"; do
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

    if (( TOT_F == 0 )); then
        echo "❌ No archive files to process after filtering"
        exit 1
    fi #1

    # Check disk space
    if [[ ! "$DRY_RUN" == true ]]; then
        local estimated_space=$(estimate_space_needed)
        check_disk_space "$TARG_DIR" "$estimated_space"
    fi #1

    # Display configuration
    if [[ ! "$QUIET" == true ]]; then
        echo
        echo "📋 Processing Configuration:"
        echo "============================="
        echo "🔍 Target directory: $TARG_DIR"
        echo "📦 Archiver: $ARC_R"
        echo "🔄 Recursive: $RECURSIVE"
        echo "🗑️ Delete original: $DEL_ORG"
        echo "💾 Backup original: $BUP_ORG"
        echo "✅ Verify archives: $VFY_ARCS"
        echo "📁 Extract multi-part: $EXT_MULP"
        echo "🔧 Repair corrupted: $REP_CRPT"
        echo "🛠️ Keep broken files: $KP_BRKF"
        echo "🚫 Ignore corruption: $IGN_CORR"
        echo "💡 Dry run: $DRY_RUN"
        echo "🔇 Quiet mode: $QUIET"
        echo "⚡ Parallel jobs: $PAR_JOBS"
        [[ $CPU_LIMIT -gt 0 ]] && echo "🔧 CPU limit: ${CPU_LIMIT}%"
        [[ $NICE_LVL -ne 0 ]] && echo "🔧 Nice level: $NICE_LVL"
        [[ -n "$COPN_LVL" ]] && echo "📊 Compression level: $COPN_LVL"
        [[ -n "$INCL_PAT" ]] && echo "🎯 Include pattern: $INCL_PAT"
        [[ -n "$EXCL_PAT" ]] && echo "🚫 Exclude pattern: $EXCL_PAT"
        [[ $MIN_SIZE -gt 0 ]] && echo "📏 Min size: $(format_size "$MIN_SIZE")"
        [[ $MAX_SIZE -gt 0 ]] && echo "📏 Max size: $(format_size "$MAX_SIZE")"
        echo "📝 Log file: $LOGFILE"
        echo "📁 Files to process: $TOT_F"
        echo "📊 Total size: $(format_size "$O_SIZE")"
        echo
    fi #1

    # Phase 2: Process files
    C_PHSE="Processing files"
    [[ ! "$QUIET" == true ]] && echo "🔄 Phase 2: Processing archive files..."
    
    # Create processing queue from scan results
    local processing_queue=()
    for result in "${SC_RLTS[@]}"; do
        IFS='|' read -r file size action reason <<< "$result"
        if [[ "$action" == "process" ]]; then
            processing_queue+=("$file")
        fi #1
    done

    # Process files
    if (( PAR_JOBS > 1 )); then
        # Parallel processing using xargs with proper environment
        printf '%s\n' "${processing_queue[@]}" | \
        WORK_DIR="$WORK_DIR" \
        ARC_R="$ARC_R" \
        COPN_LVL="$COPN_LVL" \
        DEL_ORG="$DEL_ORG" \
        BUP_ORG="$BUP_ORG" \
        VFY_ARCS="$VFY_ARCS" \
        EXT_MULP="$EXT_MULP" \
        REP_CRPT="$REP_CRPT" \
        KP_BRKF="$KP_BRKF" \
        DRY_RUN="$DRY_RUN" \
        QUIET="$QUIET" \
        RESUME="$RESUME" \
        RSME_FIL="$RSME_FIL" \
        MIN_SIZE="$MIN_SIZE" \
        MAX_SIZE="$MAX_SIZE" \
        INCL_PAT="$INCL_PAT" \
        EXCL_PAT="$EXCL_PAT" \
        SKP_FILS="$SKP_FILS" \
        FAIL_F="$FAIL_F" \
        IGN_CORR="$IGN_CORR" \
        PROC_F="$PROC_F" \
        REP_SIZE="$REP_SIZE" \
        xargs -P "$PAR_JOBS" -I {} bash -c 'process_archive "{}" 1 '"$TOT_F"
    else
        # Sequential processing
        local counter=0
        for file in "${processing_queue[@]}"; do
            ((counter++))
            process_archive "$file" "$counter" "$TOT_F"
        done ##1
    fi #1

    # Cleanup
    rm -rf "$WORK_DIR"
    [[ -f "$RSME_FIL" ]] && rm -f "$RSME_FIL"
    [[ -f "$S_CACHE" ]] && rm -f "$S_CACHE"

    # Stop CPU limiting if active
    if [[ -n "$CPU_P" ]]; then
        kill "$CPU_P" 2>/dev/null
    fi #1

    # Final statistics
    local end_time=$(date +%s)
    local duration=$((end_time - S_TIME))
    local hours=$((duration / 3600))
    local minutes=$(((duration % 3600) / 60))
    local seconds=$((duration % 60))
    
    echo
    echo "📋 Final Summary:"
    echo "===================="
    echo "📁 Total files found: $((TOT_F + ${#SKP_FILS[@]}))"
    echo "✅ Successfully processed: $PROC_F"
    echo "❌ Failed: ${#FAIL_F[@]}"
    echo "⏩ Skipped: ${#SKP_FILS[@]}"
    
    if (( PROC_F > 0 )) && [[ ! "$DRY_RUN" == true ]]; then
        echo "📊 Original total size: $(format_size "$O_SIZE")"
        echo "📊 Repacked total size: $(format_size "$REP_SIZE")"
        local total_ratio=$(calc_compression_ratio "$O_SIZE" "$REP_SIZE")
        echo "📊 Overall compression: $total_ratio"
        local space_saved=$((O_SIZE - REP_SIZE))
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
    
    if (( ${#FAIL_F[@]} )); then
        echo
        echo "⚠️ Failed files:"
        printf "  • %s\n" "${FAIL_F[@]}"
    fi #1
    
    if (( ${#SKP_FILS[@]} )) && [[ ! "$QUIET" == true ]]; then
        echo
        echo "⏩ Skipped files:"
        printf "  • %s\n" "${SKP_FILS[@]}"
    fi #1

    echo
    echo "📝 Complete log saved to: $LOGFILE"

    # Exit with error code if any files failed
    if (( ${#FAIL_F[@]} )); then
        exit 1
    fi #1

} #closed main

fatal_error() { #left outside
    echo "❌ Error: $1"
    [[ -n "$2" ]] && echo "💡 $2"
    exit 1
} #1

# Call main function with all arguments
main "$@"
