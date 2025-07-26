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
FDRTO_ARCS=false # Process folders instead of archives
UPKTO_FDR=false
CPU_LIMIT=0  # 0 = no limit, 10 = 10%, 90 = 90%
NICE_LVL=0  # Process priority adjustment
SCN_ONLY=false  # Only scan and report what would be done
EXT_MULP=false  # Extract multi-part archives to separate folders
REP_CRPT=false   # Attempt to repair corrupted RAR files before processing
KP_BRKF=false  # Keep broken/partial files during extraction
IGN_CORR=false  # Continue processing even if archives are corrupted
SINGLE_FILE=false
GEN_CHECKSUMS=true  # Generate checksums for completed archives by default
USE_BTRFS_FLAGS=false  # Use BTRFS extended attributes to mark processed files
IGNORE_PROCESSED=false  # Skip files marked as processed
CLEAR_FLAGS=false  # Clear all autopak processing flags
TIMEOUT_SECS=300  # Timeout for stuck operations (5 minutes)
CHECK_DUPLICATES=false  # Check for duplicate files/archives
CHECKSUM_DB="/tmp/autopak_checksums.db"  # Checksum database
CLEANUP_REPACKED=false

# Passwords and Encryption
PASSWORD_FILE=""  # Password file for encrypted archives
PASSWORD_VAULT=""  # Encrypted password vault file
MASTER_PASSWORD=""  # Master password for vault
ENCRYPT_ARCHIVES=false  # Encrypt created archives
SECURE_DELETE=false  # Securely overwrite deleted files
SKIP_PASSWORDED=false  # Skip password-protected archives automatically
FLAG_PASSWORDED=false  # Flag passworded files for review
PASSWORDED_LOG="/tmp/autopak_passworded_$(date +%Y%m%d_%H%M%S).log"  # Log of skipped passworded files

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

    local percent=0
    if (( total > 0 )); then
        percent=$((current * 100 / total))
    fi #1

    local bar_length=40
    local filled_length=0
    if (( total > 0 )); then
        filled_length=$((percent * bar_length / 100))
    fi #1

    local bar=""
    for ((i=0; i<filled_length; i++)); do bar+="█"; done
    for ((i=filled_length; i<bar_length; i++)); do bar+="░"; done

    local eta=""
    if (( current > 0 && total > 0 )); then
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
    # Get all potential files/folders
    local temp_items=()

    if $FDRTO_ARCS; then
        # Find directories, excluding version control and build folders
        readarray -t temp_items < <(find "$TARG_DIR" "${FIND_OPTS[@]}" -type d \
            -not -path "$TARG_DIR" \
            -not -name ".*" \
            -not -name "node_modules" \
            -not -name "__pycache__" \
            -not -name "build" \
            -not -name "dist" \
            -not -name "target" \
            -not -path "*/.git" \
            -not -path "*/.git/*" \
            -not -path "*/.svn" \
            -not -path "*/.svn/*" \
            -not -path "*/.hg" \
            -not -path "*/.hg/*" \
            -not -path "*/.bzr" \
            -not -path "*/.bzr/*" \
            -print)
    elif $UPKTO_FDR; then
        # Find archive files for unpacking
        readarray -t temp_items < <(find "$TARG_DIR" "${FIND_OPTS[@]}" -type f \( \
            -iname '*.zip' -o -iname '*.rar' -o -iname '*.7z' -o -iname '*.exe' -o \
            -iname '*.tar' -o -iname '*.tar.gz' -o -iname '*.tgz' -o -iname '*.tar.bz2' -o \
            -iname '*.tar.xz' -o -iname '*.tar.zst' -o -iname '*.gz' -o -iname '*.xz' -o \
            -iname '*.bz2' -o -iname '*.lz' -o -iname '*.lzh' -o -iname '*.lha' -o \
            -iname '*.cab' -o -iname '*.iso' -o -iname '*.img' -o -iname '*.dd' -o \
            -iname '*.deb' -o -iname '*.pkg' -o -iname '*.pac' -o -iname '*.pp' -o \
            -iname '*.ace' -o -iname '*.arj' -o -iname '*.z' -o -iname '*.Z' -o \
            -iname '*.dmg' -o -iname '*.pkg' -o -iname '*.mpkg' -o -iname '*.sit' -o -iname '*.sitx' -o -iname '*.sea' -o \
            -iname '*.arc' -o -iname '*.r[0-9]*' -o -iname '*.part[0-9]*' \
            \) -print)
    else
        # Original archive file finding for repacking
        readarray -t temp_items < <(find "$TARG_DIR" "${FIND_OPTS[@]}" -type f \( \
            -iname '*.zip' -o -iname '*.rar' -o -iname '*.7z' -o -iname '*.exe' -o \
            -iname '*.tar' -o -iname '*.tar.gz' -o -iname '*.tgz' -o -iname '*.tar.bz2' -o \
            -iname '*.tar.xz' -o -iname '*.tar.zst' -o -iname '*.gz' -o -iname '*.xz' -o \
            -iname '*.bz2' -o -iname '*.lz' -o -iname '*.lzh' -o -iname '*.lha' -o \
            -iname '*.cab' -o -iname '*.iso' -o -iname '*.img' -o -iname '*.dd' -o \
            -iname '*.deb' -o -iname '*.pkg' -o -iname '*.pac' -o -iname '*.pp' -o \
            -iname '*.ace' -o -iname '*.arj' -o -iname '*.z' -o -iname '*.Z' -o \
            -iname '*.dmg' -o -iname '*.pkg' -o -iname '*.mpkg' -o -iname '*.sit' -o -iname '*.sitx' -o -iname '*.sea' -o \
            -iname '*.arc' -o -iname '*.r[0-9]*' -o -iname '*.part[0-9]*' \
            \) -print)
    fi #1

    readarray -t temp_files < <(find "$TARG_DIR" "${FIND_OPTS[@]}" -type f \( \
        -iname '*.zip' -o -iname '*.rar' -o -iname '*.7z' -o -iname '*.exe' -o \
        -iname '*.tar' -o -iname '*.tar.gz' -o -iname '*.tgz' -o -iname '*.tar.bz2' -o \
        -iname '*.tar.xz' -o -iname '*.tar.zst' -o -iname '*.gz' -o -iname '*.xz' -o \
        -iname '*.bz2' -o -iname '*.lz' -o -iname '*.lzh' -o -iname '*.lha' -o \
        -iname '*.cab' -o -iname '*.iso' -o -iname '*.img' -o -iname '*.dd' -o \
        -iname '*.deb' -o -iname '*.pkg' -o -iname '*.pac' -o -iname '*.pp' -o \
        -iname '*.ace' -o -iname '*.arj' -o -iname '*.z' -o -iname '*.Z' -o \
        -iname '*.dmg' -o -iname '*.pkg' -o -iname '*.mpkg' -o -iname '*.sit' -o -iname '*.sitx' -o -iname '*.sea' -o \
        -iname '*.arc' -o -iname '*.r[0-9]*' -o -iname '*.part[0-9]*' \
        \) -print)
    
    local total_found=${#temp_files[@]}
    [[ ! "$QUIET" == true ]] && echo "📁 Found $total_found potential archive files"
    [[ ! "$QUIET" == true ]] && echo "🔍 Debug: Found ${#temp_items[@]} items"
    [[ ! "$QUIET" == true ]] && printf "  • %s\n" "${temp_items[@]}"


    # Track processed multi-part archives to avoid duplicates
    local processed_multipart=()
    
    # Analyze each file/folder
    SC_RLTS=()
    for file in "${temp_items[@]}"; do ##1
        ((counter++))

        local basename=$(basename "$file")
        local size
        if $FDRTO_ARCS; then
            size=$(du -sb "$file" 2>/dev/null | cut -f1)
            [[ -z "$size" ]] && size=0
        else
            size=$(get_file_size "$file")
        fi #1
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
            for processed in "${processed_multipart[@]}"; do ##2
                if [[ "$processed" == "$first_part" ]]; then
                    already_processed=true
                    break
                fi #3
            done ##2
            
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
        
        # Skip already repacked files/folders
        if [[ "$should_process" == true ]]; then
            if $FDRTO_ARCS; then
                # Skip folders that end with _archived
                if [[ "$basename" =~ _archived$ ]]; then
                    should_process=false
                    skip_reason="already archived"
                fi
            else
                # Original archive check
                if [[ "$file" =~ _repacked(\.new[0-9]*)?\.([7z|zip|tar\.(gz|xz|zst)|tar])$ ]]; then
                    should_process=false
                    skip_reason="already repacked"
                fi
            fi
        fi

        # Check if file is already flagged as processed
        if [[ "$should_process" == true ]] && is_file_flagged "$file"; then
            should_process=false
            skip_reason="already processed (flagged)"
        fi

        if [[ "$should_process" == true && -n "$EXCL_PAT" ]] && [[ "$basename" =~ $EXCL_PAT ]]; then
            should_process=false
            skip_reason="matches exclude pattern"
        fi #1
        
        # Skip already repacked files
        #if [[ "$should_process" == true && "$file" =~ #_repacked(\.new[0-9]*)?\.([7z|zip|tar\.(gz|xz|zst)|tar])$ ]]; then
        #    should_process=false
        #    skip_reason="already repacked"
        #fi #1

        if [[ "$basename" =~ _repacked ]]; then
            should_process=false
            skip_reason="already repacked"
        fi

        # Skip already repacked files/folders
        if [[ "$should_process" == true ]]; then
            if $FOLDERS_TO_ARCS; then
                # Skip folders that end with _archived
                if [[ "$basename" =~ _archived$ ]]; then
                    should_process=false
                    skip_reason="already archived"
                fi
            else
                # Original archive check
                if [[ "$file" =~ _repacked(\.new[0-9]*)?\.([7z|zip|tar\.(gz|xz|zst)|tar])$ ]]; then
                    should_process=false
                    skip_reason="already repacked"
                fi
            fi
        fi


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
    
    local percent=0
    if (( total > 0 )); then
        percent=$((current * 100 / total))
    fi
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

AutoPak - Advanced Archive Repackaging Tool v1.0 - X-Seti - March23 2024 - 2025

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
    -h, --help               Show this help message

    --cpu-limit PERCENT      Limit CPU usage to percentage (10, 50, 90, etc.)
    --nice-level N           Set process priority (-20 to 19, negative = higher priority)
    --scan-only              Only scan files and show what would be processed
    --ignore-processed       Skip files already marked as processed
    --keep-broken-files      Keep broken/partial files during extraction
    --repair-corrupted       Attempt to repair corrupted RAR files before processing
    --ignore-corruption      Continue processing even if archives are corrupted
    --extract-multipart      Extract multi-part archives to separate folders
    --unpack-to-folders      Unpack archives to folders instead of repacking
    --folders-to-archives    Process folders instead of archive files
    --timeout SECONDS        Timeout for stuck operations (default: 300)
    --checksum-db FILE       Checksum database file location
    --generate-checksums     Generate checksum files for completed archives (default)
    --no-checksums           Don't generate checksum files
    --use-btrfs-flags        Use BTRFS extended attributes to mark processed files
    --clear-flags            Clear all autopak processing flags and exit
    --check-duplicates       Check for duplicate files/archives before processing
    --cleanup-repacked       Clean up duplicate _repacked filenames and exit

SECURITY & ENCRYPTION:
    --password-file FILE     Password file for encrypted archives
    --password-vault FILE    Encrypted password vault file
    --encrypt-archives       Encrypt created archives with AES-256
    --secure-delete          Securely overwrite deleted files
    --skip-passworded        Skip password-protected archives automatically
    --flag-passworded        Log passworded files for review
    --passworded-log FILE    Custom log file for passworded archives

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
            gz, xz, bz2, lz, lzh, lha, cab, iso, img, dd, deb, pkg, pac, pp, dmg, pkg, mpkg, sit, sitx, sea
            ace, arc, arj, z, Z (compress), multi-part RAR (part01.rar, r00/r01, etc.)
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
            --repair-corrupted) REP_CRPT=true ;;
            --keep-broken-files) KP_BRKF=true ;;
            --ignore-corruption) IGN_CORR=true ;;
            --folders-to-archives) FDRTO_ARCS=true ;;
            --unpack-to-folders) UPKTO_FDR=true ;;
            --extract-multipart) EXT_MULP=true ;;
            --use-btrfs-flags) USE_BTRFS_FLAGS=true ;;
            --ignore-processed) IGNORE_PROCESSED=true ;;
            --clear-flags) CLEAR_FLAGS=true ;;
            --timeout) shift; TIMEOUT_SECS="$1" ;;
            --cleanup-repacked) CLEANUP_REPACKED=true ;;
            --check-duplicates) CHECK_DUPLICATES=true ;;
            --generate-checksums) GEN_CHECKSUMS=true ;;
            --no-checksums) GEN_CHECKSUMS=false ;;
            --checksum-db) shift; CHECKSUM_DB="$1" ;;
            --password-file) shift; PASSWORD_FILE="$1" ;;
            --password-vault) shift; PASSWORD_VAULT="$1" ;;
            --encrypt-archives) ENCRYPT_ARCHIVES=true ;;
            --skip-passworded) SKIP_PASSWORDED=true ;;
            --flag-passworded) FLAG_PASSWORDED=true ;;
            --passworded-log) shift; PASSWORDED_LOG="$1" ;;
            --secure-delete) SECURE_DELETE=true ;;
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

    # Early password detection for common formats (NOT .exe files)
    local ext_lower=$(echo "$EXT" | tr '[:upper:]' '[:lower:]')
    if [[ "$ext_lower" =~ ^(zip|rar|7z)$ ]] && [[ ! "$ext_lower" == "exe" ]] && is_archive_passworded "$FILE" "$ext_lower"; then
        if [[ "$SKIP_PASSWORDED" == true ]]; then
            log_passworded_file "$FILE" "Archive detected as password-protected"
            [[ ! "$QUIET" == true ]] && echo "⏩ Skipping passworded: $(basename "$FILE")"
            SKP_FILS+=("$FILE")
            return 0
        elif [[ "$FLAG_PASSWORDED" == true ]]; then
            log_passworded_file "$FILE" "Archive detected as password-protected, will prompt for password"
        fi
    fi

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
    
    if [[ -n "$EXCL_PAT" ]] && [[ "$basename" =~ ${EXCL_PAT,,} ]]; then
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
            zip|ZIP)
                # Try regular extraction first, then encrypted if it fails
                if ! unzip -qq "$current_file" -d "$TMP_DIR" 2>/dev/null && \
                ! unzip -j -qq "$current_file" -d "$TMP_DIR" 2>/dev/null && \
                ! 7z x -bd -y -o"$TMP_DIR" "$current_file" >/dev/null 2>&1; then
                    # Try encrypted extraction
                    extract_encrypted_archive "$current_file" "$TMP_DIR" "zip" || EXTR_SS=false
                fi
                ;;
            rar)
                if $KP_BRKF; then
                    if ! unrar x -kb -inul "$current_file" "$TMP_DIR/" 2>/dev/null && \
                    ! 7z x -bd -y -o"$TMP_DIR" "$current_file" >/dev/null 2>&1; then
                        extract_encrypted_archive "$current_file" "$TMP_DIR" "rar" || EXTR_SS=false
                    fi
                else
                    if ! unrar x -inul "$current_file" "$TMP_DIR/" 2>/dev/null && \
                    ! 7z x -bd -y -o"$TMP_DIR" "$current_file" >/dev/null 2>&1; then
                        extract_encrypted_archive "$current_file" "$TMP_DIR" "rar" || EXTR_SS=false
                    fi
                fi
                ;;
            7z|exe)
                if ! 7z x -bd -y -o"$TMP_DIR" "$FILE" >/dev/null 2>&1; then
                    extract_encrypted_archive "$current_file" "$TMP_DIR" "7z" || EXTR_SS=false
                fi
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
            arc)
                # ARC archive support (old DOS/Windows format)
                if command -v arc &> /dev/null; then
                    arc x "$current_file" "$TMP_DIR/" 2>/dev/null || EXTR_SS=false
                elif command -v nomarch &> /dev/null; then
                    nomarch "$current_file" "$TMP_DIR/" 2>/dev/null || EXTR_SS=false
                elif command -v 7z &> /dev/null; then
                    7z x -bd -y -o"$TMP_DIR" "$current_file" >/dev/null 2>&1 || EXTR_SS=false
                else
                    [[ ! "$QUIET" == true ]] && echo "⚠️ ARC support requires 'arc', 'nomarch', or 7z with ARC plugin"
                    EXTR_SS=false
                fi
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
            dmg)
                # macOS Disk Image (read-only on Linux)
                if command -v 7z &> /dev/null; then
                    7z x -bd -y -o"$TMP_DIR" "$current_file" >/dev/null 2>&1 || EXTR_SS=false
                else
                    [[ ! "$QUIET" == true ]] && echo "⚠️ DMG support requires 7z"
                    EXTR_SS=false
                fi
                ;;
            sit|sitx)
                # StuffIt archives (Mac)
                if command -v unstuff &> /dev/null; then
                    unstuff "$current_file" -d "$TMP_DIR" 2>/dev/null || EXTR_SS=false
                elif command -v 7z &> /dev/null; then
                    7z x -bd -y -o"$TMP_DIR" "$current_file" >/dev/null 2>&1 || EXTR_SS=false
                else
                    [[ ! "$QUIET" == true ]] && echo "⚠️ StuffIt support requires 'unstuff' or 7z"
                    EXTR_SS=false
                fi
                ;;
            sea)
                # Self-extracting archive (Mac)
                # Usually needs to be run on macOS, try 7z as fallback
                7z x -bd -y -o"$TMP_DIR" "$current_file" >/dev/null 2>&1 || EXTR_SS=false
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
            if ! create_encrypted_archive "$TMP_DIR" "$NEW_ARCHIVE" "7z" "${comp_opts:-"-mx=9"}"; then
                # Fallback to regular archive
                7z a -t7z ${comp_opts:-"-mx=9"} -m0=lzma2 "$NEW_ARCHIVE" "$TMP_DIR"/* >/dev/null 2>&1 || REPACK_SUCCESS=false
            fi
            ;;
        zip)
            if ! create_encrypted_archive "$TMP_DIR" "$NEW_ARCHIVE" "zip" "${comp_opts:-"-9"}"; then
                # Fallback to regular archive
                (cd "$TMP_DIR" && zip -r ${comp_opts:-"-9"} -q "$NEW_ARCHIVE" * 2>/dev/null) || REPACK_SUCCESS=false
            fi
            ;;
        zstd)
            # No encryption support for zstd, use regular
            tar -C "$TMP_DIR" -cf - . | zstd ${comp_opts:-"-19"} -T0 -o "$NEW_ARCHIVE" 2>/dev/null || REPACK_SUCCESS=false
            ;;
        xz)
            # No encryption support for xz, use regular
            tar -C "$TMP_DIR" -cf - . | xz ${comp_opts:-"-9"} -c > "$NEW_ARCHIVE" 2>/dev/null || REPACK_SUCCESS=false
            ;;
        gz)
            # No encryption support for gz, use regular
            tar -C "$TMP_DIR" -c${comp_opts:-"z"}f "$NEW_ARCHIVE" . 2>/dev/null || REPACK_SUCCESS=false
            ;;
        tar)
            # No encryption support for tar, use regular
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
            secure_delete_file "$FILE"
            
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
    
    generate_checksum_file "$NEW_ARCHIVE" "archive_creation"

    # Set processed flag
    set_processed_flag "$FILE"

    return 0
} #closed process_archive


# Process folder into archive #vers 1
process_folder() {
    local FOLDER="$1"
    local current_num="$2"
    local total_num="$3"

    # Check if already processed (resume functionality)
    if $RESUME && is_already_processed "$FOLDER"; then
        [[ ! "$QUIET" == true ]] && echo "⏩ Already processed: $(basename "$FOLDER")"
        return 0
    fi #1

    local BASENAME=$(basename "$FOLDER")
    local FOLDER_SIZE=$(du -sb "$FOLDER" 2>/dev/null | cut -f1)

    local ext_lower=$(echo "$EXT" | tr '[:upper:]' '[:lower:]')
    if [[ "$ext_lower" =~ ^(zip|rar|7z)$ ]] && is_archive_passworded "$FILE" "$ext_lower"; then
        if [[ "$SKIP_PASSWORDED" == true ]]; then
            log_passworded_file "$FILE" "Archive detected as password-protected"
            [[ ! "$QUIET" == true ]] && echo "⏩ Skipping passworded: $(basename "$FILE")"
            SKP_FILS+=("$FILE")
            return 0
        elif [[ "$FLAG_PASSWORDED" == true ]]; then
            log_passworded_file "$FILE" "Archive detected as password-protected, will prompt for password"
        fi
    fi

    # Size filtering
    if (( MIN_SIZE > 0 && FOLDER_SIZE < MIN_SIZE )); then
        [[ ! "$QUIET" == true ]] && echo "⏩ Skipping (too small): $BASENAME"
        SKP_FILS+=("$FOLDER")
        return 0
    fi #1

    if (( MAX_SIZE > 0 && FOLDER_SIZE > MAX_SIZE )); then
        [[ ! "$QUIET" == true ]] && echo "⏩ Skipping (too large): $BASENAME"
        SKP_FILS+=("$FOLDER")
        return 0
    fi #1

    # Pattern filtering
    if [[ -n "$INCL_PAT" ]] && [[ ! "$BASENAME" =~ $INCL_PAT ]]; then
        [[ ! "$QUIET" == true ]] && echo "⏩ Skipping (not matching include pattern): $BASENAME"
        SKP_FILS+=("$FOLDER")
        return 0
    fi #1

    if [[ -n "$EXCL_PAT" ]] && [[ "$basename" =~ ${EXCL_PAT,,} ]]; then
        [[ ! "$QUIET" == true ]] && echo "⏩ Skipping (matching exclude pattern): $BASENAME"
        SKP_FILS+=("$FOLDER")
        return 0
    fi #1

    [[ ! "$QUIET" == true ]] && show_progress "$current_num" "$total_num" "$BASENAME"
    [[ ! "$QUIET" == true ]] && echo -e "\n➡️ Processing folder: $BASENAME ($(format_size "$FOLDER_SIZE"))"

    # Create backup if requested
    if $BUP_ORG && [[ ! "$DRY_RUN" == true ]]; then
        local backup_folder="${FOLDER}.backup"
        cp -r "$FOLDER" "$backup_folder"
        [[ ! "$QUIET" == true ]] && echo "💾 Created backup: $backup_folder"
    fi #1

    # Determine output filename
    local NEW_ARCHIVE
    case "$ARC_R" in
        7z)
            if ! create_encrypted_archive "$(dirname "$FOLDER")" "$NEW_ARCHIVE" "7z" "${comp_opts:-"-mx=9"}"; then
                7z a -t7z ${comp_opts:-"-mx=9"} -m0=lzma2 "$NEW_ARCHIVE" "$FOLDER"/* >/dev/null 2>&1 || ARCHIVE_SUCCESS=false
            fi
            ;;
        zip)
            if ! create_encrypted_archive "$(dirname "$FOLDER")" "$NEW_ARCHIVE" "zip" "${comp_opts:-"-9"}"; then
                (cd "$(dirname "$FOLDER")" && zip -r ${comp_opts:-"-9"} -q "$NEW_ARCHIVE" "$(basename "$FOLDER")" 2>/dev/null) || ARCHIVE_SUCCESS=false
            fi
            ;;
        zstd) NEW_ARCHIVE=$(generate_output_filename "${FOLDER}_archived" "tar.zst") ;;
        xz) NEW_ARCHIVE=$(generate_output_filename "${FOLDER}_archived" "tar.xz") ;;
        gz) NEW_ARCHIVE=$(generate_output_filename "${FOLDER}_archived" "tar.gz") ;;
        tar) NEW_ARCHIVE=$(generate_output_filename "${FOLDER}_archived" "tar") ;;
    esac # in "$ARC_R"

    if $DRY_RUN; then
        [[ ! "$QUIET" == true ]] && echo "💡 Would archive: $BASENAME → $(basename "$NEW_ARCHIVE")"
        if $DEL_ORG; then
            [[ ! "$QUIET" == true ]] && echo "💡 Would delete original folder: $BASENAME"
        fi #2
    else
        [[ ! "$QUIET" == true ]] && echo "📦 Archiving to: $(basename "$NEW_ARCHIVE")"
        local ARCHIVE_SUCCESS=true

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
        fi #2

        case "$ARC_R" in
            7z)
                echo -n "📦 Archiving with 7z"
                7z a -t7z ${comp_opts:-"-mx=9"} -m0=lzma2 "$NEW_ARCHIVE" "$FOLDER"/* >/dev/null 2>&1 &
                local archive_pid=$!
                while kill -0 $archive_pid 2>/dev/null; do
                    echo -n "."
                    sleep 2
                done
                wait $archive_pid
                [[ $? -ne 0 ]] && ARCHIVE_SUCCESS=false
                echo " ✅"
                ;;
            zip)
                (cd "$(dirname "$FOLDER")" && zip -r ${comp_opts:-"-9"} -q "$NEW_ARCHIVE" "$(basename "$FOLDER")" 2>/dev/null) || ARCHIVE_SUCCESS=false
                ;;
            zstd)
                tar -C "$(dirname "$FOLDER")" -cf - "$(basename "$FOLDER")" | zstd ${comp_opts:-"-19"} -T0 -o "$NEW_ARCHIVE" 2>/dev/null || ARCHIVE_SUCCESS=false
                ;;
            xz)
                tar -C "$(dirname "$FOLDER")" -cf - "$(basename "$FOLDER")" | xz ${comp_opts:-"-9"} -c > "$NEW_ARCHIVE" 2>/dev/null || ARCHIVE_SUCCESS=false
                ;;
            gz)
                tar -C "$(dirname "$FOLDER")" -c${comp_opts:-"z"}f "$NEW_ARCHIVE" "$(basename "$FOLDER")" 2>/dev/null || ARCHIVE_SUCCESS=false
                ;;
            tar)
                tar -C "$(dirname "$FOLDER")" -cf "$NEW_ARCHIVE" "$(basename "$FOLDER")" 2>/dev/null || ARCHIVE_SUCCESS=false
                ;;
        esac # in "$ARC_R"

        if [[ "$ARCHIVE_SUCCESS" != true ]]; then
            [[ ! "$QUIET" == true ]] && echo "❌ Failed to archive: $BASENAME"
            FAIL_F+=("$FOLDER")
            return 1
        fi #2

        # Verify archive if requested
        if $VFY_ARCS; then
            if ! verify_archive "$NEW_ARCHIVE" "$ARC_R"; then
                [[ ! "$QUIET" == true ]] && echo "❌ Archive verification failed: $(basename "$NEW_ARCHIVE")"
                FAIL_F+=("$FOLDER")
                rm -f "$NEW_ARCHIVE"
                return 1
            fi
            [[ ! "$QUIET" == true ]] && echo "✅ Archive verified: $(basename "$NEW_ARCHIVE")"
        fi #2

        # Calculate and display compression statistics
        local new_size=$(get_file_size "$NEW_ARCHIVE")
        local compression_ratio=$(calc_compression_ratio "$FOLDER_SIZE" "$new_size")

        REP_SIZE=$((REP_SIZE + new_size))

        [[ ! "$QUIET" == true ]] && echo "📊 Size: $(format_size "$FOLDER_SIZE") → $(format_size "$new_size") (${compression_ratio} compression)"

        # Handle original folder
        if $DEL_ORG; then
            [[ ! "$QUIET" == true ]] && echo "🗑️ Deleting original folder: $BASENAME"
            rm -rf "$FOLDER"
        fi #2
    fi #1

    # Save resume state
    save_resume_state "$FOLDER"

    PROC_F=$((PROC_F + 1))
    [[ ! "$QUIET" == true ]] && echo "✅ Done: $BASENAME"

    # Generate checksum file
    generate_checksum_file "$NEW_ARCHIVE" "archive_creation"

    # Set processed flag
    set_processed_flag "$FILE"

    return 0
} #closed process_folder


# Process archive into folder #vers 1
process_unpack() {
    local ARCHIVE="$1"
    local current_num="$2"
    local total_num="$3"


    # Check if already processed (resume functionality)
    if $RESUME && is_already_processed "$ARCHIVE"; then
        [[ ! "$QUIET" == true ]] && echo "⏩ Already processed: $(basename "$ARCHIVE")"
        return 0
    fi

    local BASENAME=$(basename "$ARCHIVE")
    local ARCHIVE_SIZE=$(get_file_size "$ARCHIVE")

    # Get folder name (remove extension and clean suffixes)
    local FOLDER_NAME
    if is_multipart_rar "$ARCHIVE"; then
        # For multi-part, use base name without part numbers
        FOLDER_NAME=$(echo "$BASENAME" | sed -E 's/\.(part[0-9]+\.rar|r[0-9]+|part[0-9]+)$//')
    else
        # Remove standard extensions
        FOLDER_NAME=$(echo "$BASENAME" | sed -E 's/\.(zip|rar|7z|exe|tar|tar\.gz|tgz|tar\.bz2|tar\.xz|tar\.zst|gz|xz|bz2|lz|lzh|lha|cab|iso|img|dd|deb|pkg|pac|pp|ace|arj|z|Z)$//')
    fi

    # Clean up any previous processing suffixes
    FOLDER_NAME=$(echo "$FOLDER_NAME" | sed -E 's/_archived(_repacked)?$//')
    FOLDER_NAME=$(echo "$FOLDER_NAME" | sed -E 's/_repacked(\.new[0-9]*)?$//')

    local TARGET_FOLDER="$(dirname "$ARCHIVE")/$FOLDER_NAME"

    # Skip if folder already exists
    if [[ -d "$TARGET_FOLDER" ]]; then
        [[ ! "$QUIET" == true ]] && echo "⏩ Skipping (folder exists): $FOLDER_NAME"
        SKP_FILS+=("$ARCHIVE")
        return 0
    fi

    local ext_lower=$(echo "$EXT" | tr '[:upper:]' '[:lower:]')
    if [[ "$ext_lower" =~ ^(zip|rar|7z)$ ]] && is_archive_passworded "$FILE" "$ext_lower"; then
        if [[ "$SKIP_PASSWORDED" == true ]]; then
            log_passworded_file "$FILE" "Archive detected as password-protected"
            [[ ! "$QUIET" == true ]] && echo "⏩ Skipping passworded: $(basename "$FILE")"
            SKP_FILS+=("$FILE")
            return 0
        elif [[ "$FLAG_PASSWORDED" == true ]]; then
            log_passworded_file "$FILE" "Archive detected as password-protected, will prompt for password"
        fi
    fi

    # Size filtering
    if (( MIN_SIZE > 0 && ARCHIVE_SIZE < MIN_SIZE )); then
        [[ ! "$QUIET" == true ]] && echo "⏩ Skipping (too small): $BASENAME"
        SKP_FILS+=("$ARCHIVE")
        return 0
    fi

    if (( MAX_SIZE > 0 && ARCHIVE_SIZE > MAX_SIZE )); then
        [[ ! "$QUIET" == true ]] && echo "⏩ Skipping (too large): $BASENAME"
        SKP_FILS+=("$ARCHIVE")
        return 0
    fi

    # Pattern filtering
    if [[ -n "$INCL_PAT" ]] && [[ ! "$BASENAME" =~ $INCL_PAT ]]; then
        [[ ! "$QUIET" == true ]] && echo "⏩ Skipping (not matching include pattern): $BASENAME"
        SKP_FILS+=("$ARCHIVE")
        return 0
    fi

    if [[ -n "$EXCL_PAT" ]] && [[ "$basename" =~ ${EXCL_PAT,,} ]]; then
        [[ ! "$QUIET" == true ]] && echo "⏩ Skipping (matching exclude pattern): $BASENAME"
        SKP_FILS+=("$ARCHIVE")
        return 0
    fi

    [[ ! "$QUIET" == true ]] && show_progress "$current_num" "$total_num" "$BASENAME"
    [[ ! "$QUIET" == true ]] && echo -e "\n➡️ Unpacking: $BASENAME ($(format_size "$ARCHIVE_SIZE")) → $FOLDER_NAME/"

    # Create backup if requested
    if $BUP_ORG && [[ ! "$DRY_RUN" == true ]]; then
        local backup_file="${ARCHIVE}.backup"
        cp "$ARCHIVE" "$backup_file"
        [[ ! "$QUIET" == true ]] && echo "💾 Created backup: $backup_file"
    fi

    if $DRY_RUN; then
        [[ ! "$QUIET" == true ]] && echo "💡 Would unpack: $BASENAME → $FOLDER_NAME/"
        if $DEL_ORG; then
            [[ ! "$QUIET" == true ]] && echo "💡 Would delete original: $BASENAME"
        fi
    else
        # Create target folder
        mkdir -p "$TARGET_FOLDER"
        [[ ! "$QUIET" == true ]] && echo "📁 Created folder: $FOLDER_NAME"

        local EXTRACT_SUCCESS=true
        local current_file="$ARCHIVE"

        # Handle repair for corrupted RAR files
        if $REP_CRPT && [[ "$BASENAME" =~ \.(rar|r[0-9]+|part[0-9]+\.rar|part[0-9]+)$ ]]; then
            if is_rar_corrupted "$ARCHIVE"; then
                [[ ! "$QUIET" == true ]] && echo "⚠️ Corrupted RAR detected, attempting repair..."
                local repair_dir="$TARGET_FOLDER/repair_temp"
                local repaired_file=$(repair_rar_file "$ARCHIVE" "$repair_dir")

                if [[ -n "$repaired_file" && -e "$repaired_file" ]]; then
                    [[ ! "$QUIET" == true ]] && echo "✅ Using repaired archive"
                    current_file="$repaired_file"
                fi
            fi
        fi

        # Extract archive using same logic as process_archive
        local EXT="${BASENAME##*.}"
        if is_multipart_rar "$current_file"; then
            local first_part=$(get_multipart_first_part "$current_file")
            [[ ! "$QUIET" == true ]] && echo "📦 Extracting multi-part RAR..."

            if $KP_BRKF; then
                unrar x -kb -inul "$first_part" "$TARGET_FOLDER/" 2>/dev/null || \
                7z x -bd -y -o"$TARGET_FOLDER" "$first_part" >/dev/null 2>&1 || \
                EXTRACT_SUCCESS=false
            else
                unrar x -inul "$first_part" "$TARGET_FOLDER/" 2>/dev/null || \
                7z x -bd -y -o"$TARGET_FOLDER" "$first_part" >/dev/null 2>&1 || \
                EXTRACT_SUCCESS=false
            fi
        else
            # Standard extraction (use same case logic as process_archive)
        case "$EXT" in
            zip)
                if ! unzip -qq "$current_file" -d "$TARGET_FOLDER" 2>/dev/null && \
                ! 7z x -bd -y -o"$TARGET_FOLDER" "$current_file" >/dev/null 2>&1; then
                    extract_encrypted_archive "$current_file" "$TARGET_FOLDER" "zip" || EXTRACT_SUCCESS=false
                fi
                ;;
            rar)
                if $KP_BRKF; then
                    if ! unrar x -kb -inul "$current_file" "$TARGET_FOLDER/" 2>/dev/null && \
                    ! 7z x -bd -y -o"$TARGET_FOLDER" "$current_file" >/dev/null 2>&1; then
                        extract_encrypted_archive "$current_file" "$TARGET_FOLDER" "rar" || EXTRACT_SUCCESS=false
                    fi
                else
                    if ! unrar x -inul "$current_file" "$TARGET_FOLDER/" 2>/dev/null && \
                    ! 7z x -bd -y -o"$TARGET_FOLDER" "$current_file" >/dev/null 2>&1; then
                        extract_encrypted_archive "$current_file" "$TARGET_FOLDER" "rar" || EXTRACT_SUCCESS=false
                    fi #2
                fi #1
                ;;
            7z|exe)
                if ! 7z x -bd -y -o"$TARGET_FOLDER" "$current_file" >/dev/null 2>&1; then
                    extract_encrypted_archive "$current_file" "$TARGET_FOLDER" "7z" || EXTRACT_SUCCESS=false
                fi
                ;;
                tar)
                    tar -xf "$current_file" -C "$TARGET_FOLDER" 2>/dev/null || EXTRACT_SUCCESS=false
                    ;;
                *)
                    # Use same extraction logic as process_archive for other formats
                    7z x -bd -y -o"$TARGET_FOLDER" "$current_file" >/dev/null 2>&1 || EXTRACT_SUCCESS=false
                    ;;
            esac # in "$EXT"
        fi

        if [[ "$EXTRACT_SUCCESS" != true ]]; then
            [[ ! "$QUIET" == true ]] && echo "❌ Failed to extract: $BASENAME"
            FAIL_F+=("$ARCHIVE")
            rm -rf "$TARGET_FOLDER"
            return 1
        fi

        # Check if extraction resulted in any files
        if [[ ! "$(ls -A "$TARGET_FOLDER")" ]]; then
            [[ ! "$QUIET" == true ]] && echo "❌ Empty extraction: $BASENAME"
            FAIL_F+=("$ARCHIVE")
            rm -rf "$TARGET_FOLDER"
            return 1
        fi

        [[ ! "$QUIET" == true ]] && echo "✅ Extracted to: $FOLDER_NAME/"

        # Handle original archive
        if $DEL_ORG; then
            [[ ! "$QUIET" == true ]] && echo "🗑️ Deleting original: $BASENAME"
            rm -f "$ARCHIVE"

            # For multi-part RAR files, also delete the related parts
            if is_multipart_rar "$ARCHIVE"; then
                local dir=$(dirname "$ARCHIVE")
                local basename_no_ext=$(basename "$ARCHIVE")

                if [[ "$basename_no_ext" =~ ^(.*)\.part[0-9]+\.rar$ ]]; then
                    local base_name="${BASH_REMATCH[1]}"
                    rm -f "$dir/${base_name}".part*.rar 2>/dev/null
                    [[ ! "$QUIET" == true ]] && echo "🗑️ Deleted multi-part RAR set: ${base_name}.part*.rar"
                elif [[ "$basename_no_ext" =~ ^(.*)\.rar$ ]]; then
                    local base_name="${BASH_REMATCH[1]}"
                    rm -f "$dir/${base_name}".r[0-9]* 2>/dev/null
                    [[ ! "$QUIET" == true ]] && echo "🗑️ Deleted multi-part RAR set: ${base_name}.r*"
                fi
            fi
        fi
    fi

    # Save resume state
    save_resume_state "$ARCHIVE"

    PROC_F=$((PROC_F + 1))
    [[ ! "$QUIET" == true ]] && echo "✅ Done: $BASENAME"

    # Generate checksum file
    generate_checksum_file "$NEW_ARCHIVE" "archive_creation"

    # Set processed flag
    set_processed_flag "$FILE"

    return 0
} #closed process_unpack


# Initialize checksum database #vers 1
init_checksum_db() {
    if [[ ! -f "$CHECKSUM_DB" ]]; then
        sqlite3 "$CHECKSUM_DB" << 'EOF'
CREATE TABLE IF NOT EXISTS checksums (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    filename TEXT NOT NULL,
    filepath TEXT NOT NULL,
    filesize INTEGER,
    sha256 TEXT,
    md5 TEXT,
    processed_date TEXT,
    operation_type TEXT,
    UNIQUE(filepath)
);
CREATE INDEX IF NOT EXISTS idx_filepath ON checksums(filepath);
CREATE INDEX IF NOT EXISTS idx_sha256 ON checksums(sha256);
CREATE INDEX IF NOT EXISTS idx_md5 ON checksums(md5);
EOF
    fi
} #closed init_checksum_db

# Generate checksum file and store in database #vers 1
generate_checksum_file() {
    local archive_file="$1"
    local operation_type="$2"

    if [[ ! "$GEN_CHECKSUMS" == true ]] || [[ ! -f "$archive_file" ]]; then
        return 0
    fi

    local checksum_file="${archive_file}.txt"
    local filename=$(basename "$archive_file")
    local filesize=$(get_file_size "$archive_file")
    local sha256_hash=$(sha256sum "$archive_file" | cut -d' ' -f1)
    local md5_hash=$(md5sum "$archive_file" | cut -d' ' -f1)
    local current_date=$(date -Iseconds)

    # Create checksum file
    {
        echo "# AutoPak Checksum Verification for: $filename"
        echo "# Generated: $current_date"
        echo "# Operation: $operation_type"
        echo "# =================================="
        echo
        echo "File: $filename"
        echo "Size: $filesize bytes ($(format_size "$filesize"))"
        echo "SHA256: $sha256_hash"
        echo "MD5: $md5_hash"
        echo "Date: $current_date"
        echo "Operation: $operation_type"
    } > "$checksum_file"

    # Store in database
    if command -v sqlite3 &> /dev/null; then
        sqlite3 "$CHECKSUM_DB" << EOF
INSERT OR REPLACE INTO checksums
(filename, filepath, filesize, sha256, md5, processed_date, operation_type)
VALUES
('$filename', '$archive_file', $filesize, '$sha256_hash', '$md5_hash', '$current_date', '$operation_type');
EOF
    fi

    [[ ! "$QUIET" == true ]] && echo "📋 Generated checksum: $(basename "$checksum_file")"
} #closed generate_checksum_file

# Check if archive is password protected #vers 1
is_archive_passworded() {
    local archive_file="$1"
    local archive_type="$2"

    case "$archive_type" in
        zip)
            # More specific password check for ZIP
            if unzip -t "$archive_file" 2>&1 | grep -q "incorrect password\|need PK compat"; then
                return 0  # Is passworded
            fi
            ;;
        rar)
            # More specific password check for RAR
            if unrar t "$archive_file" 2>&1 | grep -q "password required\|encrypted headers"; then
                return 0  # Is passworded
            fi
            ;;
        7z)
            # More specific password check for 7z
            if 7z t "$archive_file" 2>&1 | grep -q "Wrong password\|password required"; then
                return 0  # Is passworded
            fi
            ;;
    esac

    return 1  # Not passworded
} #closed is_archive_passworded

# Log passworded file #vers 1
log_passworded_file() {
    local archive_file="$1"
    local reason="$2"

    if [[ "$FLAG_PASSWORDED" == true ]]; then
        {
            echo "Passworded file detected: $(date -Iseconds)"
            echo "File: $archive_file"
            echo "Size: $(get_file_size "$archive_file") bytes ($(format_size "$(get_file_size "$archive_file")"))"
            echo "Reason: $reason"
            echo "Location: $(dirname "$archive_file")"
            echo "---"
        } >> "$PASSWORDED_LOG"

        [[ ! "$QUIET" == true ]] && echo "🔐 Logged passworded file: $(basename "$archive_file")"
    fi
} #closed log_passworded_file

# Check for duplicate files using checksums #vers 1
check_for_duplicates() {
    if [[ ! "$CHECK_DUPLICATES" == true ]] || [[ ! -f "$CHECKSUM_DB" ]]; then
        return 0
    fi

    [[ ! "$QUIET" == true ]] && echo "🔍 Checking for duplicate files..."

    local duplicates_found=false
    local temp_dups="/tmp/autopak_duplicates_$$.txt"

    # Find duplicates by SHA256
    sqlite3 "$CHECKSUM_DB" << 'EOF' > "$temp_dups"
SELECT sha256, COUNT(*) as count, GROUP_CONCAT(filepath, ' | ') as files
FROM checksums
WHERE sha256 != ''
GROUP BY sha256
HAVING count > 1
ORDER BY count DESC;
EOF

    if [[ -s "$temp_dups" ]]; then
        duplicates_found=true
        [[ ! "$QUIET" == true ]] && echo "⚠️ Duplicate files found:"
        while IFS='|' read -r sha256 count files; do
            [[ ! "$QUIET" == true ]] && echo "  🔄 $count copies (SHA256: ${sha256:0:16}...): $files"
        done < "$temp_dups"
    fi

    rm -f "$temp_dups"

    if [[ "$duplicates_found" == true ]]; then
        [[ ! "$QUIET" == true ]] && echo "💡 Consider using --exclude-pattern to skip duplicate processing"
    else
        [[ ! "$QUIET" == true ]] && echo "✅ No duplicates found"
    fi
} #closed check_for_duplicates

# BTRFS extended attribute functions #vers 1
set_processed_flag() {
    local file="$1"

    if [[ ! "$USE_BTRFS_FLAGS" == true ]]; then
        return 0
    fi

    if command -v setfattr &> /dev/null; then
        setfattr -n user.autopak.processed -v "true" "$file" 2>/dev/null
        setfattr -n user.autopak.date -v "$(date -Iseconds)" "$file" 2>/dev/null
        setfattr -n user.autopak.version -v "1.0" "$file" 2>/dev/null
    fi
} #closed set_processed_flag

# Check if file has processed flag #vers 1
is_file_flagged() {
    local file="$1"

    if [[ ! "$USE_BTRFS_FLAGS" == true ]] || [[ ! "$IGNORE_PROCESSED" == true ]]; then
        return 1  # Not flagged
    fi

    if command -v getfattr &> /dev/null; then
        local flag_value=$(getfattr -n user.autopak.processed --only-values "$file" 2>/dev/null)
        [[ "$flag_value" == "true" ]]
    else
        return 1  # Can't check, assume not flagged
    fi
} #closed is_file_flagged

# Clear all autopak flags #vers 1
clear_autopak_flags() {
    local target_dir="$1"

    [[ ! "$QUIET" == true ]] && echo "🧹 Clearing AutoPak processing flags..."

    local cleared_count=0
    local FIND_OPTS=()
    $RECURSIVE || FIND_OPTS+=(-maxdepth 1)

    while IFS= read -r -d '' file; do
        if command -v setfattr &> /dev/null; then
            setfattr -x user.autopak.processed "$file" 2>/dev/null && ((cleared_count++))
            setfattr -x user.autopak.date "$file" 2>/dev/null
            setfattr -x user.autopak.version "$file" 2>/dev/null
        fi
    done < <(find "$target_dir" "${FIND_OPTS[@]}" -type f -print0)

    [[ ! "$QUIET" == true ]] && echo "✅ Cleared flags from $cleared_count files"
} #closed clear_autopak_flags

# Timeout wrapper for operations #vers 1
run_with_timeout() {
    local timeout_duration="$1"
    local operation_name="$2"
    shift 2
    local command=("$@")

    [[ ! "$QUIET" == true ]] && echo "⏱️ Running $operation_name (timeout: ${timeout_duration}s)"

    # Run command in background
    "${command[@]}" &
    local cmd_pid=$!

    # Start timeout counter
    (
        sleep "$timeout_duration"
        if kill -0 "$cmd_pid" 2>/dev/null; then
            [[ ! "$QUIET" == true ]] && echo "⚠️ Operation timed out, killing process..."
            kill -TERM "$cmd_pid" 2>/dev/null
            sleep 5
            kill -KILL "$cmd_pid" 2>/dev/null
        fi
    ) &
    local timeout_pid=$!

    # Wait for command to complete
    local exit_code=0
    if wait "$cmd_pid"; then
        exit_code=0
    else
        exit_code=1
    fi

    # Kill timeout process if command completed
    kill "$timeout_pid" 2>/dev/null
    wait "$timeout_pid" 2>/dev/null

    return $exit_code
} #closed run_with_timeout


# Clean up duplicate _repacked filenames #vers 1
cleanup_repacked_files() {
    local target_dir="$1"

    [[ ! "$QUIET" == true ]] && echo "🧹 Cleaning up duplicate _repacked files..."

    local cleaned_count=0
    local FIND_OPTS=()
    $RECURSIVE || FIND_OPTS+=(-maxdepth 1)

    # Find files with multiple _repacked in name
    while IFS= read -r -d '' file; do
        local basename=$(basename "$file")
        local dirname=$(dirname "$file")

        # Count how many _repacked instances
        local repacked_count=$(echo "$basename" | grep -o "_repacked" | wc -l)

        if (( repacked_count > 1 )); then
            # Create clean name with only one _repacked
            local clean_name=$(echo "$basename" | sed 's/_repacked\(_repacked\)*/\_repacked/')
            local clean_path="$dirname/$clean_name"

            # Only rename if clean name doesn't exist
            if [[ ! -e "$clean_path" ]]; then
                mv "$file" "$clean_path"
                [[ ! "$QUIET" == true ]] && echo "  📝 $(basename "$file") → $clean_name"
                ((cleaned_count++))
            else
                [[ ! "$QUIET" == true ]] && echo "  🗑️ Removing duplicate: $(basename "$file")"
                secure_delete_file "$FILE"
                ((cleaned_count++))
            fi
        fi
    done < <(find "$target_dir" "${FIND_OPTS[@]}" -name "*_repacked_repacked*" -type f -print0)

    [[ ! "$QUIET" == true ]] && echo "✅ Cleaned up $cleaned_count files"
    #while IFS= read -r -d '' file; do
} #closed cleanup_repacked_files

