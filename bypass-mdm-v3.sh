#!/bin/bash
set -euo pipefail

# ═══════════════════════════════════════════════════════════════
#  Bypass MDM v3 - By Assaf Dori (assafdori.com)
#  Enhanced with resilience, persistence, and safety features
# ═══════════════════════════════════════════════════════════════

# ── Color codes ──
RED='\033[1;31m'
GRN='\033[1;32m'
BLU='\033[1;34m'
YEL='\033[1;33m'
PUR='\033[1;35m'
CYAN='\033[1;36m'
NC='\033[0m'

# ── Constants ──
VERSION="3.2.0"
LOG_FILE="/tmp/mdm-bypass.log"
BACKUP_DIR="/tmp/mdm-bypass-backup"
LOCK_DIR="/tmp/mdm-bypass.lock"
JOURNAL_FILE="/tmp/mdm-bypass.journal"
TOTAL_STEPS=11
CURRENT_STEP=0
LAUNCHDAEMON_LABEL="com.bypass.mdmguardian"
GUARDIAN_SCRIPT_PATH="Library/Scripts/mdmguardian.sh"

# Expanded MDM domains (v2 had 3, v3 has 8)
MDM_DOMAINS=(
	"deviceenrollment.apple.com"
	"mdmenrollment.apple.com"
	"iprofiles.apple.com"
	"acmdm.apple.com"
	"albert.apple.com"
	"gateway.push.apple.com"
	"setup.icloud.com"
	"identity.apple.com"
)

# MDM daemon identifiers to disable
MDM_DAEMONS=(
	"com.apple.mdmclient.daemon"
	"com.apple.ManagedClient.enroll"
	"com.apple.ManagedClient.cloudconfigurationd"
	"com.apple.cloudconfigurationd"
	"com.apple.mdmclient.daemon.runatboot"
)

MDM_AGENTS=(
	"com.apple.mdmclient.agent"
	"com.apple.ManagedClient.agent"
)

# ── State variables ──
DRY_RUN=false
declare -a COMPLETED_ACTIONS=()
ORIGINAL_DATA_VOLUME=""

# ═══════════════════════════════════════════════════════════════
#  Output & Logging
# ═══════════════════════════════════════════════════════════════

init_log() {
	if $DRY_RUN; then
		return
	fi
	echo "═══════════════════════════════════════════════════" >"$LOG_FILE"
	echo "MDM Bypass v$VERSION - $(date '+%Y-%m-%d %H:%M:%S')" >>"$LOG_FILE"
	echo "Hostname: $(hostname 2>/dev/null || echo 'unknown')" >>"$LOG_FILE"
	echo "═══════════════════════════════════════════════════" >>"$LOG_FILE"
}

log() {
	local level="$1"
	local message="$2"
	if $DRY_RUN; then
		echo "[$(date '+%H:%M:%S')] [DRY-RUN] [$level] $message" >>"$LOG_FILE" 2>/dev/null || true
	else
		echo "[$(date '+%H:%M:%S')] [$level] $message" >>"$LOG_FILE" 2>/dev/null || true
	fi
}

error_exit() {
	trap '' ERR
	log "ERROR" "$1"
	echo -e "${RED}ERROR: $1${NC}" >&2
	if [ ${#COMPLETED_ACTIONS[@]} -gt 0 ]; then
		offer_rollback
	fi
	exit 1
}

warn() {
	log "WARN" "$1"
	echo -e "${YEL}WARNING: $1${NC}"
}

success() {
	log "SUCCESS" "$1"
	echo -e "${GRN}✓ $1${NC}"
}

info() {
	log "INFO" "$1"
	echo -e "${BLU}ℹ $1${NC}"
}

progress() {
	CURRENT_STEP=$((CURRENT_STEP + 1))
	local step_name="$1"
	log "INFO" "=== Step $CURRENT_STEP/$TOTAL_STEPS: $step_name ==="
	echo ""
	echo -e "${PUR}[Step $CURRENT_STEP/$TOTAL_STEPS]${NC} ${CYAN}$step_name${NC}"
	echo -e "${PUR}$(printf '─%.0s' {1..40})${NC}"
}

# ═══════════════════════════════════════════════════════════════
#  Atomic File Helpers
# ═══════════════════════════════════════════════════════════════

atomic_write() {
	local target="$1"
	local content="$2"
	local tmpfile="${target}.tmp.$$"

	echo "$content" > "$tmpfile" 2>/dev/null || {
		rm -f "$tmpfile" 2>/dev/null
		return 1
	}
	mv "$tmpfile" "$target" 2>/dev/null || {
		rm -f "$tmpfile" 2>/dev/null
		return 1
	}
	return 0
}

atomic_append() {
	local target="$1"
	shift
	local tmpfile="${target}.tmp.$$"

	if [ -f "$target" ]; then
		cp "$target" "$tmpfile" 2>/dev/null || {
			rm -f "$tmpfile" 2>/dev/null
			return 1
		}
	else
		touch "$tmpfile" 2>/dev/null || {
			rm -f "$tmpfile" 2>/dev/null
			return 1
		}
	fi

	for line in "$@"; do
		echo "$line" >> "$tmpfile" 2>/dev/null || {
			rm -f "$tmpfile" 2>/dev/null
			return 1
		}
	done

	mv "$tmpfile" "$target" 2>/dev/null || {
		rm -f "$tmpfile" 2>/dev/null
		return 1
	}
	return 0
}

# ═══════════════════════════════════════════════════════════════
#  Checksum Validation
# ═══════════════════════════════════════════════════════════════

checksum_file() {
	local filepath="$1"
	local label="$2"

	if [ ! -f "$filepath" ]; then
		log "AUDIT" "Checksum [$label]: file does not exist: $filepath"
		return
	fi

	local hash
	hash=$(shasum -a 256 "$filepath" 2>/dev/null | awk '{print $1}') || {
		log "AUDIT" "Checksum [$label]: failed to compute hash for $filepath"
		return
	}
	log "AUDIT" "Checksum [$label]: $hash  $filepath"
}

# ═══════════════════════════════════════════════════════════════
#  Argument Parsing
# ═══════════════════════════════════════════════════════════════

parse_args() {
	while [ $# -gt 0 ]; do
		case "$1" in
		--dry-run)
			DRY_RUN=true
			shift
			;;
		--diagnostics)
			run_diagnostics
			exit 0
			;;
		--help)
			echo "Usage: bypass-mdm-v3.sh [OPTIONS]"
			echo ""
			echo "Options:"
			echo "  --dry-run       Show what would be done without making changes"
			echo "  --diagnostics   Run system diagnostics without making changes"
			echo "  --help          Show this help message"
			echo "  --version       Show version information"
			echo ""
			echo "This script must be run from macOS Recovery Mode."
			exit 0
			;;
		--version)
			echo "bypass-mdm v$VERSION"
			exit 0
			;;
		*)
			error_exit "Unknown option: $1 (use --help for usage)"
			;;
		esac
	done
}

# ═══════════════════════════════════════════════════════════════
#  Execution Lock
# ═══════════════════════════════════════════════════════════════

acquire_lock() {
	if mkdir "$LOCK_DIR" 2>/dev/null; then
		echo $$ > "$LOCK_DIR/pid"
		trap 'release_lock' EXIT
		log "INFO" "Acquired execution lock (PID $$)"
		return 0
	fi

	# Lock exists — check if stale
	if [ -f "$LOCK_DIR/pid" ]; then
		local existing_pid
		existing_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null || echo "")
		if [ -n "$existing_pid" ] && kill -0 "$existing_pid" 2>/dev/null; then
			error_exit "Another instance is running (PID $existing_pid). Remove $LOCK_DIR if this is stale."
		else
			# Stale lock — reclaim
			warn "Reclaiming stale lock from PID $existing_pid"
			rm -rf "$LOCK_DIR" 2>/dev/null
			if mkdir "$LOCK_DIR" 2>/dev/null; then
				echo $$ > "$LOCK_DIR/pid"
				trap 'release_lock' EXIT
				log "INFO" "Reclaimed stale lock (PID $$)"
				return 0
			fi
		fi
	else
		# No pid file — stale lock dir
		warn "Reclaiming stale lock (no PID file)"
		rm -rf "$LOCK_DIR" 2>/dev/null
		if mkdir "$LOCK_DIR" 2>/dev/null; then
			echo $$ > "$LOCK_DIR/pid"
			trap 'release_lock' EXIT
			log "INFO" "Reclaimed stale lock (PID $$)"
			return 0
		fi
	fi

	error_exit "Could not acquire execution lock at $LOCK_DIR"
}

release_lock() {
	rm -rf "$LOCK_DIR" 2>/dev/null || true
}

