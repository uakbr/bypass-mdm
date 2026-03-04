# bypass-mdm

macOS MDM (Mobile Device Management) bypass tool. Three standalone bash scripts run from macOS Recovery Mode to create a local admin user, block MDM enrollment domains, and disable MDM services.

## Scripts

| Script | Role | Notes |
|---|---|---|
| `bypass-mdm.sh` | v1 legacy | Hardcoded "Macintosh HD" paths, UID 501, 3 domains, no error handling |
| `bypass-mdm-v2.sh` | v2 enhanced | Auto-detects volumes, input validation, available UID search, duplicate checks |
| `bypass-mdm-v3.sh` | v3 production (3.2.0) | Everything in v2 plus: transaction journal, atomic ops, backup/rollback, daemon disabling, guardian persistence, idempotency detection, verification pass, cleanup script generation, `--dry-run`/`--diagnostics` flags |

## Running

No build step or dependencies. Execute directly from Recovery Mode terminal:

```bash
# v3 (recommended)
bash bypass-mdm-v3.sh
bash bypass-mdm-v3.sh --dry-run       # preview changes without modifying anything
bash bypass-mdm-v3.sh --diagnostics   # inspect system state without making changes
bash bypass-mdm-v3.sh --version
bash bypass-mdm-v3.sh --help
```

There are no tests. The `--dry-run` flag is the closest thing to a test harness.

## v3 Architecture

### 11-step main workflow

1. Pre-flight system checks (Recovery Mode, dscl availability)
2. Volume detection (system + data volumes via multi-strategy fallback)
3. Normalize data volume name (rename to "Data")
4. Validate critical paths (system volume, data volume, dscl path)
5. Check for existing bypass (idempotency — skip if already done)
6. Create backups (hosts, ConfigurationProfiles/Settings, disabled.plist)
7. Collect user input (username, password with validation)
8. Create local admin user via dscl
9. Block MDM domains in /etc/hosts + disable MDM daemons/agents
10. Configure bypass markers + install guardian LaunchDaemon
11. Verification pass + summary report + cleanup script generation

### Key subsystems

- **Transaction journal** (`/tmp/mdm-bypass.journal`): BEGIN/COMMIT log per action. Enables resume on re-run — committed steps are skipped.
- **Atomic file ops**: `atomic_write()` and `atomic_append()` write to `.tmp.$$` then `mv` to target. Prevents partial writes.
- **Backup/rollback**: Pre-change backups to `/tmp/mdm-bypass-backup/`. On failure, `offer_rollback()` or `_auto_rollback()` (ERR trap) reverses completed actions in LIFO order.
- **Guardian persistence**: LaunchDaemon (`com.bypass.mdmguardian`) runs `Library/Scripts/mdmguardian.sh` at boot + every 3600s to re-enforce domain blocks, config markers, and kill mdmclient.
- **Idempotency**: `check_existing_bypass()` scans for existing artifacts before acting. Each `do_*` function checks the journal before executing.
- **Verification**: Post-bypass checklist confirms all domains blocked, markers present, activation records removed, user created, daemon overrides installed.
- **Execution lock**: `mkdir`-based lock at `/tmp/mdm-bypass.lock` with stale-PID detection.
- **Checksum audit**: SHA-256 of modified files logged before/after changes.

## System files modified

| Path | What happens |
|---|---|
| `/Volumes/<System>/etc/hosts` | MDM domains appended as `0.0.0.0` entries |
| `/Volumes/<System>/var/db/ConfigurationProfiles/Settings/` | `.cloudConfigHasActivationRecord` and `.cloudConfigRecordFound` removed; `.cloudConfigProfileInstalled` and `.cloudConfigRecordNotFound` created |
| `/Volumes/<Data>/private/var/db/.AppleSetupDone` | Created (marks setup complete) |
| `/Volumes/<Data>/private/var/db/dslocal/nodes/Default/` | New user record via dscl |
| `/Volumes/<System>/Library/LaunchDaemons/` | Override plists for MDM daemons + guardian plist (v3) |
| `/Volumes/<System>/Library/LaunchAgents/` | Override plists for MDM agents (v3) |
| `/Volumes/<Data>/private/var/db/com.apple.xpc.launchd/disabled.plist` | MDM identifiers set to disabled via python3 plistlib (v3) |
| `/Volumes/<System>/Library/Scripts/mdmguardian.sh` | Guardian script (v3) |

## MDM domains blocked (v3: 8 domains, v1/v2: 3)

```
deviceenrollment.apple.com
mdmenrollment.apple.com
iprofiles.apple.com
acmdm.apple.com
albert.apple.com
gateway.push.apple.com
setup.icloud.com
identity.apple.com
```

## MDM daemons/agents disabled (v3 only)

**Daemons:** `com.apple.mdmclient.daemon`, `com.apple.ManagedClient.enroll`, `com.apple.ManagedClient.cloudconfigurationd`, `com.apple.cloudconfigurationd`, `com.apple.mdmclient.daemon.runatboot`

**Agents:** `com.apple.mdmclient.agent`, `com.apple.ManagedClient.agent`

## Shell conventions

- **Color codes**: `RED`, `GRN`, `BLU`, `YEL`, `PUR`, `CYAN`, `NC` — defined identically in all three scripts
- **Output functions** (v2/v3): `error_exit()`, `warn()`, `success()`, `info()` — prefixed with colored symbols. v3 adds `progress()` for step headers and `log()` for file logging.
- **Validation**: `validate_username()` (alphanumeric + `_-`, max 31 chars, must start with letter/underscore), `validate_password()` (min 4 chars)
- **Volume detection**: Multi-strategy — looks for `/System` dir, then data volume by name patterns. Shared between v2 and v3.
- **v3 strict mode**: `set -euo pipefail` with ERR trap for auto-rollback