# Password vault management #vers 1
init_password_vault() {
    local vault_file="$1"

    if [[ ! -f "$vault_file" ]]; then
        [[ ! "$QUIET" == true ]] && echo "🔐 Creating new password vault: $vault_file"

        # Prompt for master password
        read -s -p "Enter master password for vault: " MASTER_PASSWORD
        echo
        read -s -p "Confirm master password: " confirm_password
        echo

        if [[ "$MASTER_PASSWORD" != "$confirm_password" ]]; then
            echo "❌ Passwords don't match!"
            return 1
        fi

        # Create encrypted vault file
        echo '{"version":"1.0","passwords":{}}' | openssl enc -aes-256-cbc -salt -pass pass:"$MASTER_PASSWORD" -out "$vault_file"
        [[ ! "$QUIET" == true ]] && echo "✅ Password vault created"
    fi

    return 0
} #closed init_password_vault

# Add password to vault #vers 1
add_password_to_vault() {
    local vault_file="$1"
    local archive_name="$2"
    local password="$3"

    if [[ ! -f "$vault_file" ]]; then
        echo "❌ Password vault not found: $vault_file"
        return 1
    fi

    # Decrypt vault
    local temp_vault="/tmp/autopak_vault_$$.json"
    if ! openssl enc -aes-256-cbc -d -salt -pass pass:"$MASTER_PASSWORD" -in "$vault_file" -out "$temp_vault" 2>/dev/null; then
        echo "❌ Failed to decrypt password vault (wrong master password?)"
        rm -f "$temp_vault"
        return 1
    fi

    # Add password using jq
    if command -v jq &> /dev/null; then
        jq --arg name "$archive_name" --arg pass "$password" '.passwords[$name] = $pass' "$temp_vault" > "${temp_vault}.new"
        mv "${temp_vault}.new" "$temp_vault"

        # Re-encrypt vault
        openssl enc -aes-256-cbc -salt -pass pass:"$MASTER_PASSWORD" -in "$temp_vault" -out "$vault_file"
        rm -f "$temp_vault"

        [[ ! "$QUIET" == true ]] && echo "🔐 Password stored for: $archive_name"
    else
        echo "❌ jq required for password vault management"
        rm -f "$temp_vault"
        return 1
    fi

    return 0
} #closed add_password_to_vault