# ═══════════════════════════════════════════════════════════════
#  Transaction Journal
# ═══════════════════════════════════════════════════════════════

journal_begin() {
	local action="$1"
	$DRY_RUN && return
	echo "BEGIN $action $(date '+%Y-%m-%d %H:%M:%S')" >> "$JOURNAL_FILE" 2>/dev/null || true
}

journal_commit() {
	local action="$1"
	$DRY_RUN && return
	echo "COMMIT $action $(date '+%Y-%m-%d %H:%M:%S')" >> "$JOURNAL_FILE" 2>/dev/null || true
}

journal_check() {
	local action="$1"
	[ -f "$JOURNAL_FILE" ] || return 1
	grep -q "^COMMIT $action " "$JOURNAL_FILE" 2>/dev/null
}

journal_init() {
	$DRY_RUN && return

	if [ ! -f "$JOURNAL_FILE" ]; then
		return
	fi

	echo ""
	info "Found existing transaction journal: $JOURNAL_FILE"

	local committed=""
	local incomplete=""
	while IFS= read -r line; do
		case "$line" in
		BEGIN\ *)
			local action="${line#BEGIN }"
			action="${action% [0-9]*}"
			incomplete="$incomplete $action"
			;;
		COMMIT\ *)
			local action="${line#COMMIT }"
			action="${action% [0-9]*}"
			committed="$committed $action"
			# Remove from incomplete
			incomplete="${incomplete/ $action/}"
			;;
		esac
	done < "$JOURNAL_FILE"

	if [ -n "$committed" ]; then
		info "  Completed actions:$committed"
	fi
	if [ -n "$incomplete" ]; then
		warn "  Incomplete actions:$incomplete"
	fi

	echo ""
	read -p "Resume previous run? (y=resume, n=start fresh): " response
	if [[ "$response" =~ ^[Yy]$ ]]; then
		info "Resuming from journal. Completed steps will be skipped."
	else
		info "Starting fresh. Removing old journal."
		rm -f "$JOURNAL_FILE" 2>/dev/null
	fi
}

# ═══════════════════════════════════════════════════════════════
#  Pre-flight Checks
# ═══════════════════════════════════════════════════════════════

check_recovery_mode() {
	info "Checking environment..."

	# Check if diskutil is available
	if ! command -v diskutil &>/dev/null; then
		warn "diskutil not found - are you in Recovery Mode?"
	fi

	# Check if we're booted into the main OS (not recovery)
	if [ -d "/System/Library/CoreServices" ] && [ -f "/System/Library/CoreServices/SystemVersion.plist" ]; then
		warn "You appear to be running from the main OS, not Recovery Mode"
		warn "This script is designed to run from Recovery Mode"
	else
		success "Recovery Mode environment detected"
	fi

	# Check if dscl is available
	if ! command -v dscl &>/dev/null; then
		error_exit "dscl command not found. Cannot proceed without Directory Services."
	fi
}

check_volumes_mounted() {
	local vol_count=0
	for vol in /Volumes/*; do
		if [ -d "$vol" ]; then
			vol_count=$((vol_count + 1))
		fi
	done

	if [ $vol_count -eq 0 ]; then
		error_exit "No volumes found in /Volumes/. Ensure your macOS disk is mounted."
	fi

	success "Found $vol_count mounted volume(s)"
}

detect_macos_version() {
	local system_path="$1"
	local plist="$system_path/System/Library/CoreServices/SystemVersion.plist"

	if [ -f "$plist" ]; then
		local version
		version=$(grep -A1 "ProductVersion" "$plist" 2>/dev/null | grep "<string>" | sed 's/.*<string>\(.*\)<\/string>.*/\1/' || echo "unknown")
		echo "$version"
	else
		echo "unknown"
	fi
}

# ═══════════════════════════════════════════════════════════════
#  Environment Fingerprint
# ═══════════════════════════════════════════════════════════════

