#!/bin/bash
set -euo pipefail

# ═══════════════════════════════════════════════════════════════
#  MDM Bypass Hardener - Run on a live (already-bypassed) Mac
#  Prevents MDM re-enrollment across updates and reboots
#  Usage: sudo bash harden-mdm-bypass.sh [--dry-run|--status|--uninstall]
# ═══════════════════════════════════════════════════════════════

RED='\033[1;31m'
GRN='\033[1;32m'
BLU='\033[1;34m'
YEL='\033[1;33m'
PUR='\033[1;35m'
CYAN='\033[1;36m'
NC='\033[0m'

VERSION="1.1.0"
DRY_RUN=false
STATUS_ONLY=false
UNINSTALL=false

GUARDIAN_LABEL="com.bypass.mdmguardian"
GUARDIAN_PLIST="/Library/LaunchDaemons/${GUARDIAN_LABEL}.plist"
GUARDIAN_SCRIPT="/Library/Scripts/mdmguardian.sh"
WATCHER_LABEL="com.bypass.mdmwatcher"
WATCHER_PLIST="/Library/LaunchDaemons/${WATCHER_LABEL}.plist"
WATCHER_SCRIPT="/Library/Scripts/mdmwatcher.sh"
LOG_FILE="/var/log/mdm-hardener.log"
BACKUP_DIR="/var/backups/mdm-hardener"

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

# ── Output ──

log() {
	echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >>"$LOG_FILE" 2>/dev/null || true
}

info()    { log "INFO: $1";    echo -e "${BLU}ℹ $1${NC}"; }
success() { log "OK: $1";      echo -e "${GRN}✓ $1${NC}"; }
warn()    { log "WARN: $1";    echo -e "${YEL}⚠ $1${NC}"; }
fail()    { log "FAIL: $1";    echo -e "${RED}✗ $1${NC}"; }

# run <description> <command...>
# In dry-run mode, prints what would happen. Otherwise executes.
run() {
	local desc="$1"; shift
	if $DRY_RUN; then
		info "[DRY-RUN] $desc"
	else
		"$@"
	fi
}

# run_ok <message> — prints success only when NOT in dry-run
run_ok() {
	$DRY_RUN || success "$1"
}

# ── Resolve console user UID for agent domain ──

get_console_uid() {
	local console_user
	console_user=$(stat -f '%u' /dev/console 2>/dev/null) && echo "$console_user" && return
	id -u "${SUDO_USER:-}" 2>/dev/null && return
	echo "501"
}

CONSOLE_UID="$(get_console_uid)"

# ── Argument parsing ──

while [ $# -gt 0 ]; do
	case "$1" in
	--dry-run)    DRY_RUN=true; shift ;;
	--status)     STATUS_ONLY=true; shift ;;
	--uninstall)  UNINSTALL=true; shift ;;
	--help)
		echo "Usage: sudo bash harden-mdm-bypass.sh [OPTIONS]"
		echo ""
		echo "Options:"
		echo "  --dry-run     Show what would be done without making changes"
		echo "  --status      Check current hardening status and exit"
		echo "  --uninstall   Remove all hardening (unlock files, remove daemons)"
		echo "  --help        Show this help message"
		exit 0
		;;
	*) echo "Unknown option: $1"; exit 1 ;;
	esac
done

# ── Root check ──

if [ "$(id -u)" -ne 0 ]; then
	echo -e "${RED}This script must be run as root. Use: sudo bash $0${NC}"
	exit 1
fi

# ── SIP detection ──

SIP_ENABLED=true
if csrutil status 2>/dev/null | grep -q "disabled"; then
	SIP_ENABLED=false
fi

# ── ERR trap: re-lock schg flags if script fails mid-run ──

_emergency_relock() {
	local exit_code=$?
	if [ $exit_code -ne 0 ] && ! $DRY_RUN; then
		echo ""
		fail "Script failed (exit $exit_code) — attempting to re-lock modified files..."
		chflags schg /etc/hosts 2>/dev/null || true
		if ! $SIP_ENABLED; then
			chflags -R schg /var/db/ConfigurationProfiles/Settings 2>/dev/null || true
		fi
		warn "Files re-locked. Check $LOG_FILE for details."
		warn "Your backups are in $BACKUP_DIR"
	fi
}
trap _emergency_relock ERR

# ═══════════════════════════════════════════════════════════════
#  Status check
# ═══════════════════════════════════════════════════════════════