# Get password from vault #vers 1
get_password_from_vault() {
    local vault_file="$1"
    local archive_name="$2"

    if [[ ! -f "$vault_file" ]]; then
        return 1
    fi

    # Decrypt vault
    local temp_vault="/tmp/autopak_vault_$$.json"
    if ! openssl enc -aes-256-cbc -d -salt -pass pass:"$MASTER_PASSWORD" -in "$vault_file" -out "$temp_vault" 2>/dev/null; then
        rm -f "$temp_vault"
        return 1
    fi

    # Get password using jq
    if command -v jq &> /dev/null; then
        local password=$(jq -r --arg name "$archive_name" '.passwords[$name] // empty' "$temp_vault")
        rm -f "$temp_vault"

        if [[ -n "$password" && "$password" != "null" ]]; then
            echo "$password"
            return 0
        fi
    else
        rm -f "$temp_vault"
    fi

    return 1
} #closed get_password_from_vault

# Secure file deletion #vers 1
secure_delete_file() {
    local file="$1"

    if [[ ! "$SECURE_DELETE" == true ]] || [[ ! -f "$file" ]]; then
        secure_delete_file "$FILE"
        return 0
    fi #1

    [[ ! "$QUIET" == true ]] && echo "🔒 Securely deleting: $(basename "$file")"

    # Multiple pass secure deletion
    if command -v shred &> /dev/null; then
        shred -vfz -n 3 "$file" 2>/dev/null
    elif command -v wipe &> /dev/null; then
        wipe -rf "$file" 2>/dev/null
    else
        # Fallback: overwrite with random data
        local filesize=$(stat -c%s "$file" 2>/dev/null || echo "0")
        if (( filesize > 0 )); then
            dd if=/dev/urandom of="$file" bs=1024 count=$((filesize / 1024 + 1)) 2>/dev/null
            sync
        fi #2
        secure_delete_file "$FILE"
    fi #1

    [[ ! "$QUIET" == true ]] && echo "✅ Secure deletion completed"
} #closed secure_delete_file

