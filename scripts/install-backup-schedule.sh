#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/install-backup-schedule.sh --output-dir DIR [options]

Installs and enables systemd timers that run the managed encrypted backup and
its retention pruning every day. Re-running the installer updates the units in
place.

Required configuration:
  --output-dir DIR    Managed backup root passed to the backup and prune
                      scripts. Use an absolute path such as /var/backups/tow.

Options:
  --project-dir DIR   Deployment directory containing compose.yaml and
                      scripts/. Default: the parent of this script's directory.
  --backup-time SPEC  systemd OnCalendar value for backup creation.
                      Default: *-*-* 03:15:00 UTC
  --prune-time SPEC   systemd OnCalendar value for retention pruning.
                      Default: *-*-* 04:05:00 UTC
  --unit-dir DIR      systemd unit directory. Default: /etc/systemd/system
  -h, --help          Show this help.
USAGE
}

output_dir=""
project_dir=""
backup_time="*-*-* 03:15:00 UTC"
prune_time="*-*-* 04:05:00 UTC"
unit_dir="/etc/systemd/system"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir)
      output_dir="${2:?--output-dir requires a value}"
      shift 2
      ;;
    --project-dir)
      project_dir="${2:?--project-dir requires a value}"
      shift 2
      ;;
    --backup-time)
      backup_time="${2:?--backup-time requires a value}"
      shift 2
      ;;
    --prune-time)
      prune_time="${2:?--prune-time requires a value}"
      shift 2
      ;;
    --unit-dir)
      unit_dir="${2:?--unit-dir requires a value}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown option: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

fail() {
  printf '[install-backup-schedule] %s\n' "$*" >&2
  exit 1
}

log() {
  printf '[install-backup-schedule] %s\n' "$*"
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
if [[ -z "$project_dir" ]]; then
  project_dir="$(cd "$script_dir/.." && pwd -P)"
fi

[[ -n "$output_dir" ]] || fail "--output-dir is required. Use an absolute path such as /var/backups/tow."
[[ "$output_dir" = /* ]] || fail "--output-dir must be an absolute path."
[[ "$project_dir" = /* ]] || fail "--project-dir must be an absolute path."
[[ -f "$project_dir/compose.yaml" ]] || fail "No compose.yaml in $project_dir; pass the deployment directory with --project-dir."
[[ -x "$project_dir/scripts/backup-system.sh" ]] || fail "No executable scripts/backup-system.sh in $project_dir; extract the ops scripts first."
[[ -x "$project_dir/scripts/prune-system-backups.sh" ]] || fail "No executable scripts/prune-system-backups.sh in $project_dir; extract the ops scripts first."
command -v systemctl >/dev/null 2>&1 || fail "systemctl is required; this installer only supports systemd hosts."
if [[ "$unit_dir" == /etc/systemd/system && "$(id -u)" -ne 0 ]]; then
  fail "Run as root (sudo) to install units into /etc/systemd/system."
fi
[[ -d "$unit_dir" ]] || fail "The systemd unit directory $unit_dir does not exist."

# The unit templates ship beside the repository's deploy/ tree and inside the
# image-extracted ops directory (scripts/systemd after extraction).
template_dir=""
for candidate in "$project_dir/deploy/systemd" "$script_dir/systemd"; do
  if [[ -f "$candidate/tow-backup.service" ]]; then
    template_dir="$candidate"
    break
  fi
done
[[ -n "$template_dir" ]] || fail "Could not find the tow-backup systemd unit templates in $project_dir/deploy/systemd or $script_dir/systemd."

env_file="$project_dir/.env"
if [[ -f "$env_file" ]]; then
  for required_key in PRIVACY_BACKUP_AGE_RECIPIENT PRIVACY_LEDGER_HMAC_SECRET TOW_PRIVACY_LEDGER_DIR; do
    if ! grep -Eq "^[[:space:]]*(export[[:space:]]+)?${required_key}=..*" "$env_file"; then
      log "Warning: $required_key looks unset in $env_file; scheduled backups will fail until it is configured."
    fi
  done
else
  log "Warning: no .env in $project_dir; scheduled backups will fail until the deployment is configured."
fi

render_unit() {
  local template="$1" destination="$2"
  python3 - "$template" "$destination" "$project_dir" "$output_dir" "$backup_time" "$prune_time" <<'PY'
import pathlib
import re
import sys

template, destination, project_dir, backup_root, backup_time, prune_time = sys.argv[1:7]
content = pathlib.Path(template).read_text()
content = content.replace("@PROJECT_DIR@", project_dir)
content = content.replace("@BACKUP_ROOT@", backup_root)
content = content.replace("@BACKUP_ONCALENDAR@", backup_time)
content = content.replace("@PRUNE_ONCALENDAR@", prune_time)
leftover = re.search(r"@[A-Z_]+@", content)
if leftover:
    raise SystemExit(f"unit template has an unreplaced placeholder: {leftover.group(0)}")
pathlib.Path(destination).write_text(content)
PY
}

command -v python3 >/dev/null 2>&1 || fail "Python 3 is required to render the unit files."

for unit in tow-backup.service tow-backup.timer tow-backup-prune.service tow-backup-prune.timer; do
  [[ -f "$template_dir/$unit" ]] || fail "Missing unit template: $template_dir/$unit"
  render_unit "$template_dir/$unit" "$unit_dir/$unit"
  chmod 644 "$unit_dir/$unit"
  log "Installed $unit_dir/$unit"
done

systemctl daemon-reload
systemctl enable --now tow-backup.timer tow-backup-prune.timer
log "Backup and prune timers are enabled:"
systemctl list-timers 'tow-backup*' --no-pager || true
log "Run 'journalctl -u tow-backup.service' to see backup output."
