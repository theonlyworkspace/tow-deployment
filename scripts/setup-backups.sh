#!/usr/bin/env bash
# One-command backup bootstrap for a TOW deployment.
#
# Wraps the existing tooling — nothing here reimplements backup logic:
#   1. Generates the age encryption key pair and records the public recipient
#      in .env (the private identity must be moved off this host).
#   2. Ensures the deletion-ledger directory exists and is configured.
#   3. Initializes the append-only deletion ledger (idempotent).
#   4. Takes the first encrypted backup (backup-system.sh).
#   5. Installs the daily backup and prune timers (install-backup-schedule.sh).
set -Eeuo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/setup-backups.sh [options]

Options:
  --output-dir DIR     Managed backup root. Default: /var/backups/tow
  --ledger-dir DIR     Deletion-ledger directory used when .env does not
                       already configure an absolute TOW_PRIVACY_LEDGER_DIR.
                       Default: /var/lib/tow-privacy
  --project-dir DIR    Deployment directory containing compose.yaml and .env.
                       Default: the parent of this script's directory.
  --skip-first-backup  Do not take a backup at the end of setup.
  --skip-timers        Do not install the systemd timers.
  --non-interactive    Never prompt; accept all defaults.
  -h, --help           Show this help.
USAGE
}

log() { printf '[setup-backups] %s\n' "$*"; }
warn() { printf '[setup-backups] WARNING: %s\n' "$*" >&2; }
fail() { printf '[setup-backups] ERROR: %s\n' "$*" >&2; exit 1; }

output_dir="/var/backups/tow"
ledger_dir="/var/lib/tow-privacy"
project_dir=""
skip_first_backup=0
skip_timers=0
non_interactive=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir) output_dir="${2:?--output-dir requires a value}"; shift 2 ;;
    --ledger-dir) ledger_dir="${2:?--ledger-dir requires a value}"; shift 2 ;;
    --project-dir) project_dir="${2:?--project-dir requires a value}"; shift 2 ;;
    --skip-first-backup) skip_first_backup=1; shift ;;
    --skip-timers) skip_timers=1; shift ;;
    --non-interactive) non_interactive=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
if [[ -z "$project_dir" ]]; then
  project_dir="$(cd "$script_dir/.." && pwd -P)"
fi

