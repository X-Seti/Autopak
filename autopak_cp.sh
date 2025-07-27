#!/bin/bash
# X-Seti - March23 2024 - AutoPak - Archive Repackaging Tool - Version: 1.0

# Default settings
REC=false
DEL=false
ARC="7z"
TDIR=""
DRY=false
Q=false
JOBS=1
LVL=""
BUP=false
VFY=false
RES=false
CFG="$HOME/.autopak.conf"
INCL=""
EXCL=""
MINS=0
MAXS=0
FDR_ARC=false # Process folders instead of archives
UNP_FDR=false
CPU_LIM=0  # 0 = no limit, 10 = 10%, 90 = 90%
NICE=0  # Process priority adjustment
SCN=false  # Only scan and report what would be done
EXT_MP=false  # Extract multi-part archives to separate folders
REP_CRP=false   # Attempt to repair corrupted RAR files before processing
KP_BRK=false  # Keep broken/partial files during extraction
IGN_COR=false  # Continue processing even if archives are corrupted
SING_FIL=false
GEN_CSUMS=true  # Generate checksums for completed archives by default
BTRFS_FLG=false  # Use BTRFS extended attributes to mark processed files
IGN_PROC=false  # Skip files marked as processed
CLR_FLGS=false  # Clear all autopak processing flags
OUTATIME=300  # Timeout for stuck operations (5 minutes)
CHK_DUPS=false  # Check for duplicate files/archives
CHKSUM_DB="/tmp/autopak_checksums.db"  # Checksum database
CLNUP_PKED=false
EXCL_EXT=()
EXCL_PATN=()
EXCL_DIR=()

# Passwords and Encryption
PWD_FILE=""  # Password file for encrypted archives
PWD_VAULT=""  # Encrypted password vault file
MSTER_PWD=""  # Master password for vault
ENCRYPT_ARC=false  # Encrypt created archives
SEC_DEL=false  # Securely overwrite deleted files
SKP_PWD=false  # Skip password-protected archives automatically
FLAG_PWD=false  # Flag passworded files for review
PWD_LOG="/tmp/autopak_passworded_$(date +%Y%m%d_%H%M%S).log"  # Log of skipped passworded files

# Statistics and progress
TOT_F=0
PROC_F=0
FAIL_F=()
SKP_F=()
F_JOBS=()  # failure tracking
S_TIME=$(date +%s)
O_SIZE=0
REP_SIZE=0
SC_RLTS=()  # Array to store scan results
C_PHSE=""  # Track current operation phase

# Logging
LOGFILE="/tmp/autopack_$(date +%Y%m%d_%H%M%S).log"
RSM_FIL="/tmp/autopak_resume_$(basename "$0")_$$.state"
S_CACHE="/tmp/autopak_scan_$(basename "$0")_$$.cache"
CPU_P=""  # PID of cpulimit process if running
WORK_DIR="$HOME/.autopak_tmp_$$"

# Signal handling
cleanup_exit() {
    echo -e "\n🛑 Interrupted! Cleaning up..."
    if [[ -d "$WORK_DIR" ]]; then
        chmod -R 755 "$WORK_DIR" 2>/dev/null
        rm -rf "$WORK_DIR"
    fi #2
    [[ -f "$RSM_FIL" ]] && rm -f "$RSM_FIL"
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
} #closed cleanup_exit

trap cleanup_exit INT TERM

# Load configuration
load_cfg() {
    if [[ -f "$CFG" ]]; then
        source "$CFG"
        [[ ! "$Q" == true ]] && echo "📋 Loaded config from: $CFG"
    fi #1
} #closed load_cfg

# Save configuration
save_cfg() {
    cat > "$CFG" << EOF
# AutoPak Configuration
ARC="$ARC"
LVL="$LVL"
JOBS=$JOBS
VFY=$VFY
BUP=$BUP
CPU_LIM=$CPU_LIM
NICE=$NICE
EXT_MP=$EXT_MP
REP_CRP=$REP_CRP
KP_BRK=$KP_BRK
EOF
    echo "💾 Configuration saved to: $CFG"
} #closed save_cfg

# CPU management functions
setup_cpu() {
    if (( CPU_LIM > 0 )); then
        if command -v cpulimit &> /dev/null; then
            [[ ! "$Q" == true ]] && echo "🔧 Setting CPU limit to ${CPU_LIM}%"
            cpulimit -l "$CPU_LIM" -p $$ &
            CPU_P=$!
        else
            echo "⚠️ cpulimit not found, CPU limiting disabled"
            echo "Install with: sudo apt-get install cpulimit"
        fi #1
    fi #2

    if (( NICE != 0 )); then
        [[ ! "$Q" == true ]] && echo "🔧 Setting process priority (nice level: $NICE)"
        renice "$NICE" $$ >/dev/null 2>&1
    fi #1
} #closed setup_cpu

# Advanced progress display
show_prog() {
    local current=$1
    local total=$2
    local filename="$3"
    local operation="$4"
    local size="$5"

    if [[ "$Q" == true ]]; then
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
} #closed show_prog