log_environment_fingerprint() {
	local phase="${1:-basic}"

	log "INFO" "=== Environment Fingerprint ($phase) ==="
	log "INFO" "Script version: $VERSION"
	log "INFO" "Date: $(date '+%Y-%m-%d %H:%M:%S')"
	log "INFO" "Hostname: $(hostname 2>/dev/null || echo 'unknown')"
	log "INFO" "Architecture: $(uname -m 2>/dev/null || echo 'unknown')"
	log "INFO" "Hardware model: $(sysctl -n hw.model 2>/dev/null || echo 'unknown')"
	log "INFO" "Recovery OS version: $(sw_vers -productVersion 2>/dev/null || echo 'unknown')"

	# Available tools scan
	local tools="diskutil dscl python3 grep awk sed"
	local available=""
	local missing=""
	for tool in $tools; do
		if command -v "$tool" &>/dev/null; then
			available="$available $tool"
		else
			missing="$missing $tool"
		fi
	done
	log "INFO" "Available tools:$available"
	[ -n "$missing" ] && log "WARN" "Missing tools:$missing"

	if [ "$phase" = "full" ]; then
		local sys_path="${2:-}"
		if [ -n "$sys_path" ]; then
			local mac_ver
			mac_ver=$(detect_macos_version "$sys_path")
			log "INFO" "Target macOS version: $mac_ver"
		fi

		# APFS container info
		log "INFO" "APFS container info:"
		diskutil apfs list 2>/dev/null | head -20 | while IFS= read -r line; do
			log "INFO" "  $line"
		done

		# Disk layout
		log "INFO" "Disk layout:"
		diskutil list 2>/dev/null | head -20 | while IFS= read -r line; do
			log "INFO" "  $line"
		done

		# Mounted volumes
		log "INFO" "Mounted volumes:"
		for vol in /Volumes/*; do
			[ -d "$vol" ] && log "INFO" "  $vol"
		done
	fi

	log "INFO" "=== End Environment Fingerprint ==="
}

# ═══════════════════════════════════════════════════════════════
#  Self-Diagnostics
# ═══════════════════════════════════════════════════════════════

run_diagnostics() {
	echo ""
	echo -e "${CYAN}╔═══════════════════════════════════════════════════════╗${NC}"
	echo -e "${CYAN}║         System Diagnostics - bypass-mdm v$VERSION       ║${NC}"
	echo -e "${CYAN}╚═══════════════════════════════════════════════════════╝${NC}"
	echo ""

	# Recovery Mode detection
	echo -e "${CYAN}Recovery Mode:${NC}"
	if [ -d "/System/Library/CoreServices" ] && [ -f "/System/Library/CoreServices/SystemVersion.plist" ]; then
		echo -e "  ${YEL}~${NC} Appears to be running from main OS (not Recovery Mode)"
	else
		echo -e "  ${GRN}✓${NC} Recovery Mode environment detected"
	fi
	echo ""

	# Hardware model
	echo -e "${CYAN}Hardware:${NC}"
	echo -e "  Model: $(sysctl -n hw.model 2>/dev/null || echo 'unknown')"
	echo -e "  Architecture: $(uname -m 2>/dev/null || echo 'unknown')"
	echo -e "  Recovery OS: $(sw_vers -productVersion 2>/dev/null || echo 'unknown')"
	echo ""

	# macOS version on target volume
	echo -e "${CYAN}Target Volume macOS:${NC}"
	local found_system=false
	for vol in /Volumes/*; do
		if [ -d "$vol/System/Library/CoreServices" ]; then
			local ver
			ver=$(detect_macos_version "$vol")
			echo -e "  ${GRN}✓${NC} $(basename "$vol"): macOS $ver"
			found_system=true
		fi
	done
	$found_system || echo -e "  ${RED}✗${NC} No system volume found"
	echo ""

	# Mounted volumes
	echo -e "${CYAN}Mounted Volumes:${NC}"
	for vol in /Volumes/*; do
		if [ -d "$vol" ]; then
			echo -e "  • $(basename "$vol")"
		fi
	done
	echo ""

	# APFS container info
	echo -e "${CYAN}APFS Container Info:${NC}"
	if command -v diskutil &>/dev/null; then
		diskutil apfs list 2>/dev/null | head -20 || echo "  Could not read APFS info"
	else
		echo "  diskutil not available"
	fi
	echo ""

	# Available commands
	echo -e "${CYAN}Available Commands:${NC}"
	local tools="diskutil dscl python3 grep awk sed"
	for tool in $tools; do
		if command -v "$tool" &>/dev/null; then
			echo -e "  ${GRN}✓${NC} $tool"
		else
			echo -e "  ${RED}✗${NC} $tool"
		fi
	done
	echo ""

	# dscl path accessibility
	echo -e "${CYAN}Directory Services:${NC}"
	local dscl_found=false
	for vol in /Volumes/*; do
		local dscl_path="$vol/private/var/db/dslocal/nodes/Default"
		if [ -d "$dscl_path" ]; then
			echo -e "  ${GRN}✓${NC} dscl path found: $dscl_path"
			dscl_found=true

			# UID availability
			if command -v dscl &>/dev/null; then
				local uid
				uid=$(find_available_uid "$dscl_path" 2>/dev/null) || uid="unknown"
				echo -e "  Next available UID: $uid"
			fi
		fi
	done
	$dscl_found || echo -e "  ${YEL}~${NC} No dscl path found in any volume"
	echo ""

	# Writable paths test
	echo -e "${CYAN}Writable Paths:${NC}"
	local test_paths="/tmp /Volumes"
	for p in $test_paths; do
		if [ -w "$p" ]; then
			echo -e "  ${GRN}✓${NC} $p (writable)"
		else
			echo -e "  ${RED}✗${NC} $p (not writable)"
		fi
	done
	echo ""

	# Existing bypass status
	echo -e "${CYAN}Existing Bypass Status:${NC}"
	local bypass_checked=false
	for vol in /Volumes/*; do
		local sys_path="$vol"
		local data_paths=("/Volumes/Data" "/Volumes/$(basename "$vol") - Data")
		for data_path in "${data_paths[@]}"; do
			if [ -d "$data_path/private/var/db/dslocal/nodes/Default" ]; then
				local dscl_p="$data_path/private/var/db/dslocal/nodes/Default"
				local status
				status=$(check_existing_bypass "$sys_path" "$data_path" "$dscl_p" 2>/dev/null) || status="error"
				echo -e "  Status: $status (system: $(basename "$sys_path"), data: $(basename "$data_path"))"
				bypass_checked=true
				break 2
			fi
		done
	done
	$bypass_checked || echo -e "  ${YEL}~${NC} Could not determine bypass status"
	echo ""
}

# ═══════════════════════════════════════════════════════════════
#  Volume Detection (preserved from v2)
# ═══════════════════════════════════════════════════════════════

detect_volumes() {
	local system_vol=""
	local data_vol=""

	info "Detecting system volumes..." >&2

	# Strategy 1: Look for common macOS APFS volume patterns
	for vol in /Volumes/*; do
		if [ -d "$vol" ]; then
			vol_name=$(basename "$vol")
			if [[ ! "$vol_name" =~ "Data"$ ]] && [[ ! "$vol_name" =~ "Recovery" ]] && [ -d "$vol/System" ]; then
				system_vol="$vol_name"
				info "Found system volume: $system_vol" >&2
				break
			fi
		fi
	done

	# Strategy 2: Fallback - any volume with /System directory
	if [ -z "$system_vol" ]; then
		for vol in /Volumes/*; do
			if [ -d "$vol/System" ]; then
				system_vol=$(basename "$vol")
				warn "Using volume with /System directory: $system_vol" >&2
				break
			fi
		done
	fi

	# Strategy 3: Check for Data volume
	if [ -d "/Volumes/Data" ]; then
		data_vol="Data"
		info "Found data volume: $data_vol" >&2
	elif [ -n "$system_vol" ] && [ -d "/Volumes/$system_vol - Data" ]; then
		data_vol="$system_vol - Data"
		info "Found data volume: $data_vol" >&2
	else
		for vol in /Volumes/*Data; do
			if [ -d "$vol" ]; then
				data_vol=$(basename "$vol")
				warn "Found data volume: $data_vol" >&2
				break
			fi
		done
	fi

	# Validate
	if [ -z "$system_vol" ]; then
		error_exit "Could not detect system volume. Please ensure you're running this in Recovery mode with a macOS installation present."
	fi

	if [ -z "$data_vol" ]; then
		error_exit "Could not detect data volume. Please ensure you're running this in Recovery mode with a macOS installation present."
	fi

	echo "$system_vol|$data_vol"
}

# ═══════════════════════════════════════════════════════════════
#  Input Validation (preserved from v2)
# ═══════════════════════════════════════════════════════════════

validate_username() {
	local username="$1"

	if [ -z "$username" ]; then
		echo "Username cannot be empty"
		return 1
	fi

	if [ ${#username} -gt 31 ]; then
		echo "Username too long (max 31 characters)"
		return 1
	fi

	if ! [[ "$username" =~ ^[a-zA-Z0-9_-]+$ ]]; then
		echo "Username can only contain letters, numbers, underscore, and hyphen"
		return 1
	fi

	if ! [[ "$username" =~ ^[a-zA-Z_] ]]; then
		echo "Username must start with a letter or underscore"
		return 1
	fi

	return 0
}

validate_password() {
	local password="$1"

	if [ -z "$password" ]; then
		echo "Password cannot be empty"
		return 1
	fi

	if [ ${#password} -lt 4 ]; then
		echo "Password too short (minimum 4 characters recommended)"
		return 1
	fi

	return 0
}

# ═══════════════════════════════════════════════════════════════
#  User Management (preserved from v2)
# ═══════════════════════════════════════════════════════════════

check_user_exists() {
	local dscl_path="$1"
	local username="$2"

	if dscl -f "$dscl_path" localhost -read "/Local/Default/Users/$username" 2>/dev/null; then
		return 0
	else
		return 1
	fi
}

find_available_uid() {
	local dscl_path="$1"
	local uid=501

	while [ $uid -lt 600 ]; do
		if ! dscl -f "$dscl_path" localhost -search /Local/Default/Users UniqueID $uid 2>/dev/null | grep -q "UniqueID"; then
			echo $uid
			return 0
		fi
		uid=$((uid + 1))
	done

	echo "501"
	return 1
}

# ═══════════════════════════════════════════════════════════════
#  Backup Subsystem (v3 new)
# ═══════════════════════════════════════════════════════════════

create_backups() {
	local system_path="$1"
	local config_path="$2"
	local hosts_file="$system_path/etc/hosts"
	local timestamp
	timestamp=$(date '+%Y%m%d_%H%M%S')

	if $DRY_RUN; then
		info "[DRY-RUN] Would create backup directory: $BACKUP_DIR"
		[ -f "$hosts_file" ] && info "[DRY-RUN] Would backup: $hosts_file"
		[ -d "$config_path" ] && info "[DRY-RUN] Would backup: $config_path"
		return
	fi

	mkdir -p "$BACKUP_DIR" || warn "Could not create backup directory"

	# Backup hosts file
	if [ -f "$hosts_file" ]; then
		cp "$hosts_file" "$BACKUP_DIR/hosts.bak" 2>/dev/null && success "Backed up hosts file" || warn "Could not backup hosts file"
	else
		info "No existing hosts file to backup"
	fi

	# Backup ConfigurationProfiles/Settings
	if [ -d "$config_path" ]; then
		cp -a "$config_path" "$BACKUP_DIR/ConfigurationProfiles-Settings/" 2>/dev/null && success "Backed up configuration profiles" || warn "Could not backup configuration profiles"
	else
		info "No existing configuration profiles to backup"
	fi

	# Backup launchd disabled.plist
	local disabled_plist="$system_path/private/var/db/com.apple.xpc.launchd/disabled.plist"
	if [ -f "$disabled_plist" ]; then
		cp "$disabled_plist" "$BACKUP_DIR/disabled.plist.bak" 2>/dev/null && success "Backed up launchd disabled.plist" || warn "Could not backup disabled.plist"
	else
		info "No existing disabled.plist to backup"
	fi

	# Write manifest
	echo "Backup created at: $timestamp" >"$BACKUP_DIR/manifest.txt"
	echo "System path: $system_path" >>"$BACKUP_DIR/manifest.txt"
	echo "Config path: $config_path" >>"$BACKUP_DIR/manifest.txt"
	log "INFO" "Backups created in $BACKUP_DIR"
}

# ═══════════════════════════════════════════════════════════════
#  Idempotency Detection (v3 new)
# ═══════════════════════════════════════════════════════════════

check_existing_bypass() {
	local system_path="$1"
	local data_path="$2"
	local dscl_path="$3"
	local username="${4:-Apple}"

	local checks_total=0
	local checks_passed=0
	local hosts_file="$system_path/etc/hosts"
	local config_path="$system_path/var/db/ConfigurationProfiles/Settings"

	info "Scanning for existing bypass artifacts..."

	# Check hosts file for blocked domains
	if [ -f "$hosts_file" ]; then
		local blocked_count=0
		for domain in "${MDM_DOMAINS[@]}"; do
			if grep -q "$domain" "$hosts_file" 2>/dev/null; then
				blocked_count=$((blocked_count + 1))
			fi
		done
		checks_total=$((checks_total + 1))
		if [ $blocked_count -eq ${#MDM_DOMAINS[@]} ]; then
			checks_passed=$((checks_passed + 1))
			info "  Hosts file: all $blocked_count domains blocked"
		elif [ $blocked_count -gt 0 ]; then
			info "  Hosts file: $blocked_count/${#MDM_DOMAINS[@]} domains blocked"
		fi
	fi

	# Check config markers
	checks_total=$((checks_total + 1))
	if [ -f "$config_path/.cloudConfigProfileInstalled" ] && [ -f "$config_path/.cloudConfigRecordNotFound" ]; then
		checks_passed=$((checks_passed + 1))
		info "  Bypass markers: present"
	fi

	# Check activation records removed
	checks_total=$((checks_total + 1))
	if [ ! -f "$config_path/.cloudConfigHasActivationRecord" ] && [ ! -f "$config_path/.cloudConfigRecordFound" ]; then
		checks_passed=$((checks_passed + 1))
		info "  Activation records: cleared"
	fi

	# Check .AppleSetupDone
	checks_total=$((checks_total + 1))
	if [ -f "$data_path/private/var/db/.AppleSetupDone" ]; then
		checks_passed=$((checks_passed + 1))
		info "  Setup marker: present"
	fi

	# Check if MDM daemons are disabled (override plists exist)
	local daemon_overrides=0
	for ident in "${MDM_DAEMONS[@]}"; do
		if [ -f "$system_path/Library/LaunchDaemons/${ident}.plist" ]; then
			if grep -q "Disabled" "$system_path/Library/LaunchDaemons/${ident}.plist" 2>/dev/null; then
				daemon_overrides=$((daemon_overrides + 1))
			fi
		fi
	done
	for ident in "${MDM_AGENTS[@]}"; do
		if [ -f "$system_path/Library/LaunchAgents/${ident}.plist" ]; then
			if grep -q "Disabled" "$system_path/Library/LaunchAgents/${ident}.plist" 2>/dev/null; then
				daemon_overrides=$((daemon_overrides + 1))
			fi
		fi
	done
	local total_mdm_ids=$(( ${#MDM_DAEMONS[@]} + ${#MDM_AGENTS[@]} ))
	checks_total=$((checks_total + 1))
	if [ $daemon_overrides -eq $total_mdm_ids ]; then
		checks_passed=$((checks_passed + 1))
		info "  MDM daemons: all $daemon_overrides disabled"
	elif [ $daemon_overrides -gt 0 ]; then
		info "  MDM daemons: $daemon_overrides/$total_mdm_ids disabled"
	fi

	# Determine status
	if [ $checks_passed -eq $checks_total ] && [ $checks_total -gt 0 ]; then
		echo "full"
	elif [ $checks_passed -gt 0 ]; then
		echo "partial"
	else
		echo "none"
	fi
}

# ═══════════════════════════════════════════════════════════════
#  Core Operations (refactored from v2 with dry-run + idempotency)
# ═══════════════════════════════════════════════════════════════

do_rename_data_volume() {
	local data_volume="$1"

	if journal_check "rename_volume"; then
		info "Skipping rename_volume (already completed in previous run)"
		return
	fi

	if [ "$data_volume" = "Data" ]; then
		info "Data volume already named 'Data', skipping rename"
		return
	fi

	ORIGINAL_DATA_VOLUME="$data_volume"

	if $DRY_RUN; then
		info "[DRY-RUN] Would rename '$data_volume' to 'Data'"
		return
	fi

	journal_begin "rename_volume"

	info "Renaming data volume to 'Data' for consistency..."
	if diskutil rename "$data_volume" "Data" 2>/dev/null; then
		success "Data volume renamed successfully"
		COMPLETED_ACTIONS+=("rename_volume")
	else
		warn "Could not rename data volume, continuing with: $data_volume"
	fi

	journal_commit "rename_volume"
}

do_create_user() {
	local dscl_path="$1"
	local data_path="$2"
	local username="$3"
	local realName="$4"
	local passw="$5"
	local uid="$6"

	if journal_check "create_user"; then
		info "Skipping create_user (already completed in previous run)"
		return
	fi

	if $DRY_RUN; then
		info "[DRY-RUN] Would create user '$username' (UID: $uid, Name: $realName)"
		info "[DRY-RUN] Would create home directory at $data_path/Users/$username"
		info "[DRY-RUN] Would add '$username' to admin group"
		return
	fi

	journal_begin "create_user"

	info "Creating user account: $username"

	if ! dscl -f "$dscl_path" localhost -create "/Local/Default/Users/$username" 2>/dev/null; then
		error_exit "Failed to create user account"
	fi

	dscl -f "$dscl_path" localhost -create "/Local/Default/Users/$username" UserShell "/bin/zsh" || warn "Failed to set user shell"
	dscl -f "$dscl_path" localhost -create "/Local/Default/Users/$username" RealName "$realName" || warn "Failed to set real name"
	dscl -f "$dscl_path" localhost -create "/Local/Default/Users/$username" UniqueID "$uid" || warn "Failed to set UID"
	dscl -f "$dscl_path" localhost -create "/Local/Default/Users/$username" PrimaryGroupID "20" || warn "Failed to set GID"

	local user_home="$data_path/Users/$username"
	if [ ! -d "$user_home" ]; then
		if mkdir -p "$user_home" 2>/dev/null; then
			success "Created user home directory"
		else
			error_exit "Failed to create user home directory: $user_home"
		fi
	else
		warn "User home directory already exists: $user_home"
	fi

	dscl -f "$dscl_path" localhost -create "/Local/Default/Users/$username" NFSHomeDirectory "/Users/$username" || warn "Failed to set home directory"

	if ! dscl -f "$dscl_path" localhost -passwd "/Local/Default/Users/$username" "$passw" 2>/dev/null; then
		error_exit "Failed to set user password"
	fi

	if ! dscl -f "$dscl_path" localhost -append "/Local/Default/Groups/admin" GroupMembership "$username" 2>/dev/null; then
		error_exit "Failed to add user to admin group"
	fi

	success "User account created successfully"
	COMPLETED_ACTIONS+=("create_user")

	journal_commit "create_user"
}

do_block_domains() {
	local system_path="$1"
	local hosts_file="$system_path/etc/hosts"

	if journal_check "block_domains"; then
		info "Skipping block_domains (already completed in previous run)"
		return
	fi

	if [ ! -f "$hosts_file" ]; then
		if $DRY_RUN; then
			info "[DRY-RUN] Would create hosts file: $hosts_file"
		else
			touch "$hosts_file" || error_exit "Failed to create hosts file"
			info "Created hosts file"
		fi
	fi

	local added=0
	local skipped=0
	local new_lines=()

	for domain in "${MDM_DOMAINS[@]}"; do
		if grep -q "$domain" "$hosts_file" 2>/dev/null; then
			skipped=$((skipped + 1))
			log "INFO" "Domain already blocked: $domain"
		elif $DRY_RUN; then
			info "[DRY-RUN] Would block: $domain"
			added=$((added + 1))
		else
			new_lines+=("0.0.0.0 $domain")
			added=$((added + 1))
			log "SUCCESS" "Blocked domain: $domain"
		fi
	done

	if ! $DRY_RUN && [ ${#new_lines[@]} -gt 0 ]; then
		journal_begin "block_domains"
		checksum_file "$hosts_file" "hosts-pre-block"
		atomic_append "$hosts_file" "${new_lines[@]}" || error_exit "Failed to append domains to hosts file"
		checksum_file "$hosts_file" "hosts-post-block"
	fi

	if [ $skipped -gt 0 ]; then
		info "$skipped domain(s) already blocked (skipped)"
	fi
	if [ $added -gt 0 ]; then
		success "Blocked $added MDM domain(s)"
	fi

	if ! $DRY_RUN; then
		COMPLETED_ACTIONS+=("block_domains")
		journal_commit "block_domains"
	fi
}

do_config_profiles() {
	local system_path="$1"
	local data_path="$2"
	local config_path="$system_path/var/db/ConfigurationProfiles/Settings"

	if journal_check "config_profiles"; then
		info "Skipping config_profiles (already completed in previous run)"
		return
	fi

	if $DRY_RUN; then
		info "[DRY-RUN] Would create config directory: $config_path"
		info "[DRY-RUN] Would touch: $data_path/private/var/db/.AppleSetupDone"
		info "[DRY-RUN] Would remove: .cloudConfigHasActivationRecord, .cloudConfigRecordFound"
		info "[DRY-RUN] Would touch: .cloudConfigProfileInstalled, .cloudConfigRecordNotFound"
		return
	fi

	journal_begin "config_profiles"

	# Create config directory if missing
	if [ ! -d "$config_path" ]; then
		if mkdir -p "$config_path" 2>/dev/null; then
			success "Created configuration directory"
		else
			warn "Could not create configuration directory"
		fi
	fi

	# Mark setup as done
	touch "$data_path/private/var/db/.AppleSetupDone" 2>/dev/null && success "Marked setup as complete" || warn "Could not mark setup as complete"

	# Remove activation records
	rm -rf "$config_path/.cloudConfigHasActivationRecord" 2>/dev/null && success "Removed activation record" || info "No activation record to remove"
	rm -rf "$config_path/.cloudConfigRecordFound" 2>/dev/null && success "Removed cloud config record" || info "No cloud config record to remove"

	# Create bypass markers
	touch "$config_path/.cloudConfigProfileInstalled" 2>/dev/null && success "Created profile installed marker" || warn "Could not create profile marker"
	touch "$config_path/.cloudConfigRecordNotFound" 2>/dev/null && success "Created record not found marker" || warn "Could not create not found marker"

	COMPLETED_ACTIONS+=("config_profiles")

	journal_commit "config_profiles"
}

# ═══════════════════════════════════════════════════════════════
#  MDM Daemon Disabler (v3.1 new)
# ═══════════════════════════════════════════════════════════════

_create_override_plist() {
	local plist_path="$1"
	local identifier="$2"

	local plist_content
	plist_content=$(cat <<OVERRIDEPLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$identifier</string>
	<key>Disabled</key>
	<true/>
	<key>ProgramArguments</key>
	<array>
		<string>/usr/bin/true</string>
	</array>
</dict>
</plist>
OVERRIDEPLISTEOF
	)

	if [ -f "$plist_path" ]; then
		# File exists — check if Disabled key is already set
		if grep -q "<key>Disabled</key>" "$plist_path" 2>/dev/null; then
			log "INFO" "Override plist already has Disabled key: $plist_path"
			return 0
		else
			# Inject Disabled=true before closing </dict>
			checksum_file "$plist_path" "plist-pre-inject-$identifier"
			sed -i '' 's|</dict>|	<key>Disabled</key>\
	<true/>\
</dict>|' "$plist_path" 2>/dev/null
			checksum_file "$plist_path" "plist-post-inject-$identifier"
			log "SUCCESS" "Injected Disabled key into existing plist: $plist_path"
			return 0
		fi
	fi

	checksum_file "$plist_path" "plist-pre-create-$identifier"
	atomic_write "$plist_path" "$plist_content" || {
		log "WARN" "Failed to atomically write plist: $plist_path"
		echo "$plist_content" > "$plist_path" 2>/dev/null
	}
	chmod 644 "$plist_path" 2>/dev/null
	checksum_file "$plist_path" "plist-post-create-$identifier"
	log "SUCCESS" "Created override plist: $plist_path"
}

do_disable_mdm_daemons() {
	local system_path="$1"
	local data_path="$2"

	if journal_check "disable_daemons"; then
		info "Skipping disable_daemons (already completed in previous run)"
		return
	fi

	local daemon_dir="$system_path/Library/LaunchDaemons"
	local agent_dir="$system_path/Library/LaunchAgents"
	local disabled_count=0
	local total_mdm_ids=$(( ${#MDM_DAEMONS[@]} + ${#MDM_AGENTS[@]} ))

	if $DRY_RUN; then
		info "[DRY-RUN] Would create override plists for $total_mdm_ids MDM daemons/agents"
		for ident in "${MDM_DAEMONS[@]}"; do
			info "[DRY-RUN]   Daemon: $ident"
		done
		for ident in "${MDM_AGENTS[@]}"; do
			info "[DRY-RUN]   Agent: $ident"
		done
		info "[DRY-RUN] Would update launchd disabled.plist database"
		return
	fi

	journal_begin "disable_daemons"

	# Strategy A: Create override plists
	mkdir -p "$daemon_dir" 2>/dev/null
	mkdir -p "$agent_dir" 2>/dev/null

	for ident in "${MDM_DAEMONS[@]}"; do
		if _create_override_plist "$daemon_dir/${ident}.plist" "$ident"; then
			disabled_count=$((disabled_count + 1))
		fi
	done

	for ident in "${MDM_AGENTS[@]}"; do
		if _create_override_plist "$agent_dir/${ident}.plist" "$ident"; then
			disabled_count=$((disabled_count + 1))
		fi
	done

	# Strategy B: Update launchd per-machine disabled database
	local disabled_dir="$data_path/private/var/db/com.apple.xpc.launchd"
	local disabled_plist="$disabled_dir/disabled.plist"
	mkdir -p "$disabled_dir" 2>/dev/null

	if command -v python3 &>/dev/null; then
		local all_idents=""
		for ident in "${MDM_DAEMONS[@]}" "${MDM_AGENTS[@]}"; do
			all_idents="$all_idents \"$ident\","
		done
		checksum_file "$disabled_plist" "disabled-plist-pre-update"
		python3 -c "
import plistlib, os, sys
path = '$disabled_plist'
try:
    with open(path, 'rb') as f:
        data = plistlib.load(f)
except:
    data = {}
for ident in [${all_idents}]:
    data[ident] = True
with open(path, 'wb') as f:
    plistlib.dump(data, f)
" 2>/dev/null && success "Updated launchd disabled database" || warn "Could not update launchd disabled database"
		checksum_file "$disabled_plist" "disabled-plist-post-update"
	else
		warn "python3 not available — skipping launchd disabled database update"
	fi

	success "Disabled $disabled_count/$total_mdm_ids MDM daemons/agents via override plists"
	COMPLETED_ACTIONS+=("disable_daemons")

	journal_commit "disable_daemons"
}

# ═══════════════════════════════════════════════════════════════
#  Guardian Daemon for Persistence (v3.1 enhanced)
# ═══════════════════════════════════════════════════════════════

do_create_launchdaemon() {
	local system_path="$1"
	local plist_dir="$system_path/Library/LaunchDaemons"
	local plist_path="$plist_dir/$LAUNCHDAEMON_LABEL.plist"
	local script_dir="$system_path/$GUARDIAN_SCRIPT_PATH"
	local script_dir_parent
	script_dir_parent=$(dirname "$script_dir")

	if journal_check "launchdaemon"; then
		info "Skipping launchdaemon (already completed in previous run)"
		return
	fi

	# Build the domain list for the guardian script
	local domain_lines=""
	for domain in "${MDM_DOMAINS[@]}"; do
		domain_lines="$domain_lines	\"$domain\"
"
	done

	local guardian_script
	guardian_script=$(cat <<'GUARDIANEOF'
#!/bin/bash
# ═══════════════════════════════════════════════════════════════
#  MDM Guardian - Auto-generated by bypass-mdm v__VERSION__
#  Re-enforces MDM bypass protections every hour
# ═══════════════════════════════════════════════════════════════

LOG="/var/log/mdmguardian.log"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Guardian check starting..." >> "$LOG"

# ── Re-enforce domain blocks in /etc/hosts ──
MDM_DOMAINS=(
__DOMAIN_LINES__
)

for domain in "${MDM_DOMAINS[@]}"; do
	if ! grep -q "$domain" /etc/hosts 2>/dev/null; then
		echo "0.0.0.0 $domain" >> /etc/hosts
		echo "[$(date '+%H:%M:%S')] Re-blocked domain: $domain" >> "$LOG"
	fi
done

# ── Re-enforce config markers ──
CONFIG_DIR="/var/db/ConfigurationProfiles/Settings"
mkdir -p "$CONFIG_DIR" 2>/dev/null

touch "$CONFIG_DIR/.cloudConfigProfileInstalled" 2>/dev/null
touch "$CONFIG_DIR/.cloudConfigRecordNotFound" 2>/dev/null
rm -f "$CONFIG_DIR/.cloudConfigHasActivationRecord" 2>/dev/null
rm -f "$CONFIG_DIR/.cloudConfigRecordFound" 2>/dev/null

# ── Kill mdmclient if running ──
if pgrep -x "mdmclient" >/dev/null 2>&1; then
	pkill -x "mdmclient" 2>/dev/null
	echo "[$(date '+%H:%M:%S')] Killed mdmclient process" >> "$LOG"
fi

echo "[$(date '+%H:%M:%S')] Guardian check complete." >> "$LOG"
GUARDIANEOF
	)

	# Substitute placeholders
	guardian_script="${guardian_script//__VERSION__/$VERSION}"
	guardian_script="${guardian_script//__DOMAIN_LINES__/$domain_lines}"

	local plist_content
	plist_content=$(cat <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LAUNCHDAEMON_LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/bash</string>
		<string>/$GUARDIAN_SCRIPT_PATH</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>StartInterval</key>
	<integer>3600</integer>
	<key>StandardOutPath</key>
	<string>/var/log/mdmguardian.log</string>
	<key>StandardErrorPath</key>
	<string>/var/log/mdmguardian.log</string>
</dict>
</plist>
PLISTEOF
	)

	if $DRY_RUN; then
		info "[DRY-RUN] Would create guardian script at: $script_dir"
		info "[DRY-RUN] Would create LaunchDaemon at: $plist_path"
		info "[DRY-RUN] Guardian re-runs every 3600s (1 hour)"
		return
	fi

	journal_begin "launchdaemon"

	# Create guardian script
	mkdir -p "$script_dir_parent" 2>/dev/null || warn "Could not create Scripts directory"
	if atomic_write "$script_dir" "$guardian_script"; then
		chmod 755 "$script_dir" 2>/dev/null
		success "Guardian script installed at /$GUARDIAN_SCRIPT_PATH"
		log "SUCCESS" "Created guardian script at $script_dir"
		checksum_file "$script_dir" "guardian-script-created"
	else
		warn "Could not create guardian script"
	fi

	# Create LaunchDaemon plist
	mkdir -p "$plist_dir" 2>/dev/null || warn "Could not create LaunchDaemons directory"
	if atomic_write "$plist_path" "$plist_content"; then
		chmod 644 "$plist_path" 2>/dev/null
		success "Guardian LaunchDaemon installed (runs at boot + every hour)"
		log "SUCCESS" "Created LaunchDaemon at $plist_path"
		checksum_file "$plist_path" "guardian-plist-created"
		COMPLETED_ACTIONS+=("launchdaemon")
	else
		warn "Could not create LaunchDaemon (guardian may not persist)"
	fi

	journal_commit "launchdaemon"
}

# ═══════════════════════════════════════════════════════════════
#  Cleanup Script Generator (v3 new)
# ═══════════════════════════════════════════════════════════════

do_generate_cleanup_script() {
	local data_path="$1"
	local username="$2"
	local desktop_path="$data_path/Users/$username/Desktop"
	local script_path="$desktop_path/cleanup-mdm-bypass.sh"

	if journal_check "cleanup_script"; then
		info "Skipping cleanup_script (already completed in previous run)"
		return
	fi

	# Build sed commands for domain removal
	local sed_commands=""
	for domain in "${MDM_DOMAINS[@]}"; do
		sed_commands="$sed_commands	sed -i '' '/$domain/d' /etc/hosts 2>/dev/null
"
	done

	# Build daemon override removal commands
	local daemon_rm_commands=""
	for ident in "${MDM_DAEMONS[@]}"; do
		daemon_rm_commands="${daemon_rm_commands}rm -f \"/Library/LaunchDaemons/${ident}.plist\" 2>/dev/null
"
	done
	for ident in "${MDM_AGENTS[@]}"; do
		daemon_rm_commands="${daemon_rm_commands}rm -f \"/Library/LaunchAgents/${ident}.plist\" 2>/dev/null
"
	done

	# Build python command to remove entries from disabled.plist
	local all_idents_py=""
	for ident in "${MDM_DAEMONS[@]}" "${MDM_AGENTS[@]}"; do
		all_idents_py="$all_idents_py \"$ident\","
	done

	local cleanup_content
	cleanup_content=$(
		cat <<CLEANUPEOF
#!/bin/bash
# ═══════════════════════════════════════════════════════════════
#  MDM Bypass Cleanup - Generated by bypass-mdm v$VERSION
#  Run with: sudo bash cleanup-mdm-bypass.sh
# ═══════════════════════════════════════════════════════════════

echo "This will remove all MDM bypass artifacts:"
echo "  - Remove temporary user: $username"
echo "  - Remove Guardian daemon + script"
echo "  - Remove MDM daemon override plists"
echo "  - Remove blocked domains from /etc/hosts"
echo "  - Remove bypass configuration markers"
echo "  - Clean launchd disabled database"
echo ""
read -p "Are you sure? (y/n): " confirm
[[ "\$confirm" =~ ^[Yy]$ ]] || { echo "Cancelled."; exit 0; }

echo ""
echo "Removing temporary user..."
sysadminctl -deleteUser "$username" 2>/dev/null && echo "✓ User removed" || echo "✗ Could not remove user (may need manual removal)"

echo "Removing Guardian daemon and script..."
rm -f "/Library/LaunchDaemons/$LAUNCHDAEMON_LABEL.plist" 2>/dev/null && echo "✓ Guardian LaunchDaemon removed" || echo "✗ Guardian LaunchDaemon not found"
rm -f "/$GUARDIAN_SCRIPT_PATH" 2>/dev/null && echo "✓ Guardian script removed" || echo "✗ Guardian script not found"

echo "Removing MDM daemon override plists..."
$daemon_rm_commands
echo "✓ MDM daemon overrides removed"

echo "Cleaning launchd disabled database..."
python3 -c "
import plistlib, os
path = '/private/var/db/com.apple.xpc.launchd/disabled.plist'
if os.path.exists(path):
    with open(path, 'rb') as f:
        data = plistlib.load(f)
    for ident in [${all_idents_py}]:
        data.pop(ident, None)
    with open(path, 'wb') as f:
        plistlib.dump(data, f)
" 2>/dev/null && echo "✓ Launchd disabled database cleaned" || echo "✗ Could not clean disabled database"

echo "Cleaning hosts file..."
$sed_commands
echo "✓ Hosts file cleaned"

echo "Removing bypass markers..."
rm -f "/var/db/ConfigurationProfiles/Settings/.cloudConfigProfileInstalled" 2>/dev/null
rm -f "/var/db/ConfigurationProfiles/Settings/.cloudConfigRecordNotFound" 2>/dev/null
echo "✓ Bypass markers removed"

echo "Cleaning up journal and lock files..."
rm -f "$JOURNAL_FILE" 2>/dev/null
rm -rf "$LOCK_DIR" 2>/dev/null
echo "✓ Temporary files cleaned"

echo ""
echo "Cleanup complete. Reboot recommended."
CLEANUPEOF
	)

	if $DRY_RUN; then
		info "[DRY-RUN] Would generate cleanup script at: $script_path"
		return
	fi

	journal_begin "cleanup_script"

	# Ensure Desktop directory exists
	mkdir -p "$desktop_path" 2>/dev/null

	if atomic_write "$script_path" "$cleanup_content"; then
		chmod +x "$script_path" 2>/dev/null
		success "Cleanup script generated at: ~/Desktop/cleanup-mdm-bypass.sh"
		log "SUCCESS" "Created cleanup script at $script_path"
		checksum_file "$script_path" "cleanup-script-created"
		COMPLETED_ACTIONS+=("cleanup_script")
	else
		warn "Could not generate cleanup script"
	fi

	journal_commit "cleanup_script"
}

# ═══════════════════════════════════════════════════════════════
#  Verification Pass (v3 new)
# ═══════════════════════════════════════════════════════════════

verify_changes() {
	local system_path="$1"
	local data_path="$2"
	local dscl_path="$3"
	local username="$4"
	local hosts_file="$system_path/etc/hosts"
	local config_path="$system_path/var/db/ConfigurationProfiles/Settings"
	local pass=0
	local fail=0

	echo ""
	echo -e "${CYAN}Verification Checklist:${NC}"

	# Check each MDM domain
	for domain in "${MDM_DOMAINS[@]}"; do
		if grep -q "$domain" "$hosts_file" 2>/dev/null; then
			echo -e "  ${GRN}✓${NC} Domain blocked: $domain"
			pass=$((pass + 1))
		else
			echo -e "  ${RED}✗${NC} Domain NOT blocked: $domain"
			fail=$((fail + 1))
		fi
	done

	# Check config markers exist
	if [ -f "$config_path/.cloudConfigProfileInstalled" ]; then
		echo -e "  ${GRN}✓${NC} Bypass marker: .cloudConfigProfileInstalled"
		pass=$((pass + 1))
	else
		echo -e "  ${RED}✗${NC} Missing: .cloudConfigProfileInstalled"
		fail=$((fail + 1))
	fi

	if [ -f "$config_path/.cloudConfigRecordNotFound" ]; then
		echo -e "  ${GRN}✓${NC} Bypass marker: .cloudConfigRecordNotFound"
		pass=$((pass + 1))
	else
		echo -e "  ${RED}✗${NC} Missing: .cloudConfigRecordNotFound"
		fail=$((fail + 1))
	fi

	# Check activation records removed
	if [ ! -f "$config_path/.cloudConfigHasActivationRecord" ]; then
		echo -e "  ${GRN}✓${NC} Removed: .cloudConfigHasActivationRecord"
		pass=$((pass + 1))
	else
		echo -e "  ${RED}✗${NC} Still present: .cloudConfigHasActivationRecord"
		fail=$((fail + 1))
	fi

	if [ ! -f "$config_path/.cloudConfigRecordFound" ]; then
		echo -e "  ${GRN}✓${NC} Removed: .cloudConfigRecordFound"
		pass=$((pass + 1))
	else
		echo -e "  ${RED}✗${NC} Still present: .cloudConfigRecordFound"
		fail=$((fail + 1))
	fi

	# Check .AppleSetupDone
	if [ -f "$data_path/private/var/db/.AppleSetupDone" ]; then
		echo -e "  ${GRN}✓${NC} Setup marker: .AppleSetupDone"
		pass=$((pass + 1))
	else
		echo -e "  ${RED}✗${NC} Missing: .AppleSetupDone"
		fail=$((fail + 1))
	fi

	# Check user exists
	if check_user_exists "$dscl_path" "$username" >/dev/null 2>&1; then
		echo -e "  ${GRN}✓${NC} User account: $username"
		pass=$((pass + 1))
	else
		echo -e "  ${RED}✗${NC} User NOT created: $username"
		fail=$((fail + 1))
	fi

	# Check Guardian LaunchDaemon
	if [ -f "$system_path/Library/LaunchDaemons/$LAUNCHDAEMON_LABEL.plist" ]; then
		echo -e "  ${GRN}✓${NC} Guardian LaunchDaemon: installed"
		pass=$((pass + 1))
	else
		echo -e "  ${YEL}~${NC} Guardian LaunchDaemon: not installed (optional)"
	fi

	# Check Guardian script
	if [ -f "$system_path/$GUARDIAN_SCRIPT_PATH" ]; then
		echo -e "  ${GRN}✓${NC} Guardian script: installed"
		pass=$((pass + 1))
	else
		echo -e "  ${YEL}~${NC} Guardian script: not installed (optional)"
	fi

	# Check MDM daemon override plists
	local override_count=0
	local total_mdm_ids=$(( ${#MDM_DAEMONS[@]} + ${#MDM_AGENTS[@]} ))
	for ident in "${MDM_DAEMONS[@]}"; do
		[ -f "$system_path/Library/LaunchDaemons/${ident}.plist" ] && override_count=$((override_count + 1))
	done
	for ident in "${MDM_AGENTS[@]}"; do
		[ -f "$system_path/Library/LaunchAgents/${ident}.plist" ] && override_count=$((override_count + 1))
	done
	if [ $override_count -eq $total_mdm_ids ]; then
		echo -e "  ${GRN}✓${NC} MDM daemon overrides: $override_count/$total_mdm_ids installed"
		pass=$((pass + 1))
	elif [ $override_count -gt 0 ]; then
		echo -e "  ${YEL}~${NC} MDM daemon overrides: $override_count/$total_mdm_ids installed"
	else
		echo -e "  ${YEL}~${NC} MDM daemon overrides: not installed (optional)"
	fi

	echo ""
	log "INFO" "Verification: $pass passed, $fail failed"

	if [ $fail -gt 0 ]; then
		warn "$fail verification check(s) failed"
		return 1
	else
		success "All $pass verification checks passed"
		return 0
	fi
}

# ═══════════════════════════════════════════════════════════════
#  Rollback (v3 new) + Auto-Rollback Trap
# ═══════════════════════════════════════════════════════════════

_auto_rollback() {
	local lineno="${1:-unknown}"
	trap '' ERR
	log "ERROR" "Unhandled error at line $lineno — triggering auto-rollback"
	echo -e "${RED}ERROR: Unhandled failure at line $lineno${NC}" >&2
	if [ ${#COMPLETED_ACTIONS[@]} -gt 0 ]; then
		echo -e "${YEL}Auto-rolling back ${#COMPLETED_ACTIONS[@]} completed action(s)...${NC}" >&2
		do_rollback
	fi
	release_lock 2>/dev/null || true
	exit 1
}

offer_rollback() {
	echo ""
	warn "A critical step failed. The following actions were completed:"
	for action in "${COMPLETED_ACTIONS[@]}"; do
		echo -e "  ${YEL}• $action${NC}"
	done
	echo ""
	read -p "Would you like to rollback these changes? (y/n): " response
	if [[ "$response" =~ ^[Yy]$ ]]; then
		do_rollback
	else
		info "Keeping partial changes. Review the log at: $LOG_FILE"
	fi
}

do_rollback() {
	info "Rolling back changes..."

	# Process in reverse order
	local i
	for ((i = ${#COMPLETED_ACTIONS[@]} - 1; i >= 0; i--)); do
		local action="${COMPLETED_ACTIONS[$i]}"
		case "$action" in
		"cleanup_script")
			# Just informational, no critical rollback needed
			info "Cleanup script will be removed with user home directory"
			;;
		"launchdaemon")
			if [ -n "${system_path:-}" ]; then
				rm -f "$system_path/Library/LaunchDaemons/$LAUNCHDAEMON_LABEL.plist" 2>/dev/null && success "Rolled back: Guardian LaunchDaemon removed" || warn "Could not remove Guardian LaunchDaemon"
				rm -f "$system_path/$GUARDIAN_SCRIPT_PATH" 2>/dev/null && success "Rolled back: Guardian script removed" || warn "Could not remove Guardian script"
			fi
			;;
		"disable_daemons")
			if [ -n "${system_path:-}" ]; then
				for ident in "${MDM_DAEMONS[@]}"; do
					rm -f "$system_path/Library/LaunchDaemons/${ident}.plist" 2>/dev/null
				done
				for ident in "${MDM_AGENTS[@]}"; do
					rm -f "$system_path/Library/LaunchAgents/${ident}.plist" 2>/dev/null
				done
				success "Rolled back: MDM daemon override plists removed"
				# Restore disabled.plist from backup
				if [ -f "$BACKUP_DIR/disabled.plist.bak" ] && [ -n "${data_path:-}" ]; then
					cp "$BACKUP_DIR/disabled.plist.bak" "$data_path/private/var/db/com.apple.xpc.launchd/disabled.plist" 2>/dev/null && success "Rolled back: disabled.plist restored" || warn "Could not restore disabled.plist"
				fi
			fi
			;;
		"config_profiles")
			if [ -d "$BACKUP_DIR/ConfigurationProfiles-Settings" ] && [ -n "${system_path:-}" ]; then
				local config_path="$system_path/var/db/ConfigurationProfiles/Settings"
				rm -rf "$config_path" 2>/dev/null
				cp -a "$BACKUP_DIR/ConfigurationProfiles-Settings" "$config_path" 2>/dev/null && success "Rolled back: configuration profiles restored" || warn "Could not restore configuration profiles"
			fi
			;;
		"block_domains")
			if [ -f "$BACKUP_DIR/hosts.bak" ] && [ -n "${system_path:-}" ]; then
				cp "$BACKUP_DIR/hosts.bak" "$system_path/etc/hosts" 2>/dev/null && success "Rolled back: hosts file restored" || warn "Could not restore hosts file"
			fi
			;;
		"create_user")
			if [ -n "${dscl_path:-}" ] && [ -n "${username:-}" ]; then
				dscl -f "$dscl_path" localhost -delete "/Local/Default/Users/$username" 2>/dev/null && success "Rolled back: user '$username' removed" || warn "Could not remove user '$username'"
				if [ -n "${data_path:-}" ]; then
					rm -rf "$data_path/Users/$username" 2>/dev/null
				fi
			fi
			;;
		"rename_volume")
			if [ -n "$ORIGINAL_DATA_VOLUME" ]; then
				diskutil rename "Data" "$ORIGINAL_DATA_VOLUME" 2>/dev/null && success "Rolled back: volume renamed to '$ORIGINAL_DATA_VOLUME'" || warn "Could not rename volume back"
			fi
			;;
		esac
	done

	info "Rollback complete"
	log "INFO" "Rollback completed"
}

# ═══════════════════════════════════════════════════════════════
#  Summary Report (v3 new)
# ═══════════════════════════════════════════════════════════════

print_summary() {
	local system_path="$1"
	local data_path="$2"
	local username="$3"
	local passw="$4"
	local macos_version="$5"

	echo ""
	echo -e "${GRN}╔═══════════════════════════════════════════════════════╗${NC}"
	echo -e "${GRN}║         MDM Bypass Completed Successfully!           ║${NC}"
	echo -e "${GRN}╚═══════════════════════════════════════════════════════╝${NC}"
	echo ""

	if $DRY_RUN; then
		echo -e "${YEL}  *** DRY RUN - No changes were made ***${NC}"
		echo ""
	fi

	local total_mdm_ids=$(( ${#MDM_DAEMONS[@]} + ${#MDM_AGENTS[@]} ))
	echo -e "${CYAN}  Summary:${NC}"
	echo -e "  ├─ macOS Version:    $macos_version"
	echo -e "  ├─ Username:         ${YEL}$username${NC}"
	echo -e "  ├─ Password:         ${YEL}$passw${NC}"
	echo -e "  ├─ Domains Blocked:  ${#MDM_DOMAINS[@]}"
	echo -e "  ├─ Daemons Disabled: $total_mdm_ids (${#MDM_DAEMONS[@]} daemons + ${#MDM_AGENTS[@]} agents)"
	echo -e "  ├─ Guardian Daemon:  $LAUNCHDAEMON_LABEL (runs at boot + every hour)"
	echo -e "  ├─ Guardian Script:  /$GUARDIAN_SCRIPT_PATH"
	echo -e "  ├─ Cleanup Script:   ~/Desktop/cleanup-mdm-bypass.sh"
	echo -e "  ├─ Backup Location:  $BACKUP_DIR"
	echo -e "  └─ Log File:         $LOG_FILE"
	echo ""
	echo -e "${CYAN}  Blocked Domains:${NC}"
	for domain in "${MDM_DOMAINS[@]}"; do
		echo -e "    • $domain"
	done
	echo ""
	echo -e "${CYAN}  Next Steps:${NC}"
	echo -e "  1. Close this terminal window"
	echo -e "  2. Reboot your Mac"
	echo -e "  3. Login with username: ${YEL}$username${NC} and password: ${YEL}$passw${NC}"
	echo -e "  4. After login, flush DNS cache:"
	echo -e "     ${PUR}sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder${NC}"
	echo -e "  5. To undo the bypass later, run:"
	echo -e "     ${PUR}sudo bash ~/Desktop/cleanup-mdm-bypass.sh${NC}"
	echo ""

	log "INFO" "Bypass completed. User: $username, Domains blocked: ${#MDM_DOMAINS[@]}"
}

# ═══════════════════════════════════════════════════════════════
#  Header
# ═══════════════════════════════════════════════════════════════

print_header() {
	echo ""
	echo -e "${CYAN}╔═══════════════════════════════════════════════════════╗${NC}"
	echo -e "${CYAN}║   Bypass MDM v$VERSION - By Assaf Dori (assafdori.com)  ║${NC}"
	echo -e "${CYAN}╚═══════════════════════════════════════════════════════╝${NC}"
	echo ""
	if $DRY_RUN; then
		echo -e "${YEL}  *** DRY RUN MODE - No changes will be made ***${NC}"
		echo ""
	fi
}

# ═══════════════════════════════════════════════════════════════
#  Main
# ═══════════════════════════════════════════════════════════════

main() {
	# Parse arguments
	parse_args "$@"

	# Acquire execution lock
	acquire_lock

	# Initialize logging
	init_log

	# Log basic environment fingerprint
	log_environment_fingerprint "basic"

	# Set up ERR trap for auto-rollback
	trap '_auto_rollback $LINENO' ERR

	# Display header
	print_header

	# Step 1: Pre-flight
	progress "Pre-flight system checks"
	check_recovery_mode
	check_volumes_mounted

	# Step 2: Volume detection
	progress "Detecting volumes"
	volume_info=$(detect_volumes)
	system_volume=$(echo "$volume_info" | cut -d'|' -f1)
	data_volume=$(echo "$volume_info" | cut -d'|' -f2)
	success "System Volume: $system_volume"
	success "Data Volume: $data_volume"

	system_path="/Volumes/$system_volume"
	data_path="/Volumes/$data_volume"

	# Detect macOS version
	macos_version=$(detect_macos_version "$system_path")
	info "macOS version: $macos_version"
	echo ""

	# Log full environment fingerprint now that we have system_path
	log_environment_fingerprint "full" "$system_path"

	# Show menu
	PS3='Please enter your choice: '
	options=("Bypass MDM from Recovery" "System Diagnostics" "Reboot & Exit")
	select opt in "${options[@]}"; do
		case $opt in
		"Bypass MDM from Recovery")

			# Step 3: Rename data volume
			progress "Normalizing data volume name"
			do_rename_data_volume "$data_volume"
			data_volume="Data"
			data_path="/Volumes/$data_volume"

			# Validate critical paths
			info "Validating system paths..."
			if [ ! -d "$system_path" ]; then
				error_exit "System volume path does not exist: $system_path"
			fi
			if [ ! -d "$data_path" ]; then
				error_exit "Data volume path does not exist: $data_path"
			fi

			dscl_path="$data_path/private/var/db/dslocal/nodes/Default"
			if [ ! -d "$dscl_path" ]; then
				error_exit "Directory Services path does not exist: $dscl_path"
			fi
			config_path="$system_path/var/db/ConfigurationProfiles/Settings"
			success "All system paths validated"

			# Step 4: Idempotency check
			progress "Checking for existing bypass"
			bypass_status=$(check_existing_bypass "$system_path" "$data_path" "$dscl_path")
			if [ "$bypass_status" = "full" ]; then
				warn "Bypass appears to be fully applied already."
				read -p "Re-apply anyway? (y/n): " reapply
				if [[ ! "$reapply" =~ ^[Yy]$ ]]; then
					info "Exiting without changes."
					exit 0
				fi
			elif [ "$bypass_status" = "partial" ]; then
				info "Partial bypass detected. Will complete remaining steps."
			else
				info "No existing bypass detected. Proceeding with full setup."
			fi

			# Journal init (resume or start fresh)
			journal_init

			# Step 5: Create backups
			progress "Creating backups"
			create_backups "$system_path" "$config_path"

			# Step 6: Create user
			progress "Creating admin user account"
			echo -e "${CYAN}Creating Temporary Admin User${NC}"
			echo -e "${NC}Press Enter to use defaults (recommended)${NC}"

			# Get real name
			read -p "Enter Temporary Fullname (Default is 'Apple'): " realName
			realName="${realName:=Apple}"

			# Get and validate username
			while true; do
				read -p "Enter Temporary Username (Default is 'Apple'): " username
				username="${username:=Apple}"
				if validation_msg=$(validate_username "$username"); then
					break
				else
					warn "$validation_msg"
					echo -e "${YEL}Please try again or press Ctrl+C to exit${NC}"
				fi
			done

			# Check if user exists
			if check_user_exists "$dscl_path" "$username"; then
				warn "User '$username' already exists in the system"
				read -p "Do you want to use a different username? (y/n): " response
				if [[ "$response" =~ ^[Yy]$ ]]; then
					while true; do
						read -p "Enter a different username: " username
						if [ -z "$username" ]; then
							warn "Username cannot be empty"
							continue
						fi
						if validation_msg=$(validate_username "$username"); then
							if ! check_user_exists "$dscl_path" "$username"; then
								break
							else
								warn "User '$username' also exists. Try another name."
							fi
						else
							warn "$validation_msg"
						fi
					done
				else
					warn "Continuing with existing user '$username' (may cause conflicts)"
				fi
			fi

			# Get and validate password
			while true; do
				read -p "Enter Temporary Password (Default is '1234'): " passw
				passw="${passw:=1234}"
				if validation_msg=$(validate_password "$passw"); then
					break
				else
					warn "$validation_msg"
					echo -e "${YEL}Please try again or press Ctrl+C to exit${NC}"
				fi
			done
			echo ""

			# Find available UID
			info "Checking for available UID..."
			available_uid=$(find_available_uid "$dscl_path")
			if [ $? -eq 0 ] && [ "$available_uid" != "501" ]; then
				info "UID 501 is in use, using UID $available_uid instead"
			else
				available_uid="501"
			fi
			success "Using UID: $available_uid"

			do_create_user "$dscl_path" "$data_path" "$username" "$realName" "$passw" "$available_uid"

			# Step 7: Block domains
			progress "Blocking MDM enrollment domains"
			do_block_domains "$system_path"

			# Step 8: Config profiles
			progress "Configuring MDM bypass settings"
			do_config_profiles "$system_path" "$data_path"

			# Step 9: Disable MDM daemons
			progress "Disabling MDM daemons and agents"
			do_disable_mdm_daemons "$system_path" "$data_path"

			# Step 10: Persistence + cleanup
			progress "Installing guardian daemon and cleanup tools"
			do_create_launchdaemon "$system_path"
			do_generate_cleanup_script "$data_path" "$username"

			# Step 11: Verification
			progress "Verifying changes"
			if $DRY_RUN; then
				info "[DRY-RUN] Skipping verification (no changes were made)"
			elif ! verify_changes "$system_path" "$data_path" "$dscl_path" "$username"; then
				warn "Some verification checks failed. Review the log at $LOG_FILE"
			fi

			# Clean up journal on success
			rm -f "$JOURNAL_FILE" 2>/dev/null

			# Summary
			print_summary "$system_path" "$data_path" "$username" "$passw" "$macos_version"
			break
			;;
		"System Diagnostics")
			run_diagnostics
			;;
		"Reboot & Exit")
			echo ""
			info "Rebooting system..."
			reboot
			break
			;;
		*)
			echo -e "${RED}Invalid option $REPLY${NC}"
			;;
		esac
	done
}

main "$@"