[[ "$output_dir" = /* ]] || fail "--output-dir must be an absolute path."
[[ "$ledger_dir" = /* ]] || fail "--ledger-dir must be an absolute path."
[[ -f "$project_dir/compose.yaml" ]] || fail "No compose.yaml in $project_dir; pass the deployment directory with --project-dir."
[[ -f "$project_dir/.env" ]] || fail "No .env in $project_dir; run ./install.sh first."
command -v docker >/dev/null 2>&1 || fail "Docker is required."
command -v python3 >/dev/null 2>&1 || fail "Python 3 is required."
command -v age-keygen >/dev/null 2>&1 || fail "age is required (apt install age / dnf install age)."

env_file="$project_dir/.env"
cd "$project_dir"

run_privileged() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    fail "Root privileges are needed for: $* (install sudo or re-run as root)"
  fi
}

read_env_key() {
  sed -n "s/^${1}=//p" "$env_file" | tail -n 1
}

set_env_key() {
  # set_env_key KEY VALUE — update in place, or append when the key is absent.
  python3 - "$env_file" "$1" "$2" <<'PY'
import pathlib
import re
import sys

path, key, value = sys.argv[1], sys.argv[2], sys.argv[3]
file = pathlib.Path(path)
lines = file.read_text(encoding="utf-8").splitlines()
pattern = re.compile(rf"^{re.escape(key)}=")
for index, line in enumerate(lines):
    if pattern.match(line):
        lines[index] = f"{key}={value}"
        break
else:
    lines.append(f"{key}={value}")
file.write_text("\n".join(lines) + "\n", encoding="utf-8")
PY
}

# ---------------------------------------------------------------------------
# 1. Backup encryption key
# ---------------------------------------------------------------------------

recipient="$(read_env_key PRIVACY_BACKUP_AGE_RECIPIENT)"
if [[ -n "$recipient" ]]; then
  log "PRIVACY_BACKUP_AGE_RECIPIENT is already set — keeping the existing key."
else
  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  identity_dir="$project_dir/secrets"
  identity_file="$identity_dir/tow-backup-age-identity-${timestamp}.txt"
  mkdir -p "$identity_dir"
  chmod 700 "$identity_dir"
  age-keygen -o "$identity_file"
  chmod 600 "$identity_file"
  recipient="$(sed -n 's/^# public key: //p' "$identity_file")"
  [[ "$recipient" == age1* ]] || fail "Could not extract the public key from $identity_file."
  set_env_key PRIVACY_BACKUP_AGE_RECIPIENT "$recipient"
  log "Recorded the public backup key in .env."
  printf '\n'
  warn "The PRIVATE key is in ${identity_file}."
  warn "Store it in your secrets manager and DELETE it from this host."
  warn "It is only needed to restore — a backup that can be decrypted in"
  warn "place protects nothing, and without the key backups are unrecoverable."
  printf '\n'
fi

# ---------------------------------------------------------------------------
# 2. Deletion-ledger directory
# ---------------------------------------------------------------------------

configured_ledger="$(read_env_key TOW_PRIVACY_LEDGER_DIR)"
if [[ -z "$configured_ledger" || "$configured_ledger" != /* ]]; then
  if [[ -n "$configured_ledger" ]]; then
    warn "TOW_PRIVACY_LEDGER_DIR is relative ($configured_ledger); production deployments need an absolute path outside the deployment directory."
  fi
  set_env_key TOW_PRIVACY_LEDGER_DIR "$ledger_dir"
  configured_ledger="$ledger_dir"
  log "Set TOW_PRIVACY_LEDGER_DIR=$ledger_dir in .env."
fi
if [[ ! -d "$configured_ledger" ]]; then
  if ! mkdir -p "$configured_ledger" 2>/dev/null; then
    run_privileged install -d -m 0700 "$configured_ledger"
  fi
fi

# Recreate the backend if it is already running so the ledger mount and the
# recipient value take effect.
if [[ -n "$(docker compose ps -q backend 2>/dev/null)" ]]; then
  log "Restarting the backend to apply the ledger configuration..."
  docker compose up -d --wait backend
fi

# ---------------------------------------------------------------------------
# 3. Initialize the deletion ledger (idempotent)
# ---------------------------------------------------------------------------

log "Initializing the deletion ledger (later runs just verify it)..."
docker compose run --rm --no-deps backend \
  python -m app.scripts.privacy_backup init \
  --journal-path /app/privacy-ledger/erasure.jsonl

# ---------------------------------------------------------------------------
# 4. First backup
# ---------------------------------------------------------------------------

if [[ $skip_first_backup -eq 1 ]]; then
  log "Skipping the first backup (--skip-first-backup)."
else
  log "Taking the first encrypted backup into ${output_dir}..."
  if [[ ! -d "$output_dir" ]]; then
    if ! mkdir -p "$output_dir" 2>/dev/null; then
      run_privileged install -d -m 0750 "$output_dir"
    fi
  fi
  "$script_dir/backup-system.sh" --output-dir "$output_dir"
fi

# ---------------------------------------------------------------------------
# 5. Daily timers
# ---------------------------------------------------------------------------

if [[ $skip_timers -eq 1 ]]; then
  log "Skipping timer installation (--skip-timers)."
elif ! command -v systemctl >/dev/null 2>&1; then
  warn "systemd is not available; schedule these two commands daily yourself:"
  warn "  $script_dir/backup-system.sh --output-dir $output_dir"
  warn "  $script_dir/prune-system-backups.sh --output-dir $output_dir"
else
  log "Installing the daily backup and prune timers (needs root)..."
  run_privileged "$script_dir/install-backup-schedule.sh" --output-dir "$output_dir" --project-dir "$project_dir"
fi

printf '\n'
log "Backups are set up. Verify with: systemctl list-timers 'tow-backup*'"
log "Do a restore drill before you need it: https://docs.tow.dev/deployment/backup-and-restore"
if [[ $non_interactive -eq 0 && -n "${identity_file:-}" ]]; then
  log "Reminder: move ${identity_file} off this host now."
fi