print_status() {
	echo ""
	echo -e "${CYAN}═══ MDM Bypass Hardening Status ═══${NC}"
	echo ""

	local pass=0 total=0

	# Hosts file
	total=$((total + 1))
	local blocked=0
	for domain in "${MDM_DOMAINS[@]}"; do
		grep -q "$domain" /etc/hosts 2>/dev/null && blocked=$((blocked + 1))
	done
	if [ $blocked -eq ${#MDM_DOMAINS[@]} ]; then
		success "Hosts: all ${#MDM_DOMAINS[@]} domains blocked"
		pass=$((pass + 1))
	elif [ $blocked -gt 0 ]; then
		warn "Hosts: $blocked/${#MDM_DOMAINS[@]} domains blocked"
	else
		fail "Hosts: no domains blocked"
	fi

	# Hosts file immutable
	total=$((total + 1))
	if ls -lO /etc/hosts 2>/dev/null | grep -q "schg"; then
		success "Hosts: system-immutable flag set (schg)"
		pass=$((pass + 1))
	else
		warn "Hosts: not immutable"
	fi

	# Config markers
	total=$((total + 1))
	local config_dir="/var/db/ConfigurationProfiles/Settings"
	if [ -f "$config_dir/.cloudConfigProfileInstalled" ] && [ -f "$config_dir/.cloudConfigRecordNotFound" ]; then
		success "Bypass markers: present"
		pass=$((pass + 1))
	else
		fail "Bypass markers: missing"
	fi

	# Activation records
	total=$((total + 1))
	if [ ! -f "$config_dir/.cloudConfigHasActivationRecord" ] && [ ! -f "$config_dir/.cloudConfigRecordFound" ]; then
		success "Activation records: cleared"
		pass=$((pass + 1))
	else
		fail "Activation records: still present"
	fi

	# Config dir immutable
	total=$((total + 1))
	if ls -lOd "$config_dir" 2>/dev/null | grep -q "schg"; then
		success "Config dir: system-immutable flag set (schg)"
		pass=$((pass + 1))
	else
		warn "Config dir: not immutable"
	fi

	# Daemons disabled
	total=$((total + 1))
	local disabled_count=0
	local disabled_plist="/private/var/db/com.apple.xpc.launchd/disabled.plist"
	if [ -f "$disabled_plist" ]; then
		for ident in "${MDM_DAEMONS[@]}" "${MDM_AGENTS[@]}"; do
			if defaults read "$disabled_plist" "$ident" 2>/dev/null | grep -q "1"; then
				disabled_count=$((disabled_count + 1))
			fi
		done
	fi
	local total_mdm=$(( ${#MDM_DAEMONS[@]} + ${#MDM_AGENTS[@]} ))
	if [ $disabled_count -eq $total_mdm ]; then
		success "Daemons: all $total_mdm disabled in launchd DB"
		pass=$((pass + 1))
	elif [ $disabled_count -gt 0 ]; then
		warn "Daemons: $disabled_count/$total_mdm disabled"
	else
		fail "Daemons: none disabled"
	fi

	# MDM processes
	total=$((total + 1))
	if ! pgrep -x "mdmclient" >/dev/null 2>&1; then
		success "Processes: mdmclient not running"
		pass=$((pass + 1))
	else
		fail "Processes: mdmclient is running"
	fi

	# Guardian daemon
	total=$((total + 1))
	if [ -f "$GUARDIAN_PLIST" ] && [ -f "$GUARDIAN_SCRIPT" ]; then
		success "Guardian daemon: installed"
		pass=$((pass + 1))
	else
		warn "Guardian daemon: not installed"
	fi

	# Watcher daemon
	total=$((total + 1))
	if [ -f "$WATCHER_PLIST" ] && [ -f "$WATCHER_SCRIPT" ]; then
		success "Watcher daemon: installed"
		pass=$((pass + 1))
	else
		warn "Watcher daemon: not installed"
	fi

	echo ""
	echo -e "${CYAN}Result: $pass/$total checks passed${NC}"
	echo ""
}

if $STATUS_ONLY; then
	print_status
	exit 0
fi

# ═══════════════════════════════════════════════════════════════
#  Uninstall
# ═══════════════════════════════════════════════════════════════

if $UNINSTALL; then
	echo ""
	echo -e "${CYAN}╔═══════════════════════════════════════════════════════╗${NC}"
	echo -e "${CYAN}║   MDM Bypass Hardener — Uninstall                    ║${NC}"
	echo -e "${CYAN}╚═══════════════════════════════════════════════════════╝${NC}"
	echo ""

	touch "$LOG_FILE" 2>/dev/null || true
	log "=== Uninstall started ==="

	# ── 1/8: Stop and remove guardian ──
	echo -e "${PUR}[1/8]${NC} ${CYAN}Removing guardian daemon${NC}"
	if launchctl bootout "system/${GUARDIAN_LABEL}" 2>/dev/null; then
		success "Guardian daemon unloaded"
	else
		info "Guardian daemon was not loaded"
	fi
	rm -f "$GUARDIAN_PLIST" "$GUARDIAN_SCRIPT"
	success "Guardian files removed"

	# ── 2/8: Stop and remove watcher ──
	echo -e "${PUR}[2/8]${NC} ${CYAN}Removing watcher daemon${NC}"
	if launchctl bootout "system/${WATCHER_LABEL}" 2>/dev/null; then
		success "Watcher daemon unloaded"
	else
		info "Watcher daemon was not loaded"
	fi
	rm -f "$WATCHER_PLIST" "$WATCHER_SCRIPT"
	success "Watcher files removed"

	# ── 3/8: Remove all immutable (schg) flags ──
	echo -e "${PUR}[3/8]${NC} ${CYAN}Removing immutable flags${NC}"
	chflags noschg /etc/hosts 2>/dev/null || true
	if ! $SIP_ENABLED; then
		chflags -R noschg /var/db/ConfigurationProfiles/Settings 2>/dev/null || true
	fi
	for ident in "${MDM_DAEMONS[@]}"; do
		chflags noschg "/Library/LaunchDaemons/${ident}.plist" 2>/dev/null || true
	done
	for ident in "${MDM_AGENTS[@]}"; do
		chflags noschg "/Library/LaunchAgents/${ident}.plist" 2>/dev/null || true
	done
	success "Immutable flags removed"

	# ── 4/8: Remove override plists ──
	echo -e "${PUR}[4/8]${NC} ${CYAN}Removing override plists${NC}"
	for ident in "${MDM_DAEMONS[@]}"; do
		rm -f "/Library/LaunchDaemons/${ident}.plist" 2>/dev/null || true
	done
	for ident in "${MDM_AGENTS[@]}"; do
		rm -f "/Library/LaunchAgents/${ident}.plist" 2>/dev/null || true
	done
	success "Override plists removed"

	# ── 5/8: Remove MDM domain blocks from /etc/hosts ──
	echo -e "${PUR}[5/8]${NC} ${CYAN}Removing MDM blocks from /etc/hosts${NC}"
	for domain in "${MDM_DOMAINS[@]}"; do
		sed -i '' "/0\\.0\\.0\\.0 ${domain}/d" /etc/hosts 2>/dev/null || true
	done
	success "MDM domain blocks removed from hosts"

	# ── 6/8: Re-enable MDM daemons/agents in launchctl + disabled.plist ──
	echo -e "${PUR}[6/8]${NC} ${CYAN}Re-enabling MDM daemons and agents${NC}"

	# Re-enable in launchctl runtime state
	for ident in "${MDM_DAEMONS[@]}"; do
		launchctl enable "system/$ident" 2>/dev/null || true
	done
	for ident in "${MDM_AGENTS[@]}"; do
		launchctl enable "system/$ident" 2>/dev/null || true
		launchctl enable "gui/$CONSOLE_UID/$ident" 2>/dev/null || true
	done

	# Remove entries from disabled.plist (restore from backup or patch)
	disabled_plist="/private/var/db/com.apple.xpc.launchd/disabled.plist"
	if [ -f "$BACKUP_DIR/disabled.plist.orig" ]; then
		cp -p "$BACKUP_DIR/disabled.plist.orig" "$disabled_plist" 2>/dev/null || true
		success "Restored original disabled.plist from backup"
	elif [ -f "$disabled_plist" ] && command -v python3 &>/dev/null; then
		all_idents=""
		for ident in "${MDM_DAEMONS[@]}" "${MDM_AGENTS[@]}"; do
			all_idents="$all_idents \"$ident\","
		done
		python3 -c "
import plistlib
path = '$disabled_plist'
try:
    with open(path, 'rb') as f:
        data = plistlib.load(f)
    for ident in [${all_idents}]:
        data.pop(ident, None)
    with open(path, 'wb') as f:
        plistlib.dump(data, f)
except Exception:
    pass
" 2>/dev/null && success "Removed MDM entries from disabled.plist" || warn "Could not update disabled.plist"
	else
		warn "Could not revert disabled.plist (no backup and no python3)"
	fi

	# ── 7/8: Remove bypass config markers ──
	echo -e "${PUR}[7/8]${NC} ${CYAN}Removing bypass config markers${NC}"
	config_dir="/var/db/ConfigurationProfiles/Settings"
	if $SIP_ENABLED; then
		warn "SIP enabled — cannot modify $config_dir on live OS"
		info "Config markers from Recovery Mode bypass are unaffected"
	else
		rm -f "$config_dir/.cloudConfigProfileInstalled" 2>/dev/null || true
		rm -f "$config_dir/.cloudConfigRecordNotFound" 2>/dev/null || true
		success "Bypass config markers removed"
	fi

	# ── 8/8: Flush DNS cache + restart MDM services ──
	echo -e "${PUR}[8/8]${NC} ${CYAN}Flushing DNS and restarting MDM services${NC}"

	# Flush DNS so stale 0.0.0.0 entries don't linger
	dscacheutil -flushcache 2>/dev/null || true
	killall -HUP mDNSResponder 2>/dev/null || true
	success "DNS cache flushed"

	# Kick-start MDM daemons so they resume without a reboot
	for ident in "${MDM_DAEMONS[@]}"; do
		launchctl kickstart -k "system/$ident" 2>/dev/null || true
	done
	for ident in "${MDM_AGENTS[@]}"; do
		launchctl kickstart -k "gui/$CONSOLE_UID/$ident" 2>/dev/null || true
	done
	info "MDM services restarted (or will start on next boot)"

	# ── Cleanup logs and backups ──
	echo ""
	echo -e "${CYAN}Cleanup:${NC}"
	rm -f /var/log/mdmguardian.log 2>/dev/null && success "Removed /var/log/mdmguardian.log" || info "No guardian log to remove"
	rm -f /var/log/mdm-hardener.log 2>/dev/null && success "Removed /var/log/mdm-hardener.log" || info "No hardener log to remove"
	if [ -d "$BACKUP_DIR" ]; then
		info "Backups preserved at $BACKUP_DIR (delete manually if not needed)"
		info "  To remove: sudo rm -rf $BACKUP_DIR"
	fi

	# ── Summary ──
	echo ""
	echo -e "${GRN}╔═══════════════════════════════════════════════════════╗${NC}"
	echo -e "${GRN}║         Uninstall Complete                           ║${NC}"
	echo -e "${GRN}╚═══════════════════════════════════════════════════════╝${NC}"
	echo ""
	echo -e "${CYAN}  What was reversed:${NC}"
	echo -e "  ├─ Guardian + watcher daemons stopped and removed"
	echo -e "  ├─ All immutable (schg) flags removed"
	echo -e "  ├─ Override plists deleted"
	echo -e "  ├─ MDM domain blocks removed from /etc/hosts"
	echo -e "  ├─ MDM daemons/agents re-enabled in launchctl + disabled.plist"
	if ! $SIP_ENABLED; then
		echo -e "  ├─ Bypass config markers deleted"
	else
		echo -e "  ├─ Bypass config markers: skipped (SIP protected)"
	fi
	echo -e "  ├─ DNS cache flushed"
	echo -e "  ├─ MDM services restarted"
	echo -e "  └─ Log files cleaned up"
	echo ""
	if $SIP_ENABLED; then
		warn "SIP is enabled — a reboot is recommended to fully restore MDM services"
	else
		info "All changes reversed. Reboot recommended but not required."
	fi
	echo ""
	exit 0
fi

# ═══════════════════════════════════════════════════════════════
#  Main hardening
# ═══════════════════════════════════════════════════════════════

echo ""
echo -e "${CYAN}╔═══════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║   MDM Bypass Hardener v${VERSION}                          ║${NC}"
echo -e "${CYAN}╚═══════════════════════════════════════════════════════╝${NC}"
echo ""
$DRY_RUN && echo -e "${YEL}  *** DRY RUN MODE ***${NC}" && echo ""

touch "$LOG_FILE" 2>/dev/null || true
log "=== Hardener v$VERSION started ==="

# ── Step 0: Backups ──

if ! $DRY_RUN; then
	mkdir -p "$BACKUP_DIR"
	if [ -f /etc/hosts ] && [ ! -f "$BACKUP_DIR/hosts.orig" ]; then
		cp -p /etc/hosts "$BACKUP_DIR/hosts.orig"
	fi
	# Always save a timestamped copy so we can diff later
	cp -p /etc/hosts "$BACKUP_DIR/hosts.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true

	config_settings="/var/db/ConfigurationProfiles/Settings"
	if [ -d "$config_settings" ] && [ ! -d "$BACKUP_DIR/Settings.orig" ]; then
		if ! $SIP_ENABLED; then
			chflags -R noschg "$config_settings" 2>/dev/null || true
		fi
		cp -Rp "$config_settings" "$BACKUP_DIR/Settings.orig" 2>/dev/null || true
		if ! $SIP_ENABLED; then
			chflags -R schg "$config_settings" 2>/dev/null || true
		fi
	fi

	disabled_plist_src="/private/var/db/com.apple.xpc.launchd/disabled.plist"
	if [ -f "$disabled_plist_src" ] && [ ! -f "$BACKUP_DIR/disabled.plist.orig" ]; then
		cp -p "$disabled_plist_src" "$BACKUP_DIR/disabled.plist.orig"
	fi
	success "Backups saved to $BACKUP_DIR"
else
	info "[DRY-RUN] Would back up hosts, ConfigurationProfiles/Settings, disabled.plist"
fi
echo ""

# ── Step 1: Kill any running MDM processes ──

echo -e "${PUR}[1/8]${NC} ${CYAN}Stopping MDM processes${NC}"

for proc in mdmclient ManagedClient cloudconfigurationd; do
	if pgrep -x "$proc" >/dev/null 2>&1; then
		run "Kill $proc" pkill -9 -x "$proc"
		run_ok "Killed $proc"
	else
		info "$proc not running"
	fi
done
echo ""

# ── Step 2: Block MDM domains in /etc/hosts ──

echo -e "${PUR}[2/8]${NC} ${CYAN}Blocking MDM domains in /etc/hosts${NC}"

# Remove immutable flag if present so we can edit
if ls -lO /etc/hosts 2>/dev/null | grep -q "schg"; then
	run "Remove schg from hosts" chflags noschg /etc/hosts
fi

added=0
for domain in "${MDM_DOMAINS[@]}"; do
	if ! grep -q "$domain" /etc/hosts 2>/dev/null; then
		if ! $DRY_RUN; then
			echo "0.0.0.0 $domain" >> /etc/hosts
		else
			info "[DRY-RUN] Block $domain"
		fi
		added=$((added + 1))
	fi
done
if [ $added -gt 0 ]; then
	run_ok "Added $added domain(s) to hosts"
else
	info "All domains already blocked"
fi

# Set immutable flag to prevent modifications
run "Set hosts immutable" chflags schg /etc/hosts
run_ok "Hosts file locked (system-immutable)"
echo ""

# ── Step 3: Configure bypass markers ──

echo -e "${PUR}[3/8]${NC} ${CYAN}Setting bypass configuration markers${NC}"

config_dir="/var/db/ConfigurationProfiles/Settings"

if $SIP_ENABLED; then
	warn "SIP is enabled — /var/db/ConfigurationProfiles is protected"
	info "Config markers will be set on a best-effort basis"
	info "To fully modify config markers, disable SIP from Recovery Mode"
fi

# Remove immutable if set from a previous run (only works with SIP off)
if [ -d "$config_dir" ] && ls -lOd "$config_dir" 2>/dev/null | grep -q "schg"; then
	run "Remove schg from config dir" chflags -R noschg "$config_dir" || true
fi

# All config marker operations are best-effort (SIP may block them)
if ! $DRY_RUN; then
	mkdir -p "$config_dir" 2>/dev/null || true
	rm -f "$config_dir/.cloudConfigHasActivationRecord" 2>/dev/null || true
	rm -f "$config_dir/.cloudConfigRecordFound" 2>/dev/null || true
	touch "$config_dir/.cloudConfigProfileInstalled" 2>/dev/null || true
	touch "$config_dir/.cloudConfigRecordNotFound" 2>/dev/null || true

	# Verify what actually succeeded
	local_ok=true
	if [ -f "$config_dir/.cloudConfigHasActivationRecord" ] || [ -f "$config_dir/.cloudConfigRecordFound" ]; then
		warn "Could not remove activation records (SIP protected)"
		local_ok=false
	fi
	if [ ! -f "$config_dir/.cloudConfigProfileInstalled" ] || [ ! -f "$config_dir/.cloudConfigRecordNotFound" ]; then
		warn "Could not create bypass markers (SIP protected)"
		local_ok=false
	fi

	if $local_ok; then
		# Lock the config directory (only if we could modify it)
		chflags -R schg "$config_dir" 2>/dev/null || true
		success "Configuration markers set and locked"
	else
		warn "Config markers skipped — SIP prevents modification on live OS"
		info "This is OK if markers were set during Recovery Mode bypass"
	fi
else
	info "[DRY-RUN] Would set bypass config markers in $config_dir"
fi
echo ""

# ── Step 4: Disable MDM daemons/agents in launchd ──

echo -e "${PUR}[4/8]${NC} ${CYAN}Disabling MDM daemons and agents${NC}"

# Unload daemons from system domain
for ident in "${MDM_DAEMONS[@]}"; do
	run "Bootout $ident" launchctl bootout "system/$ident" 2>/dev/null || true
done

# Disable agents in both system and GUI (user session) domains
for ident in "${MDM_AGENTS[@]}"; do
	run "Disable $ident (system)" launchctl disable "system/$ident" 2>/dev/null || true
	run "Disable $ident (gui/$CONSOLE_UID)" launchctl disable "gui/$CONSOLE_UID/$ident" 2>/dev/null || true
	run "Bootout $ident (gui/$CONSOLE_UID)" launchctl bootout "gui/$CONSOLE_UID/$ident" 2>/dev/null || true
done

# Update the launchd disabled.plist database
disabled_dir="/private/var/db/com.apple.xpc.launchd"
disabled_plist="$disabled_dir/disabled.plist"

if ! $DRY_RUN; then
	mkdir -p "$disabled_dir" 2>/dev/null || true
	if command -v python3 &>/dev/null; then
		all_idents=""
		for ident in "${MDM_DAEMONS[@]}" "${MDM_AGENTS[@]}"; do
			all_idents="$all_idents \"$ident\","
		done
		python3 -c "
import plistlib, os
path = '$disabled_plist'
try:
    with open(path, 'rb') as f:
        data = plistlib.load(f)
except (FileNotFoundError, plistlib.InvalidFileException, Exception) as e:
    data = {}
for ident in [${all_idents}]:
    data[ident] = True
with open(path, 'wb') as f:
    plistlib.dump(data, f)
" 2>/dev/null && success "Updated launchd disabled database" || warn "Could not update launchd disabled database"
	else
		# Fallback: use defaults command
		for ident in "${MDM_DAEMONS[@]}" "${MDM_AGENTS[@]}"; do
			defaults write "$disabled_plist" "$ident" -bool true 2>/dev/null || true
		done
		success "Updated launchd disabled database (via defaults)"
	fi
else
	info "[DRY-RUN] Would disable ${#MDM_DAEMONS[@]} daemons + ${#MDM_AGENTS[@]} agents in launchd DB"
fi
echo ""

# ── Step 5: Create override plists for MDM services ──

echo -e "${PUR}[5/8]${NC} ${CYAN}Creating disabled-override plists${NC}"

create_override_plist() {
	local dir="$1"
	local ident="$2"
	local plist_path="$dir/${ident}.plist"

	local content="<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">
<plist version=\"1.0\">
<dict>
	<key>Label</key>
	<string>${ident}</string>
	<key>Disabled</key>
	<true/>
	<key>ProgramArguments</key>
	<array>
		<string>/usr/bin/true</string>
	</array>
</dict>
</plist>"

	if $DRY_RUN; then
		info "[DRY-RUN] Would write override: $plist_path"
		return
	fi

	mkdir -p "$dir" 2>/dev/null || true
	# SIP may block writes to com.apple.* plists in /Library/Launch*
	if echo "$content" > "$plist_path" 2>/dev/null; then
		chmod 644 "$plist_path" 2>/dev/null || true
		chflags schg "$plist_path" 2>/dev/null || true
		return 0
	else
		return 1
	fi
}

override_ok=0
override_fail=0
for ident in "${MDM_DAEMONS[@]}"; do
	if create_override_plist "/Library/LaunchDaemons" "$ident"; then
		override_ok=$((override_ok + 1))
	else
		override_fail=$((override_fail + 1))
	fi
done
for ident in "${MDM_AGENTS[@]}"; do
	if create_override_plist "/Library/LaunchAgents" "$ident"; then
		override_ok=$((override_ok + 1))
	else
		override_fail=$((override_fail + 1))
	fi
done

if [ $override_fail -eq 0 ]; then
	run_ok "Override plists created and locked for all MDM services"
elif [ $override_ok -gt 0 ]; then
	warn "Created $override_ok override plists, $override_fail blocked by SIP"
else
	warn "SIP blocked all override plists — services disabled via launchctl instead"
	info "The launchctl disable + disabled.plist (step 4) is the primary mechanism"
fi
echo ""

# ── Step 6: Install guardian daemon (re-enforce every 5 min) ──

echo -e "${PUR}[6/8]${NC} ${CYAN}Installing guardian daemon${NC}"

# Build domain array for the guardian script
domain_array=""
for domain in "${MDM_DOMAINS[@]}"; do
	domain_array="${domain_array}	\"${domain}\"
"
done

daemon_array=""
for ident in "${MDM_DAEMONS[@]}"; do
	daemon_array="${daemon_array}	\"${ident}\"
"
done

agent_array=""
for ident in "${MDM_AGENTS[@]}"; do
	agent_array="${agent_array}	\"${ident}\"
"
done

guardian_script='#!/bin/bash
# MDM Guardian - auto-generated by harden-mdm-bypass.sh
# Runs every 5 minutes to re-enforce MDM bypass protections

LOG="/var/log/mdmguardian.log"
exec >> "$LOG" 2>&1
echo "[$(date "+%Y-%m-%d %H:%M:%S")] Guardian check starting..."

# ── Kill MDM processes ──
for proc in mdmclient ManagedClient cloudconfigurationd; do
	if pgrep -x "$proc" >/dev/null 2>&1; then
		pkill -9 -x "$proc" 2>/dev/null
		echo "[$(date "+%H:%M:%S")] Killed $proc"
	fi
done

# ── Re-enforce hosts blocks ──
MDM_DOMAINS=(
'"$domain_array"')

# Temporarily remove immutable flag
chflags noschg /etc/hosts 2>/dev/null

changed=false
for domain in "${MDM_DOMAINS[@]}"; do
	if ! grep -q "$domain" /etc/hosts 2>/dev/null; then
		echo "0.0.0.0 $domain" >> /etc/hosts
		echo "[$(date "+%H:%M:%S")] Re-blocked domain: $domain"
		changed=true
	fi
done

# Re-lock hosts file
chflags schg /etc/hosts 2>/dev/null

# ── Re-enforce config markers (best-effort — SIP may block) ──
CONFIG_DIR="/var/db/ConfigurationProfiles/Settings"
chflags -R noschg "$CONFIG_DIR" 2>/dev/null
mkdir -p "$CONFIG_DIR" 2>/dev/null

touch "$CONFIG_DIR/.cloudConfigProfileInstalled" 2>/dev/null || true
touch "$CONFIG_DIR/.cloudConfigRecordNotFound" 2>/dev/null || true
rm -f "$CONFIG_DIR/.cloudConfigHasActivationRecord" 2>/dev/null || true
rm -f "$CONFIG_DIR/.cloudConfigRecordFound" 2>/dev/null || true

# Only lock if we can (SIP off)
if chflags -R schg "$CONFIG_DIR" 2>/dev/null; then
	echo "[$(date "+%H:%M:%S")] Config dir locked"
fi

# ── Re-disable MDM daemons ──
MDM_DAEMONS=(
'"$daemon_array"')

MDM_AGENTS=(
'"$agent_array"')

for ident in "${MDM_DAEMONS[@]}"; do
	launchctl bootout "system/$ident" 2>/dev/null || true
done

# Disable agents in both system and GUI domains
CONSOLE_UID=$(stat -f "%u" /dev/console 2>/dev/null || echo "501")
for ident in "${MDM_AGENTS[@]}"; do
	launchctl disable "system/$ident" 2>/dev/null || true
	launchctl disable "gui/$CONSOLE_UID/$ident" 2>/dev/null || true
	launchctl bootout "gui/$CONSOLE_UID/$ident" 2>/dev/null || true
done

$changed && echo "[$(date "+%H:%M:%S")] Protections re-enforced" || echo "[$(date "+%H:%M:%S")] All protections intact"
'

guardian_plist="<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">
<plist version=\"1.0\">
<dict>
	<key>Label</key>
	<string>${GUARDIAN_LABEL}</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/bash</string>
		<string>${GUARDIAN_SCRIPT}</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>StartInterval</key>
	<integer>300</integer>
	<key>StandardOutPath</key>
	<string>/var/log/mdmguardian.log</string>
	<key>StandardErrorPath</key>
	<string>/var/log/mdmguardian.log</string>
</dict>
</plist>"

if ! $DRY_RUN; then
	mkdir -p "$(dirname "$GUARDIAN_SCRIPT")" 2>/dev/null
	echo "$guardian_script" > "$GUARDIAN_SCRIPT"
	chmod 755 "$GUARDIAN_SCRIPT"
	echo "$guardian_plist" > "$GUARDIAN_PLIST"
	chmod 644 "$GUARDIAN_PLIST"
	launchctl bootout "system/${GUARDIAN_LABEL}" 2>/dev/null || true
	launchctl bootstrap system "$GUARDIAN_PLIST" 2>/dev/null || launchctl load -w "$GUARDIAN_PLIST" 2>/dev/null || true
	success "Guardian installed (runs at boot + every 5 min)"
else
	info "[DRY-RUN] Would install guardian at $GUARDIAN_SCRIPT"
fi
echo ""

# ── Step 7: Install filesystem watcher ──

echo -e "${PUR}[7/8]${NC} ${CYAN}Installing filesystem watcher daemon${NC}"

watcher_script='#!/bin/bash
# MDM Watcher - triggers guardian immediately when MDM files change
# Uses periodic check since WatchPaths requires specific files

LOG="/var/log/mdmguardian.log"
exec >> "$LOG" 2>&1

CONFIG_DIR="/var/db/ConfigurationProfiles/Settings"

# Check if activation records reappeared
if [ -f "$CONFIG_DIR/.cloudConfigHasActivationRecord" ] || [ -f "$CONFIG_DIR/.cloudConfigRecordFound" ]; then
	echo "[$(date "+%Y-%m-%d %H:%M:%S")] ALERT: Activation records reappeared! Re-enforcing..."
	bash /Library/Scripts/mdmguardian.sh
fi

# Check if hosts file was tampered with
if ! grep -q "deviceenrollment.apple.com" /etc/hosts 2>/dev/null; then
	echo "[$(date "+%Y-%m-%d %H:%M:%S")] ALERT: Hosts file tampered! Re-enforcing..."
	bash /Library/Scripts/mdmguardian.sh
fi

# Check if mdmclient is running
if pgrep -x "mdmclient" >/dev/null 2>&1; then
	echo "[$(date "+%Y-%m-%d %H:%M:%S")] ALERT: mdmclient detected! Killing..."
	pkill -9 -x "mdmclient" 2>/dev/null
fi
'

watcher_plist="<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">
<plist version=\"1.0\">
<dict>
	<key>Label</key>
	<string>${WATCHER_LABEL}</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/bash</string>
		<string>${WATCHER_SCRIPT}</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>StartInterval</key>
	<integer>60</integer>
	<key>StandardOutPath</key>
	<string>/var/log/mdmguardian.log</string>
	<key>StandardErrorPath</key>
	<string>/var/log/mdmguardian.log</string>
</dict>
</plist>"

if ! $DRY_RUN; then
	mkdir -p "$(dirname "$WATCHER_SCRIPT")" 2>/dev/null
	echo "$watcher_script" > "$WATCHER_SCRIPT"
	chmod 755 "$WATCHER_SCRIPT"
	echo "$watcher_plist" > "$WATCHER_PLIST"
	chmod 644 "$WATCHER_PLIST"
	launchctl bootout "system/${WATCHER_LABEL}" 2>/dev/null || true
	launchctl bootstrap system "$WATCHER_PLIST" 2>/dev/null || launchctl load -w "$WATCHER_PLIST" 2>/dev/null || true
	success "Watcher installed (checks every 60s for tampering)"
else
	info "[DRY-RUN] Would install watcher at $WATCHER_SCRIPT"
fi
echo ""

# ── Step 8: Flush DNS cache ──

echo -e "${PUR}[8/8]${NC} ${CYAN}Flushing DNS cache${NC}"

if ! $DRY_RUN; then
	dscacheutil -flushcache 2>/dev/null || true
	killall -HUP mDNSResponder 2>/dev/null || true
	success "DNS cache flushed"
else
	info "[DRY-RUN] Would flush DNS cache"
fi
echo ""

# ── Summary ──

echo -e "${GRN}╔═══════════════════════════════════════════════════════╗${NC}"
echo -e "${GRN}║         MDM Bypass Hardening Complete!               ║${NC}"
echo -e "${GRN}╚═══════════════════════════════════════════════════════╝${NC}"
echo ""
if $DRY_RUN; then
	echo -e "${YEL}  *** DRY RUN - No changes were made ***${NC}"
	echo ""
fi
echo -e "${CYAN}  What was done:${NC}"
echo -e "  ├─ Backups saved to $BACKUP_DIR"
echo -e "  ├─ ${#MDM_DOMAINS[@]} MDM domains blocked in /etc/hosts (immutable)"
echo -e "  ├─ Bypass config markers set and locked (immutable)"
echo -e "  ├─ ${#MDM_DAEMONS[@]} daemons + ${#MDM_AGENTS[@]} agents disabled (system + gui/$CONSOLE_UID)"
echo -e "  ├─ Guardian daemon: runs at boot + every 5 min"
echo -e "  ├─ Watcher daemon: checks every 60s for tampering"
echo -e "  └─ DNS cache flushed"
echo ""
echo -e "${CYAN}  Installed files:${NC}"
echo -e "  ├─ $GUARDIAN_SCRIPT"
echo -e "  ├─ $GUARDIAN_PLIST"
echo -e "  ├─ $WATCHER_SCRIPT"
echo -e "  ├─ $WATCHER_PLIST"
echo -e "  └─ Log: /var/log/mdmguardian.log"
echo ""
echo -e "${CYAN}  Commands:${NC}"
echo -e "  ├─ Check status:  ${PUR}sudo bash harden-mdm-bypass.sh --status${NC}"
echo -e "  ├─ View log:      ${PUR}tail -f /var/log/mdmguardian.log${NC}"
echo -e "  ├─ Uninstall:     ${PUR}sudo bash harden-mdm-bypass.sh --uninstall${NC}"
echo -e "  └─ Re-run:        ${PUR}sudo bash harden-mdm-bypass.sh${NC} (safe to re-run)"
echo ""

log "=== Hardening complete ==="