# Handle encrypted archive extraction #vers 1
extract_encrypted_archive() {
    local archive_file="$1"
    local temp_dir="$2"
    local archive_type="$3"

    # Check if we should skip passworded files
    if [[ "$SKIP_PASSWORDED" == true ]]; then
        log_passworded_file "$archive_file" "Skipped due to --skip-passworded flag"
        [[ ! "$QUIET" == true ]] && echo "⏩ Skipping passworded archive: $(basename "$archive_file")"
        return 1  # Return failure to skip processing
    fi #1

    local password=""
    local extraction_success=false

        # Try to get password from vault first
    if [[ -n "$PASSWORD_VAULT" ]]; then
        password=$(get_password_from_vault "$PASSWORD_VAULT" "$(basename "$archive_file")")
    fi #1

    # Try password file if no vault password found
    if [[ -z "$password" && -f "$PASSWORD_FILE" ]]; then
        password=$(head -n1 "$PASSWORD_FILE")
    fi #1

    # If still no password, check if we should prompt or skip
    if [[ -z "$password" ]]; then
        if [[ "$FLAG_PASSWORDED" == true ]]; then
            log_passworded_file "$archive_file" "No password available, requires manual input"
        fi #1

        read -s -p "Enter password for $(basename "$archive_file") (or Ctrl+C to skip): " password
        echo

        # Optionally store in vault
        if [[ -n "$PASSWORD_VAULT" && -n "$password" ]]; then
            add_password_to_vault "$PASSWORD_VAULT" "$(basename "$archive_file")" "$password"
        fi #2
    fi #1

    # Try to get password from vault first
    if [[ -n "$PASSWORD_VAULT" ]]; then
        password=$(get_password_from_vault "$PASSWORD_VAULT" "$(basename "$archive_file")")
    fi #1

    # Try password file if no vault password found
    if [[ -z "$password" && -f "$PASSWORD_FILE" ]]; then
        password=$(head -n1 "$PASSWORD_FILE")
    fi #1

    # If still no password, prompt user
    if [[ -z "$password" ]]; then
        read -s -p "Enter password for $(basename "$archive_file"): " password
        echo

        # Optionally store in vault
        if [[ -n "$PASSWORD_VAULT" && -n "$password" ]]; then
            add_password_to_vault "$PASSWORD_VAULT" "$(basename "$archive_file")" "$password"
        fi #2
    fi #1

    # Try extraction with password
    case "$archive_type" in
        zip)
            unzip -P "$password" -qq "$archive_file" -d "$temp_dir" 2>/dev/null && extraction_success=true
            ;;
        rar)
            unrar x -p"$password" -inul "$archive_file" "$temp_dir/" 2>/dev/null && extraction_success=true
            ;;
        7z)
            7z x -p"$password" -bd -y -o"$temp_dir" "$archive_file" >/dev/null 2>&1 && extraction_success=true
            ;;
    esac # in "$archive_type"

    if [[ "$extraction_success" == true ]]; then
        [[ ! "$QUIET" == true ]] && echo "🔓 Successfully extracted encrypted archive"
        return 0
    else
        [[ ! "$QUIET" == true ]] && echo "❌ Failed to extract encrypted archive (wrong password?)"
        return 1
    fi #1
} #closed extract_encrypted_archive