# RAR repair functionality
repair_rar() {
    local rar_file="$1"
    local repair_dir="$2"
    local repaired_file=""

    [[ ! "$Q" == true ]] && echo "🔧 Attempting to repair: $(basename "$rar_file")"

    # Create repair directory if it doesn't exist
    mkdir -p "$repair_dir"

    # Method 1: Try WinRAR/RAR repair command
    if command -v rar &> /dev/null; then
        local repair_output="$repair_dir/rebuilt.$(basename "$rar_file")"
        if rar r -y "$rar_file" "$repair_output" >/dev/null 2>&1; then
            if [[ -f "$repair_output" ]]; then
                [[ ! "$Q" == true ]] && echo "✅ RAR repair successful using 'rar r' command"
                echo "$repair_output"
                return 0
            fi #3
        fi #2
    fi #1

    # Method 2: Try recovery volume reconstruction if .rev files exist
    if is_multipart "$rar_file"; then
        local first_part=$(get_first_part "$rar_file")
        local dir_name=$(dirname "$first_part")

        # Check for .rev files
        if ls "$dir_name"/*.rev &>/dev/null; then
            [[ ! "$Q" == true ]] && echo "🔄 Found recovery volumes, attempting reconstruction..."

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
                        [[ ! "$Q" == true ]] && echo "✅ RAR reconstruction successful using recovery volumes"
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
                [[ ! "$Q" == true ]] && echo "✅ Partial repair successful using 7-Zip extraction"
                echo "$temp_extract"
                return 0
            fi #3
        fi #2
        rm -rf "$temp_extract"
    fi #1

    # Method 4: Force extraction with keep broken files
    if $KP_BRK; then
        local brkext="$repair_dir/brkext"
        mkdir -p "$brkext"

        if command -v unrar &> /dev/null; then
            # Try unrar with keep broken files equivalent
            if unrar x -kb -y "$rar_file" "$brkext/" >/dev/null 2>&1; then
                if [[ "$(ls -A "$brkext")" ]]; then
                    [[ ! "$Q" == true ]] && echo "⚠️ Partial extraction successful (broken files kept)"
                    echo "$brkext"
                    return 0
                fi #4
            fi #3
        fi #2

        rm -rf "$brkext"
    fi #1

    [[ ! "$Q" == true ]] && echo "❌ RAR repair failed: $(basename "$rar_file")"
    return 1
} #closed repair_rar

# Check if RAR file appears corrupted
is_corrupt() {
    local rar_file="$1"

    # For multi-part archives, test the first part instead of individual parts
    if is_multipart "$rar_file"; then
        local first_part=$(get_first_part "$rar_file")
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
} #closed is_corrupt

is_multipart() {
    local file="$1"
    # Check for various multi-part RAR naming conventions
    if [[ "$file" =~ \.(part[0-9]+\.rar|r[0-9]+)$ ]] || [[ "$file" =~ \.part[0-9]+$ ]]; then
        return 0
    fi #1
    return 1
} #closed is_multipart

# Get the first part of a multi-part RAR archive
get_first_part() {
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
} #closed get_first_part

# File scanning with detailed info gathering
scan_files() {
    C_PHSE="Scanning files"
    [[ ! "$Q" == true ]] && echo "🔍 Phase 1: Scanning and analyzing files..."

    # Debug: Show exclude config status
    [[ ! "$Q" == true ]] && echo "🔍 Debug: EXCL_EXT has ${#EXCL_EXT[@]} items: ${EXCL_EXT[*]}"

    # Check if we have a cached scan
    if [[ -f "$S_CACHE" ]] && $RES; then
        [[ ! "$Q" == true ]] && echo "📋 Loading cached scan results..."
        source "$S_CACHE"
        return
    fi #1

    local counter=0
    local scan_S_TIME=$(date +%s)

    # Build find options for recursion
    local FIND_OPTS=()
    $REC || FIND_OPTS+=(-maxdepth 1)

    # Get all potential files first
    local temp_files=()
    # Get all potential files/folders
    local temp_items=()

    if $FDR_ARC; then
        # Find directories, excluding version control and build folders
        readarray -t temp_items < <(find "$TDIR" "${FIND_OPTS[@]}" -type d \
            -not -path "$TDIR" \
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
    elif $UNP_FDR; then
        # Find archive files for unpacking
        readarray -t temp_items < <(find "$TDIR" "${FIND_OPTS[@]}" -type f \( \
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
        readarray -t temp_items < <(find "$TDIR" "${FIND_OPTS[@]}" -type f \( \
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

    # CRITICAL FIX: Check if array is empty before processing
    if (( ${#temp_items[@]} == 0 )); then
        [[ ! "$Q" == true ]] && echo "❌ No files found to process"
        return 1
    fi

    local total_found=${#temp_items[@]}
    [[ ! "$Q" == true ]] && echo "📁 Found $total_found potential items"
    [[ ! "$Q" == true ]] && echo "🔍 Debug: Found ${#temp_items[@]} items"
    [[ ! "$Q" == true ]] && printf "  • %s\n" "${temp_items[@]}"

    # Track processed multi-part archives to avoid duplicates
    local processed_multipart=()

    # Analyze each file/folder
    SC_RLTS=()
    for file in "${temp_items[@]}"; do ##1
        ((counter++))

        local basename=$(basename "$file")
        local size
        if $FDR_ARC; then
            size=$(du -sb "$file" 2>/dev/null | cut -f1)
            [[ -z "$size" ]] && size=0
        else
            size=$(get_size "$file")
        fi #1
        local size_formatted=$(fmt_size "$size")

        [[ ! "$Q" == true ]] && show_prog "$counter" "$total_found" "$basename" "Scanning" "$size_formatted"

        # Apply filters
        local should_process=true
        local skip_reason=""

        # Check exclude extensions first
        local file_ext="${basename##*.}"
        for exclude_ext in "${EXCL_EXT[@]}"; do ##2
            if [[ "${file_ext,,}" == "${exclude_ext,,}" ]]; then
                should_process=false
                skip_reason="excluded extension (.${exclude_ext})"
                break
            fi #2
        done ##2

        # Check exclude patterns
        if [[ "$should_process" == true ]]; then
            for exclude_pattern in "${EXCL_PATN[@]}"; do ##2
                if [[ "$basename" == $exclude_pattern ]]; then
                    should_process=false
                    skip_reason="excluded pattern ($exclude_pattern)"
                    break
                fi #2
            done ##2
        fi #1

        # Check if this is a multi-part RAR and if we've already processed the set
        if [[ "$should_process" == true ]] && is_multipart "$file"; then
            local first_part=$(get_first_part "$file")

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
            if (( MINS > 0 && size < MINS )); then
                should_process=false
                skip_reason="too small"
            elif (( MAXS > 0 && size > MAXS )); then
                should_process=false
                skip_reason="too large"
            fi #2
        fi #1

        # Pattern filtering
        if [[ "$should_process" == true && -n "$INCL" ]] && [[ ! "$basename" =~ $INCL ]]; then
            should_process=false
            skip_reason="doesn't match include pattern"
        fi #1

        # Exclude pattern check
        if [[ "$should_process" == true && -n "$EXCL" ]] && [[ "$basename" =~ $EXCL ]]; then
            should_process=false
            skip_reason="matches exclude pattern"
        fi #1

        # Check if file is already flagged as processed
        if [[ "$should_process" == true ]] && is_flagged "$file"; then
            should_process=false
            skip_reason="already processed (flagged)"
        fi #1

        # Skip already repacked files/folders - consolidated check
        if [[ "$should_process" == true ]]; then
            if $FDR_ARC; then
                # Skip folders that end with _archived
                if [[ "$basename" =~ _archived$ ]]; then
                    should_process=false
                    skip_reason="already archived"
                fi #2
            elif $FOLDERS_TO_ARCS; then
                # Alternative variable name check
                if [[ "$basename" =~ _archived$ ]]; then
                    should_process=false
                    skip_reason="already archived"
                fi #2
            else
                # Original archive check - consolidated
                if [[ "$file" =~ _repacked(\.new[0-9]*)?\.([7z|zip|tar\.(gz|xz|zst)|tar])$ ]] || [[ "$basename" =~ _repacked ]]; then
                    should_process=false
                    skip_reason="already repacked"
                fi #2
            fi #1
        fi #1

        # Check if already processed (resume)
        if [[ "$should_process" == true ]] && $RES && is_processed "$file"; then
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
            SKP_F+=("$file")
        fi #1
    done ##1

    # Cache scan results
    {
        echo "SC_RLTS=("
        printf "'%s'\n" "${SC_RLTS[@]}"
        echo ")"
        echo "TOT_F=$TOT_F"
        echo "O_SIZE=$O_SIZE"
        echo "SKP_F=("
        printf "'%s'\n" "${SKP_F[@]}"
        echo ")"
    } > "$S_CACHE"

    local scan_duration=$(($(date +%s) - scan_S_TIME))
    [[ ! "$Q" == true ]] && echo -e "\n✅ Scan completed in ${scan_duration}s"
    [[ ! "$Q" == true ]] && echo "📊 Files to process: $TOT_F"
    [[ ! "$Q" == true ]] && echo "📊 Files to skip: ${#SKP_F[@]}"
    [[ ! "$Q" == true ]] && echo "📊 Total size to process: $(fmt_size "$O_SIZE")"
} #closed scan_files

# Dependency checking
check_deps() {
    local missing_deps=()
    local optional_deps=()

    # Essential tools
    for cmd in find tar gzip; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_deps+=("$cmd")
        fi #1
    done ##1

    # Archiver-specific dependencies
    case "$ARC" in
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

    if (( ${#optional_deps[@]} )) && [[ ! "$Q" == true ]]; then
        echo "⚠️ Optional dependencies missing (some formats may not be supported):"
        printf "  • %s\n" "${optional_deps[@]}"
    fi #1
} #closed check_deps

# Check available disk space
check_space() {
    local target_dir="$1"
    local required_space_mb=$2
    
    local available_space=$(df -BM "$target_dir" | awk 'NR==2 {gsub(/M/, "", $4); print $4+0}')
    
    if (( available_space < required_space_mb )); then
        echo "❌ Insufficient disk space. Required: ${required_space_mb}MB, Available: ${available_space}MB"
        exit 1
    fi #1
} #closed check_space

# Estimate required space
est_space() {
    local total_size=0
    local current_size=0
    local max_size=0

    # Build find options for recursion
    local FIND_OPTS=()
    $REC || FIND_OPTS+=(-maxdepth 1)
    
    while IFS= read -r -d '' file; do
        if [[ -f "$file" ]]; then
            current_size=$(stat -c%s "$file")
            total_size=$((total_size + current_size))
            if (( current_size > max_size )); then
                max_size=$current_size
            fi #2
        fi #1
    done < <(find "$TDIR" "${FIND_OPTS[@]}" -type f \( \
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
    echo $((max_size * JOBS * 15 / 10 / 1024 / 1024))
} #closed est_space

# Progress indicator
show_progress() {
    local current=$1
    local total=$2
    local filename="$3"
    
    if [[ "$Q" == true ]]; then
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
verify_arc() {
    local archive="$1"
    local archiver="$2"
    
    case "$archiver" in
        7z) 7z t "$archive" >/dev/null 2>&1 ;;
        zip) zip -T "$archive" >/dev/null 2>&1 ;;
        zstd|xz|gz|tar) tar -tf "$archive" >/dev/null 2>&1 ;;
        *) return 0 ;;  # Skip verification for unknown formats
    esac
} #closed verify_arc

# Get file size in bytes
get_size() {
    stat -c%s "$1" 2>/dev/null || echo "0"
} #closed get_size

# Format file size
fmt_size() {
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
} #closed fmt_size

# Calculate compression ratio
calc_ratio() {
    local original=$1
    local compressed=$2
    
    if (( original == 0 )); then
        echo "0%"
        return
    fi #1
    
    local ratio=$((100 - (compressed * 100 / original)))
    echo "${ratio}%"
} #closed calc_ratio

# Resume functionality
save_state() {
    local processed_file="$1"
    echo "$processed_file" >> "$RSM_FIL"
} #closed save_state

is_processed() {
    local file="$1"
    [[ -f "$RSM_FIL" ]] && grep -Fxq "$file" "$RSM_FIL"
} #closed is_processed

# Generate output filename
gen_filename() {
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
} #closed gen_filename

# Enhanced compression progress with file size monitoring #vers 1
show_comp_prog() {
    local output_file="$1"
    local archiver="$2"
    local start_time=$(date +%s)
    
    if [[ "$Q" == true ]]; then
        return
    fi

    echo -n "📦 Compressing with $archiver"
    
    while true; do
        if [[ -f "$output_file" ]]; then
            local current_size=$(stat -c%s "$output_file" 2>/dev/null || echo "0")
            local elapsed=$(($(date +%s) - start_time))
            
            if (( current_size > 0 )); then
                local size_mb=$((current_size / 1048576))
                printf "\r📦 Compressing with $archiver: %dMB (${elapsed}s)" "$size_mb"
            else
                printf "\r📦 Compressing with $archiver (${elapsed}s)"
            fi
        else
            local elapsed=$(($(date +%s) - start_time))
            printf "\r📦 Compressing with $archiver (${elapsed}s)"
        fi
        
        sleep 1
        
        # Check if parent process is still running
        if ! kill -0 $PPID 2>/dev/null; then
            break
        fi
    done
} #closed show_comp_prog

# Enhanced extraction progress indicator #vers 1  
show_ext_prog() {
    local archive_file="$1"
    local target_dir="$2"
    local archiver="$3"
    local start_time=$(date +%s)
    
    if [[ "$Q" == true ]]; then
        return
    fi

    echo -n "📂 Extracting with $archiver"
    
    while true; do
        if [[ -d "$target_dir" ]]; then
            local file_count=$(find "$target_dir" -type f 2>/dev/null | wc -l)
            local elapsed=$(($(date +%s) - start_time))
            
            if (( file_count > 0 )); then
                printf "\r📂 Extracting with $archiver: %d files (${elapsed}s)" "$file_count"
            else
                printf "\r📂 Extracting with $archiver (${elapsed}s)"
            fi
        else
            local elapsed=$(($(date +%s) - start_time))
            printf "\r📂 Extracting with $archiver (${elapsed}s)"
        fi
        
        sleep 1
        
        # Check if parent process is still running
        if ! kill -0 $PPID 2>/dev/null; then
            break
        fi
    done
} #closed show_ext_prog

# Show archiving progress with dots #vers 1
show_arc_prog() {
    local archive_file="$1"
    local folder="$2"

    if [[ "$Q" == true ]]; then
        return
    fi

    echo -n "📦 Archiving"
    while [[ ! -f "$archive_file" ]] || kill -0 $! 2>/dev/null; do
        echo -n "."
        sleep 2
    done
    echo " ✅"
} #closed show_arc_prog

# Help function
autopak_help() {
    if [[ -f "_help" ]]; then
        source "_help"
        [[ ! "$Q" == true ]] && echo $_help
    fi #1
} #closed autopak_help

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
parse_args() {
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            -r|--recursive) REC=true ;;
            -d|--delete-original) DEL=true ;;
            -b|--backup-original) BUP=true ;;
            -n|--dry-run) DRY=true ;;
            -q|--quiet) Q=true ;;
            -v|--verify) VFY=true ;;
            -R|--resume) RES=true ;;
            -s|--save-config) save_cfg; exit 0 ;;
            -S|--single-file) SING_FIL=true ;;
            --scan-only) SCN=true ;;
            --repair-corrupted) REP_CRP=true ;;
            --keep-broken-files) KP_BRK=true ;;
            --ignore-corruption) IGN_COR=true ;;
            --folders-to-archives) FDR_ARC=true ;;
            --unpack-to-folders) UNP_FDR=true ;;
            --extract-multipart) EXT_MP=true ;;
            --use-btrfs-flags) BTRFS_FLG=true ;;
            --ignore-processed) IGN_PROC=true ;;
            --clear-flags) CLR_FLGS=true ;;
            --timeout) shift; OUTATIME="$1" ;;
            --cleanup-repacked) CLNUP_PKED=true ;;
            --check-duplicates) CHK_DUPS=true ;;
            --generate-checksums) GEN_CSUMS=true ;;
            --no-checksums) GEN_CSUMS=false ;;
            --checksum-db) shift; CHKSUM_DB="$1" ;;
            --password-file) shift; PWD_FILE="$1" ;;
            --password-vault) shift; PWD_VAULT="$1" ;;
            --encrypt-archives) ENCRYPT_ARC=true ;;
            --skip-passworded) SKP_PWD=true ;;
            --flag-passworded) FLAG_PWD=true ;;
            --passworded-log) shift; PWD_LOG="$1" ;;
            --secure-delete) SEC_DEL=true ;;
            --cpu-limit)
                shift
                CPU_LIM="$1"
                if ! [[ "$CPU_LIM" =~ ^[0-9]+$ ]] || (( CPU_LIM < 1 || CPU_LIM > 100 )); then
                    echo "❌ Invalid CPU limit: $CPU_LIM (must be 1-100)"
                    exit 1
                fi #1
                ;;
            --nice-level)
                shift
                NICE="$1"
                if ! [[ "$NICE" =~ ^-?[0-9]+$ ]] || (( NICE < -20 || NICE > 19 )); then
                    echo "❌ Invalid nice level: $NICE (must be -20 to 19)"
                    exit 1
                fi #1
                ;;
            -j|--jobs)
                shift
                JOBS="$1"
                if ! [[ "$JOBS" =~ ^[0-9]+$ ]] || (( JOBS < 1 )); then
                    echo "❌ Invalid job count: $JOBS"
                    exit 1
                fi #1
                ;;
            -a|--arch)
                shift
                ARC="$1"
                ;;
            -c|--compression)
                shift
                LVL="$1"
                ;;
            -c*)
                # Handle -c9, -c6, etc. (no space)
                LVL="${1#-c}"
                ;;
            -i|--include)
                shift
                INCL="$1"
                ;;
            -e|--exclude)
                shift
                EXCL="$1"
                ;;
            -m|--min-size)
                shift
                MINS=$(parse_size "$1")
                ;;
            -M|--max-size)
                shift
                MAXS=$(parse_size "$1")
                ;;
            -C|--config)
                shift
                CFG="$1"
                ;;
            -h|--help)
                autopak_help
                exit 0
                ;;
            -*)
                echo "❌ Unknown option: $1"
                echo "Use -h or --help for usage information"
                exit 1
                ;;
            *)
                TDIR="$1"
                ;;
        esac # in "$1"
        shift
    done ##1
} #closed parse_args

# Initialize logging
init_log() {
    if [[ ! "$Q" == true ]]; then
        exec > >(tee -a "$LOGFILE") 2>&1
    else
        exec 2>> "$LOGFILE"
    fi #1
} #closed init_log

# CRITICAL FIX: Secure file deletion - REMOVED INFINITE RECURSION
sec_delete() {
    local file="$1"

    if [[ ! "$SEC_DEL" == true ]] || [[ ! -f "$file" ]]; then
        rm -f "$file" 2>/dev/null  # FIXED: Use rm instead of recursive call
        return 0
    fi #1

    [[ ! "$Q" == true ]] && echo "🔒 Securely deleting: $(basename "$file")"

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
        rm -f "$file" 2>/dev/null  # FIXED: Use rm instead of recursive call
    fi #1

    [[ ! "$Q" == true ]] && echo "✅ Secure deletion completed"
} #closed sec_delete

# BTRFS extended attribute functions #vers 1
set_flag() {
    local file="$1"

    if [[ ! "$BTRFS_FLG" == true ]]; then
        return 0
    fi

    if command -v setfattr &> /dev/null; then
        setfattr -n user.autopak.processed -v "true" "$file" 2>/dev/null
        setfattr -n user.autopak.date -v "$(date -Iseconds)" "$file" 2>/dev/null
        setfattr -n user.autopak.version -v "1.0" "$file" 2>/dev/null
    fi
} #closed set_flag

# Check if file has processed flag #vers 1
is_flagged() {
    local file="$1"

    if [[ ! "$BTRFS_FLG" == true ]] || [[ ! "$IGN_PROC" == true ]]; then
        return 1  # Not flagged
    fi

    if command -v getfattr &> /dev/null; then
        local flag_value=$(getfattr -n user.autopak.processed --only-values "$file" 2>/dev/null)
        [[ "$flag_value" == "true" ]]
    else
        return 1  # Can't check, assume not flagged
    fi
} #closed is_flagged

# Generate checksum file and store in database #vers 1
gen_checksum() {
    local archive_file="$1"
    local operation_type="$2"

    if [[ ! "$GEN_CSUMS" == true ]] || [[ ! -f "$archive_file" ]]; then
        return 0
    fi

    local checksum_file="${archive_file}.txt"
    local filename=$(basename "$archive_file")
    local filesize=$(get_size "$archive_file")
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
        echo "Size: $filesize bytes ($(fmt_size "$filesize"))"
        echo "SHA256: $sha256_hash"
        echo "MD5: $md5_hash"
        echo "Date: $current_date"
        echo "Operation: $operation_type"
    } > "$checksum_file"

    [[ ! "$Q" == true ]] && echo "📋 Generated checksum: $(basename "$checksum_file")"
} #closed gen_checksum

# Main processing function
proc_arc() {
    local file="$1"
    local current_num="$2"
    local total_num="$3"

    local basename=$(basename "$file")
    if [[ "$basename" =~ _repacked ]]; then
        [[ ! "$Q" == true ]] && echo "⏩ Skipping already repacked: $basename"
        save_state "$file"
        PROC_F=$((PROC_F + 1))
        return 0
    fi
    local ext="${basename##*.}"
    local stripped_name="${basename%.*}"
    local tmp_dir="$WORK_DIR/${stripped_name}_$_$current_num"
    local o_size=$(get_size "$file")

    # Check if already processed (resume functionality)
    if $RES && is_processed "$file"; then
        [[ ! "$Q" == true ]] && echo "⏩ Already processed: $(basename "$file")"
        return 0
    fi #1

    # Size filtering
    if (( MINS > 0 && o_size < MINS )); then
        [[ ! "$Q" == true ]] && echo "⏩ Skipping (too small): $basename"
        SKP_F+=("$file")
        return 0
    fi #1
    
    if (( MAXS > 0 && o_size > MAXS )); then
        [[ ! "$Q" == true ]] && echo "⏩ Skipping (too large): $basename"
        SKP_F+=("$file")
        return 0
    fi #1
    
    # Pattern filtering
    if [[ -n "$INCL" ]] && [[ ! "$basename" =~ $INCL ]]; then
        [[ ! "$Q" == true ]] && echo "⏩ Skipping (not matching include pattern): $basename"
        SKP_F+=("$file")
        return 0
    fi #1
    
    if [[ -n "$EXCL" ]] && [[ "$basename" =~ ${EXCL,,} ]]; then
        [[ ! "$Q" == true ]] && echo "⏩ Skipping (matching exclude pattern): $basename"
        SKP_F+=("$file")
        return 0
    fi #1
    
    # Skip already repacked files
    if [[ "$file" =~ _repacked(\.new[0-9]*)?\.([7z|zip|tar\.(gz|xz|zst)|tar])$ ]]; then
        [[ ! "$Q" == true ]] && echo "⏩ Skipping already repacked: $basename"
        SKP_F+=("$file")
        return 0
    fi #1
    
    mkdir -p "$tmp_dir"
    
    [[ ! "$Q" == true ]] && show_progress "$current_num" "$total_num" "$basename"
    [[ ! "$Q" == true ]] && echo -e "\n➡️ Processing: $basename ($(fmt_size "$o_size"))"

    # Create backup if requested
    if $BUP && [[ ! "$DRY" == true ]]; then
        local backup_file="${file}.backup"
        cp "$file" "$backup_file"
        [[ ! "$Q" == true ]] && echo "💾 Created backup: $backup_file"
    fi #1

    # Special handling for multi-part archives and repair
    local extract_success=true
    local is_multipart=false
    local multipart_folder=""
    local repair_attempted=false
    local using_repaired=false
    local current_file="$file"
    
    # Check if repair is needed and attempt it
    if $REP_CRP && [[ "$ext" =~ ^(rar|r[0-9]+)$ || "$basename" =~ \.(part[0-9]+\.rar|part[0-9]+)$ ]]; then
        if is_corrupt "$file"; then
            [[ ! "$Q" == true ]] && echo "⚠️ Corrupted RAR detected: $(basename "$file")"
            local repair_dir="$tmp_dir/repair_temp"
            local repaired_file=$(repair_rar "$file" "$repair_dir")
            
            if [[ -n "$repaired_file" && -e "$repaired_file" ]]; then
                if [[ -d "$repaired_file" ]]; then
                    # Repaired content is in a directory (broken extraction)
                    [[ ! "$Q" == true ]] && echo "✅ Using repaired content from: $(basename "$repaired_file")"
                    tmp_dir="$repaired_file"
                    repair_attempted=true
                    using_repaired=true
                    extract_success=true
                else
                    # Repaired file is a new archive
                    [[ ! "$Q" == true ]] && echo "✅ Using repaired archive: $(basename "$repaired_file")"
                    current_file="$repaired_file"
                    repair_attempted=true
                    using_repaired=true
                fi #4
            else
                [[ ! "$Q" == true ]] && echo "❌ RAR repair failed, will attempt normal extraction"
                repair_attempted=true
            fi #3
        fi #2
    fi #1
    
    # Skip extraction if we already have repaired content in tmp_dir
    if [[ "$using_repaired" == true && -d "$tmp_dir" && "$(ls -A "$tmp_dir")" ]]; then
        extract_success=true
    else
        # Check if this is a multi-part RAR and handle accordingly
        if is_multipart "$current_file"; then
            is_multipart=true
            local first_part=$(get_first_part "$current_file")
            
            if $EXT_MP; then
                # Create a dedicated folder for multi-part extraction
                local archive_name="${basename%.*}"
                # Remove part numbers from folder name
                archive_name=$(echo "$archive_name" | sed -E 's/\.(part[0-9]+|r[0-9]+|part[0-9]+)$//')
                multipart_folder="$tmp_dir/${archive_name}_extracted"
                mkdir -p "$multipart_folder"
                [[ ! "$Q" == true ]] && echo "📁 Extracting multi-part RAR to: $(basename "$multipart_folder")"
                
                # Extract using the first part
                show_ext_prog "$first_part" "$multipart_folder" "unrar" &
                local extract_pid=$!
                if $KP_BRK; then
                    unrar x -kb -inul "$first_part" "$multipart_folder/" 2>/dev/null || \
                    7z x -bd -y -o"$multipart_folder" "$first_part" >/dev/null 2>&1 || \
                    extract_success=false
                else
                    unrar x -inul "$first_part" "$multipart_folder/" 2>/dev/null || \
                    7z x -bd -y -o"$multipart_folder" "$first_part" >/dev/null 2>&1 || \
                    extract_success=false
                fi #4 -1
                kill $extract_pid 2>/dev/null
                wait $extract_pid 2>/dev/null
                [[ ! "$Q" == true ]] && echo -e "\n"
                
                # Set extraction directory to the multipart folder
                tmp_dir="$multipart_folder"
            else
                # Standard extraction to temporary directory
                [[ ! "$Q" == true ]] && echo "📦 Processing multi-part RAR: $basename"
                show_ext_prog "$first_part" "$tmp_dir" "unrar" &
                local extract_pid=$!
                if $KP_BRK; then
                    unrar x -kb -inul "$first_part" "$tmp_dir/" 2>/dev/null || \
                    7z x -bd -y -o"$tmp_dir" "$first_part" >/dev/null 2>&1 || \
                    extract_success=false
                else
                    unrar x -inul "$first_part" "$tmp_dir/" 2>/dev/null || \
                    7z x -bd -y -o"$tmp_dir" "$first_part" >/dev/null 2>&1 || \
                    extract_success=false
                fi #4 -2
                kill $extract_pid 2>/dev/null
                wait $extract_pid 2>/dev/null
                [[ ! "$Q" == true ]] && echo -e "\n"
            fi #3 -1
        else
            # Standard extraction handler for non-multipart archives
        case "$ext" in
            zip|ZIP)
                show_ext_prog "$current_file" "$tmp_dir" "unzip" &
                local extract_pid=$!
                if ! unzip -qq "$current_file" -d "$tmp_dir" 2>/dev/null && \
                ! unzip -j -qq "$current_file" -d "$tmp_dir" 2>/dev/null && \
                ! 7z x -bd -y -o"$tmp_dir" "$current_file" >/dev/null 2>&1; then
                    extract_success=false
                fi
                kill $extract_pid 2>/dev/null
                wait $extract_pid 2>/dev/null
                [[ ! "$Q" == true ]] && echo -e "\n"
                ;;
            rar)
                show_ext_prog "$current_file" "$tmp_dir" "unrar" &
                local extract_pid=$!
                if $KP_BRK; then
                    if ! unrar x -kb -inul "$current_file" "$tmp_dir/" 2>/dev/null && \
                    ! 7z x -bd -y -o"$tmp_dir" "$current_file" >/dev/null 2>&1; then
                        extract_success=false
                    fi
                else
                    if ! unrar x -inul "$current_file" "$tmp_dir/" 2>/dev/null && \
                    ! 7z x -bd -y -o"$tmp_dir" "$current_file" >/dev/null 2>&1; then
                        extract_success=false
                    fi
                fi
                kill $extract_pid 2>/dev/null
                wait $extract_pid 2>/dev/null
                [[ ! "$Q" == true ]] && echo -e "\n"
                ;;
            7z|exe)
                show_ext_prog "$current_file" "$tmp_dir" "7z" &
                local extract_pid=$!
                if ! 7z x -bd -y -o"$tmp_dir" "$file" >/dev/null 2>&1; then
                    extract_success=false
                fi
                kill $extract_pid 2>/dev/null
                wait $extract_pid 2>/dev/null
                [[ ! "$Q" == true ]] && echo -e "\n"
                ;;
            tar)
                show_ext_prog "$current_file" "$tmp_dir" "tar" &
                local extract_pid=$!
                tar -xf "$file" -C "$tmp_dir" 2>/dev/null || extract_success=false
                kill $extract_pid 2>/dev/null
                wait $extract_pid 2>/dev/null
                [[ ! "$Q" == true ]] && echo -e "\n"
                ;;
            tgz|gz) 
                if [[ "$basename" == *.tar.gz ]] || [[ "$basename" == *.tgz ]]; then
                    tar -xzf "$file" -C "$tmp_dir" 2>/dev/null || extract_success=false
                else
                    gunzip -c "$file" > "$tmp_dir/${stripped_name}" 2>/dev/null || extract_success=false
                fi #3 -2
                ;;
            xz) 
                if [[ "$basename" == *.tar.xz ]]; then
                    tar -xJf "$file" -C "$tmp_dir" 2>/dev/null || extract_success=false
                else
                    unxz -c "$file" > "$tmp_dir/${stripped_name}" 2>/dev/null || extract_success=false
                fi #3 -3
                ;;
            bz2) 
                if [[ "$basename" == *.tar.bz2 ]]; then
                    tar -xjf "$file" -C "$tmp_dir" 2>/dev/null || extract_success=false
                else
                    bunzip2 -c "$file" > "$tmp_dir/${stripped_name}" 2>/dev/null || extract_success=false
                fi #3 -4
                ;;
            zst) 
                if [[ "$basename" == *.tar.zst ]]; then
                    tar --use-compress-program=unzstd -xf "$file" -C "$tmp_dir" 2>/dev/null || extract_success=false
                else
                    zstd -d -c "$file" > "$tmp_dir/${stripped_name}" 2>/dev/null || extract_success=false
                fi #3 -5
                ;;
            lzh|lha) 
                lha xqf "$file" "$tmp_dir" 2>/dev/null || \
                lhasa x "$file" -C "$tmp_dir" 2>/dev/null || \
                7z x -bd -y -o"$tmp_dir" "$file" >/dev/null 2>&1 || \
                extract_success=false
                ;;
            cab) 
                cabextract -d "$tmp_dir" "$file" >/dev/null 2>&1 || \
                7z x -bd -y -o"$tmp_dir" "$file" >/dev/null 2>&1 || \
                extract_success=false
                ;;
            iso|img|dd)
                7z x -bd -y -o"$tmp_dir" "$file" >/dev/null 2>&1 || extract_success=false
                ;;
            deb)
                dpkg-deb -x "$file" "$tmp_dir" 2>/dev/null || \
                (ar x "$file" 2>/dev/null && \
                tar -xf data.tar.* -C "$tmp_dir" 2>/dev/null) || \
                extract_success=false
                ;;
            r[0-9]*|part[0-9]*)
                # Handle remaining multi-part files that weren't caught earlier
                local first_part=$(get_first_part "$file")
                unrar x -inul "$first_part" "$tmp_dir/" 2>/dev/null || \
                7z x -bd -y -o"$tmp_dir" "$first_part" >/dev/null 2>&1 || \
                extract_success=false
                ;;
            *)
                [[ ! "$Q" == true ]] && echo "❓ Unsupported extension: $ext"
                extract_success=false
                ;;
        esac # in "$ext"
        fi #2
    fi #1

    if [[ "$extract_success" != true ]]; then
        if $IGN_COR; then
            [[ ! "$Q" == true ]] && echo "⚠️ Extraction failed but continuing due to --ignore-corruption: $basename"
            FAIL_F+=("$file")
            rm -rf "$tmp_dir"
            [[ -n "$multipart_folder" && -d "$multipart_folder" ]] && rm -rf "$multipart_folder"
            return 0  # Return success to continue processing
        else
            [[ ! "$Q" == true ]] && echo "❌ Failed to extract: $basename"
            FAIL_F+=("$file")
            rm -rf "$tmp_dir"
            [[ -n "$multipart_folder" && -d "$multipart_folder" ]] && rm -rf "$multipart_folder"
            return 1  # Return failure to stop processing
        fi #2
    fi #1

    # Check if extraction resulted in any files
    if [[ ! "$(ls -A "$tmp_dir")" ]]; then
        [[ ! "$Q" == true ]] && echo "❌ Empty archive: $basename"
        FAIL_F+=("$file")
        rm -rf "$tmp_dir"
        [[ -n "$multipart_folder" && -d "$multipart_folder" ]] && rm -rf "$multipart_folder"
        return 1
    fi #1

    # For multi-part extraction mode, we're done - just leave the extracted folder
    if $EXT_MP && [[ "$is_multipart" == true ]]; then
        [[ ! "$Q" == true ]] && echo "✅ Multi-part archive extracted to: $(basename "$tmp_dir")"
        save_state "$file"
        PROC_F=$((PROC_F + 1))
        return 0
    fi #1

    # Determine output filename
    local new_archive
    case "$ARC" in
        7z) new_archive=$(gen_filename "${file%.*}" "7z") ;;
        zip) new_archive=$(gen_filename "${file%.*}" "zip") ;;
        zstd) new_archive=$(gen_filename "${file%.*}" "tar.zst") ;;
        xz) new_archive=$(gen_filename "${file%.*}" "tar.xz") ;;
        gz) new_archive=$(gen_filename "${file%.*}" "tar.gz") ;;
        tar) new_archive=$(gen_filename "${file%.*}" "tar") ;;
    esac # in "$ARC"

    if $DRY; then
        [[ ! "$Q" == true ]] && echo "💡 Would repack: $basename → $(basename "$new_archive")"
        if $DEL; then
            [[ ! "$Q" == true ]] && echo "💡 Would delete original: $basename"
        fi #2 -1
    else
        [[ ! "$Q" == true ]] && echo "📦 Repacking to: $(basename "$new_archive")"
        local repack_success=true
        
        # Set compression level
        local comp_opts=""
        if [[ -n "$LVL" ]]; then
            case "$ARC" in
                7z) comp_opts="-mx=$LVL" ;;
                zip) comp_opts="-$LVL" ;;
                zstd) comp_opts="-$LVL" ;;
                xz) comp_opts="-$LVL" ;;
                gz) comp_opts="-$LVL" ;;
            esac
        fi #2 -2
        
        case "$ARC" in
            7z)
                show_comp_prog "$new_archive" "7z" &
                local progress_pid=$!
                7z a -t7z ${comp_opts:-"-mx=9"} -m0=lzma2 "$new_archive" "$tmp_dir"/* >/dev/null 2>&1 || repack_success=false
                kill $progress_pid 2>/dev/null
                wait $progress_pid 2>/dev/null
                [[ ! "$Q" == true ]] && echo -e "\n"
                ;;
            zip)
                show_comp_prog "$new_archive" "zip" &
                local progress_pid=$!
                (cd "$tmp_dir" && zip -r ${comp_opts:-"-9"} -q "$new_archive" * 2>/dev/null) || repack_success=false
                kill $progress_pid 2>/dev/null
                wait $progress_pid 2>/dev/null
                [[ ! "$Q" == true ]] && echo -e "\n"
                ;;
            zstd)
                show_comp_prog "$new_archive" "zstd" &
                local progress_pid=$!
                tar -C "$tmp_dir" -cf - . | zstd ${comp_opts:-"-19"} -T0 -o "$new_archive" 2>/dev/null || repack_success=false
                kill $progress_pid 2>/dev/null
                wait $progress_pid 2>/dev/null
                [[ ! "$Q" == true ]] && echo -e "\n"
                ;;
            xz)
                show_comp_prog "$new_archive" "xz" &
                local progress_pid=$!
                tar -C "$tmp_dir" -cf - . | xz ${comp_opts:-"-9"} -c > "$new_archive" 2>/dev/null || repack_success=false
                kill $progress_pid 2>/dev/null
                wait $progress_pid 2>/dev/null
                [[ ! "$Q" == true ]] && echo -e "\n"
                ;;
            gz)
                show_comp_prog "$new_archive" "gz" &
                local progress_pid=$!
                tar -C "$tmp_dir" -c${comp_opts:-"z"}f "$new_archive" . 2>/dev/null || repack_success=false
                kill $progress_pid 2>/dev/null
                wait $progress_pid 2>/dev/null
                [[ ! "$Q" == true ]] && echo -e "\n"
                ;;
            tar)
                show_comp_prog "$new_archive" "tar" &
                local progress_pid=$!
                tar -C "$tmp_dir" -cf "$new_archive" . 2>/dev/null || repack_success=false
                kill $progress_pid 2>/dev/null
                wait $progress_pid 2>/dev/null
                [[ ! "$Q" == true ]] && echo -e "\n"
                ;;
        esac # in "$ARC"

        if [[ "$repack_success" != true ]]; then
            [[ ! "$Q" == true ]] && echo "❌ Failed to repack: $basename"
            FAIL_F+=("$file")
            rm -rf "$tmp_dir"
            [[ -n "$multipart_folder" && -d "$multipart_folder" ]] && rm -rf "$multipart_folder"
            return 1
        fi #2 -3

        # Verify repacked archive if requested
        if $VFY; then
            if ! verify_arc "$new_archive" "$ARC"; then
                [[ ! "$Q" == true ]] && echo "❌ Archive verification failed: $(basename "$new_archive")"
                FAIL_F+=("$file")
                rm -f "$new_archive"
                rm -rf "$tmp_dir"
                [[ -n "$multipart_folder" && -d "$multipart_folder" ]] && rm -rf "$multipart_folder"
                return 1
            fi
            [[ ! "$Q" == true ]] && echo "✅ Archive verified: $(basename "$new_archive")"
        fi #2 -4

        # Calculate and display compression statistics
        local new_size=$(get_size "$new_archive")
        local compression_ratio=$(calc_ratio "$o_size" "$new_size")
        
        REP_SIZE=$((REP_SIZE + new_size))
        
        [[ ! "$Q" == true ]] && echo "📊 Size: $(fmt_size "$o_size") → $(fmt_size "$new_size") (${compression_ratio} compression)"

        # Handle original file
        if $DEL; then
            [[ ! "$Q" == true ]] && echo "🗑️ Deleting original: $basename"
            sec_delete "$file"
            
            # For multi-part RAR files, also delete the related parts
            if [[ "$is_multipart" == true ]]; then
                local dir=$(dirname "$file")
                local basename_no_ext=$(basename "$file")
                
                # Remove different multi-part file patterns
                if [[ "$basename_no_ext" =~ ^(.*)\.part[0-9]+\.rar$ ]]; then
                    local base_name="${BASH_REMATCH[1]}"
                    rm -f "$dir/${base_name}".part*.rar 2>/dev/null
                    [[ ! "$Q" == true ]] && echo "🗑️ Deleted multi-part RAR set: ${base_name}.part*.rar"
                elif [[ "$basename_no_ext" =~ ^(.*)\.rar$ ]]; then
                    local base_name="${BASH_REMATCH[1]}"
                    rm -f "$dir/${base_name}".r[0-9]* 2>/dev/null
                    [[ ! "$Q" == true ]] && echo "🗑️ Deleted multi-part RAR set: ${base_name}.r*"
                elif [[ "$basename_no_ext" =~ ^(.*)\.part[0-9]+$ ]]; then
                    local base_name="${BASH_REMATCH[1]}"
                    rm -f "$dir/${base_name}".part[0-9]* 2>/dev/null
                    [[ ! "$Q" == true ]] && echo "🗑️ Deleted multi-part set: ${base_name}.part*"
                fi #4
            fi #3
        fi #2
    fi #1

    # Clean up temporary directory
    rm -rf "$tmp_dir"
    [[ -n "$multipart_folder" && -d "$multipart_folder" ]] && rm -rf "$multipart_folder"
    
    # Save resume state
    save_state "$file"
    
    PROC_F=$((PROC_F + 1))
    [[ ! "$Q" == true ]] && echo "✅ Done: $basename"
    
    gen_checksum "$new_archive" "archive_creation"

    # Set processed flag
    set_flag "$file"

    return 0
} #closed proc_arc

# Export function for use in parallel processing
export -f proc_arc
export -f get_size
export -f fmt_size
export -f calc_ratio
export -f verify_arc
export -f gen_filename
export -f save_state
export -f is_processed
export -f is_multipart
export -f get_first_part
export -f repair_rar
export -f is_corrupt
export -f gen_checksum
export -f set_flag
export -f is_flagged
export -f sec_delete
export -f show_comp_prog
export -f show_ext_prog
export -f show_arc_prog
export IGN_COR

# Main execution

fatal_error() { #left outside
    echo "❌ Error: $1"
    [[ -n "$2" ]] && echo "💡 $2"
    exit 1
} #1

# Main execution
main() {
    # Save original argument count before parsing
    local original_arg_count=$#

    load_cfg
    parse_args "$@"
    init_log

    if $SING_FIL; then
        if [[ ! -f "$TDIR" ]]; then
            echo "❌ Error: File '$TDIR' doesn't exist or is not accessible"
            exit 1
        fi #2
        echo "🎯 Single file mode: $(basename "$TDIR")"
        INCL="^$(basename "$TDIR")$"
        TDIR=$(dirname "$TDIR")
    fi #1

    # Handle flag clearing
    if $CLR_FLGS; then
        echo "🧹 Clearing AutoPak processing flags..."
        local cleared_count=0
        local FIND_OPTS=()
        $REC || FIND_OPTS+=(-maxdepth 1)

        while IFS= read -r -d '' file; do
            if command -v setfattr &> /dev/null; then
                setfattr -x user.autopak.processed "$file" 2>/dev/null && ((cleared_count++))
                setfattr -x user.autopak.date "$file" 2>/dev/null
                setfattr -x user.autopak.version "$file" 2>/dev/null
            fi
        done < <(find "$TDIR" "${FIND_OPTS[@]}" -type f -print0)

        [[ ! "$Q" == true ]] && echo "✅ Cleared flags from $cleared_count files"
        exit 0
    fi

    # Validate inputs - handle different error scenarios
    if [[ $original_arg_count -eq 0 ]]; then
        autopak_help
        exit 1
    fi #1

    if [[ -z "$TDIR" ]]; then
        echo "❌ Error: No directory specified"
        echo "💡 Usage: $(basename "$0") [OPTIONS] <directory>"
        exit 1
    fi #1

    if [[ ! -d "$TDIR" ]]; then
        echo "❌ Error: Directory '$TDIR' doesn't exist or is not accessible"
        echo "💡 Please check the path and try again"
        exit 1
    fi #1

    # Validate archiver
    case "$ARC" in
        7z|zip|zstd|xz|gz|tar) ;;
        *) echo "❌ Invalid archiver: $ARC"; exit 2 ;;
    esac # in "$ARC"

    check_deps
    setup_cpu

    mkdir -p "$WORK_DIR"
    scan_files

    # Early exit for scan-only mode
    if $SCN; then
        echo
        echo "📋 Scan Results Summary:"
        echo "========================"
        echo "📁 Total files found: $((TOT_F + ${#SKP_F[@]}))"
        echo "✅ Files to process: $TOT_F"
        echo "⏩ Files to skip: ${#SKP_F[@]}"
        echo "📊 Total size to process: $(fmt_size "$O_SIZE")"

        if (( ${#SKP_F[@]} > 0 )) && [[ ! "$Q" == true ]]; then
            echo
            echo "⏩ Skipped files:"
            for result in "${SC_RLTS[@]}"; do
                IFS='|' read -r file size action reason <<< "$result"
                if [[ "$action" == "skip" ]]; then
                    echo "  • $(basename "$file") ($(fmt_size "$size")) - $reason"
                fi #3
            done ##1
        fi #2

        echo
        echo "💡 Use without --scan-only to process these files"
        cleanup_exit
        return
    fi #1

    if (( TOT_F == 0 )); then
        echo "❌ No archive files to process after filtering"
        exit 1
    fi #1

    # Check disk space
    if [[ ! "$DRY" == true ]]; then
        local estimated_space=$(est_space)
        check_space "$TDIR" "$estimated_space"
    fi #1

    # Display configuration
    if [[ ! "$Q" == true ]]; then
        echo
        echo "📋 Processing Configuration:"
        echo "============================="
        echo "🔍 Target directory: $TDIR"
        echo "📦 Archiver: $ARC"
        echo "🔄 Recursive: $REC"
        echo "🗑️ Delete original: $DEL"
        echo "💾 Backup original: $BUP"
        echo "✅ Verify archives: $VFY"
        echo "📁 Extract multi-part: $EXT_MP"
        echo "🔧 Repair corrupted: $REP_CRP"
        echo "🛠️ Keep broken files: $KP_BRK"
        echo "🚫 Ignore corruption: $IGN_COR"
        echo "💡 Dry run: $DRY"
        echo "🔇 Quiet mode: $Q"
        echo "⚡ Parallel jobs: $JOBS"
        [[ $CPU_LIM -gt 0 ]] && echo "🔧 CPU limit: ${CPU_LIM}%"
        [[ $NICE -ne 0 ]] && echo "🔧 Nice level: $NICE"
        [[ -n "$LVL" ]] && echo "📊 Compression level: $LVL"
        [[ -n "$INCL" ]] && echo "🎯 Include pattern: $INCL"
        [[ -n "$EXCL" ]] && echo "🚫 Exclude pattern: $EXCL"
        [[ $MINS -gt 0 ]] && echo "📏 Min size: $(fmt_size "$MINS")"
        [[ $MAXS -gt 0 ]] && echo "📏 Max size: $(fmt_size "$MAXS")"
        echo "📝 Log file: $LOGFILE"
        echo "📁 Files to process: $TOT_F"
        echo "📊 Total size: $(fmt_size "$O_SIZE")"

        # Show exclude config status
        if (( ${#EXCL_EXT[@]} > 0 )); then
            echo "🚫 Excluding extensions: ${EXCL_EXT[*]}"
        fi
        if (( ${#EXCL_PATN[@]} > 0 )); then
            echo "🚫 Excluding patterns: ${EXCL_PATN[*]}"
        fi
        echo
    fi #1

    # Phase 2: Process files
    C_PHSE="Processing files"
    [[ ! "$Q" == true ]] && echo "🔄 Phase 2: Processing archive files..."

    # Create processing queue from scan results
    local processing_queue=()
    for result in "${SC_RLTS[@]}"; do
        IFS='|' read -r file size action reason <<< "$result"
        if [[ "$action" == "process" ]]; then
            processing_queue+=("$file")
        fi #1
    done

    # Process files
    if (( JOBS > 1 )); then
        # Parallel processing using xargs with proper environment
        printf '%s\n' "${processing_queue[@]}" | \
        WORK_DIR="$WORK_DIR" \
        ARC="$ARC" \
        LVL="$LVL" \
        DEL="$DEL" \
        BUP="$BUP" \
        VFY="$VFY" \
        EXT_MP="$EXT_MP" \
        REP_CRP="$REP_CRP" \
        KP_BRK="$KP_BRK" \
        DRY="$DRY" \
        Q="$Q" \
        RES="$RES" \
        RSM_FIL="$RSM_FIL" \
        MINS="$MINS" \
        MAXS="$MAXS" \
        INCL="$INCL" \
        EXCL="$EXCL" \
        SKP_F="$SKP_F" \
        FAIL_F="$FAIL_F" \
        IGN_COR="$IGN_COR" \
        PROC_F="$PROC_F" \
        REP_SIZE="$REP_SIZE" \
        WORK_DIR="$WORK_DIR" \
        UNP_FDR="$UNP_FDR" \
        xargs -P "$JOBS" -I {} bash -c 'proc_arc "{}" 1 '"$TOT_F"
    else
        # Sequential processing
        local counter=0
        for item in "${processing_queue[@]}"; do
            ((counter++))
            proc_arc "$item" "$counter" "$TOT_F"
        done
    fi #1

    # Cleanup
    rm -rf "$WORK_DIR"
    [[ -f "$RSM_FIL" ]] && rm -f "$RSM_FIL"
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
    echo "📁 Total files found: $((TOT_F + ${#SKP_F[@]}))"
    echo "✅ Successfully processed: $PROC_F"
    echo "❌ Failed: ${#FAIL_F[@]}"
    echo "⏩ Skipped: ${#SKP_F[@]}"

    if (( PROC_F > 0 )) && [[ ! "$DRY" == true ]]; then
        echo "📊 Original total size: $(fmt_size "$O_SIZE")"
        echo "📊 Repacked total size: $(fmt_size "$REP_SIZE")"
        local total_ratio=$(calc_ratio "$O_SIZE" "$REP_SIZE")
        echo "📊 Overall compression: $total_ratio"
        local space_saved=$((O_SIZE - REP_SIZE))
        echo "💾 Space saved: $(fmt_size "$space_saved")"
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

    if (( ${#SKP_F[@]} )) && [[ ! "$Q" == true ]]; then
        echo
        echo "⏩ Skipped files:"
        printf "  • %s\n" "${SKP_F[@]}"
    fi #1

    echo
    echo "📝 Complete log saved to: $LOGFILE"

    # Exit with error code if any files failed
    if (( ${#FAIL_F[@]} )); then
        exit 1
    fi #1

} #closed main

# Call main function with all arguments
main "$@"