# Create encrypted archive #vers 1
create_encrypted_archive() {
    local source_dir="$1"
    local output_file="$2"
    local archiver="$3"
    local compression_opts="$4"

    if [[ ! "$ENCRYPT_ARCHIVES" == true ]]; then
        return 1  # Not encrypting, use normal method
    fi

    local password=""

    # Get encryption password
    if [[ -n "$PASSWORD_VAULT" ]]; then
        password=$(get_password_from_vault "$PASSWORD_VAULT" "$(basename "$output_file")")
    fi

    if [[ -z "$password" ]]; then
        read -s -p "Enter password for encrypted archive $(basename "$output_file"): " password
        echo

        # Store in vault
        if [[ -n "$PASSWORD_VAULT" && -n "$password" ]]; then
            add_password_to_vault "$PASSWORD_VAULT" "$(basename "$output_file")" "$password"
        fi
    fi

    [[ ! "$QUIET" == true ]] && echo "🔐 Creating encrypted archive..."

    # Create encrypted archive
    case "$archiver" in
        7z)
            7z a -t7z -p"$password" ${compression_opts:-"-mx=9"} -m0=lzma2 "$output_file" "$source_dir"/* >/dev/null 2>&1
            ;;
        zip)
            (cd "$source_dir" && zip -P "$password" -r ${compression_opts:-"-9"} -q "$output_file" * 2>/dev/null)
            ;;
        *)
            [[ ! "$QUIET" == true ]] && echo "⚠️ Encryption not supported for $archiver format"
            return 1
            ;;
    esac

    if [[ $? -eq 0 ]]; then
        [[ ! "$QUIET" == true ]] && echo "🔐 Encrypted archive created successfully"
        return 0
    else
        [[ ! "$QUIET" == true ]] && echo "❌ Failed to create encrypted archive"
        return 1
    fi
} #closed create_encrypted_archive



# Show archiving progress with dots #vers 1
show_archive_progress() {
    local archive_file="$1"
    local folder="$2"

    if [[ "$QUIET" == true ]]; then
        return
    fi

    echo -n "📦 Archiving"
    while [[ ! -f "$archive_file" ]] || kill -0 $! 2>/dev/null; do
        echo -n "."
        sleep 2
    done
    echo " ✅"
} #closed show_archive_progress

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
export -f process_folder
export -f process_unpack
export -f generate_checksum_file
export -f set_processed_flag
export -f is_file_flagged
export -f run_with_timeout
export -f init_password_vault
export -f add_password_to_vault
export -f get_password_from_vault
export -f secure_delete_file
export -f extract_encrypted_archive
export -f create_encrypted_archive
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
        fi #2
        echo "🎯 Single file mode: $(basename "$TARG_DIR")"
        INCL_PAT="^$(basename "$TARG_DIR")$"
        TARG_DIR=$(dirname "$TARG_DIR")
    fi #1

    # Handle flag clearing
    if $CLEAR_FLAGS; then
        clear_autopak_flags "$TARG_DIR"
        exit 0
    fi

    # Initialize checksum database
    if $GEN_CHECKSUMS || $CHECK_DUPLICATES; then
        init_checksum_db
    fi

        # Initialize password vault if specified
    if [[ -n "$PASSWORD_VAULT" ]]; then
        if [[ -z "$MASTER_PASSWORD" ]]; then
            read -s -p "Enter master password for vault: " MASTER_PASSWORD
            echo
        fi
        init_password_vault "$PASSWORD_VAULT"
    fi

# Check for duplicates
check_for_duplicates

    # Validate inputs - handle different error scenarios
    if [[ $original_arg_count -eq 0 ]]; then
        show_help
        exit 1
    fi #1

    if [[ -z "$TARG_DIR" ]]; then
        echo "❌ Error: No directory specified"
        echo "💡 Usage: $(basename "$0") [OPTIONS] <directory>"
        exit 1
    fi #1

    if [[ ! -d "$TARG_DIR" ]]; then
        echo "❌ Error: Directory '$TARG_DIR' doesn't exist or is not accessible"
        echo "💡 Please check the path and try again"
        exit 1
    fi #1

    # Handle cleanup repacked files
    if $CLEANUP_REPACKED; then
        cleanup_repacked_files "$TARG_DIR"
        exit 0
    fi #1

    # Validate archiver
    case "$ARC_R" in
        7z|zip|zstd|xz|gz|tar) ;;
        *) echo "❌ Invalid archiver: $ARC_R"; exit 2 ;;
    esac # in "$ARC_R"

    check_dependencies
    setup_cpu_limiting

    mkdir -p "$WORK_DIR"
    scan_files
    
    # In check_dependencies function, add:
    if $ENCRYPT_ARCHIVES || [[ -n "$PASSWORD_VAULT" ]]; then
        for cmd in openssl jq; do
            if ! command -v "$cmd" &> /dev/null; then
                missing_deps+=("$cmd")
            fi
        done
    fi

    if $SECURE_DELETE; then
        # shred and wipe are optional, script has fallback
        [[ ! $(command -v shred) && ! $(command -v wipe) ]] && optional_deps+=("secure-delete")
    fi

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
                fi #3
            done ##1
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
        WORK_DIR="$WORK_DIR" \
        UPKTO_FDR="$UPKTO_FDR" \
        xargs -P "$PAR_JOBS" -I {} bash -c 'if [[ "$FDRTO_ARCS" == true ]]; then process_folder "{}" 1 '"$TOT_F"'; elif [[ "$UPKTO_FDR" == true ]]; then process_unpack "{}" 1 '"$TOT_F"'; else process_archive "{}" 1 '"$TOT_F"'; fi'

        xargs -P "$PAR_JOBS" -I {} bash -c 'if [[ "$FDRTO_ARCS" == true ]]; then process_folder "{}" 1 '"$TOT_F"'; else process_archive "{}" 1 '"$TOT_F"'; fi'
    else
        # Sequential processing
        local counter=0
        for item in "${processing_queue[@]}"; do
            ((counter++))
            if $FDRTO_ARCS; then
                process_folder "$item" "$counter" "$TOT_F"
            elif $UPKTO_FDR; then
                process_unpack "$item" "$counter" "$TOT_F"
            else
                process_archive "$item" "$counter" "$TOT_F"
            fi #2
        done
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
    
    # Show passworded files summary
    if [[ "$FLAG_PASSWORDED" == true ]] && [[ -f "$PASSWORDED_LOG" ]]; then
        local passworded_count=$(grep -c "^Passworded file detected:" "$PASSWORDED_LOG" 2>/dev/null || echo "0")
        if (( passworded_count > 0 )); then
            echo "🔐 Passworded files logged: $passworded_count"
            echo "📋 Passworded files log: $PASSWORDED_LOG"
        fi
    fi

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
