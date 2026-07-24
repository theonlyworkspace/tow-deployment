#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/prune-system-backups.sh [--output-dir DIR] [--journal-key-file PATH] [--dry-run]

Destroys managed encrypted backups at or beyond the expiry recorded in each
authenticated backup manifest. Legacy/unmanaged directories are never removed;
a warning reports how many such entries remain.

Configuration is resolved in order: flags, exported environment variables,
values read from the deployment .env beside compose.yaml, then derived
defaults. Set TOW_OPS_ENV_FILE to use another env file, or /dev/null to
disable loading.

Options:
  --output-dir DIR   Managed backup root. Default: backups
  --journal-key-file PATH
                       Manifest HMAC key. Defaults to
                       PRIVACY_LEDGER_HMAC_KEY_FILE.
  --journal-path PATH  Canonical ledger path used to locate the external
                       registry head. Defaults to PRIVACY_LEDGER_PATH.
  --registry-head-path PATH
                       Defaults to PRIVACY_BACKUP_REGISTRY_HEAD_PATH or beside
                       the canonical journal.
  --retention-days DAYS
                       Destruction deadline for crash-orphaned partial backups.
                       Default: PRIVACY_BACKUP_RETENTION_DAYS,
                       TOW_BACKUP_RETENTION_DAYS, or 30.
  --dry-run          Report expired backups without removing them.
  -h, --help         Show this help.
USAGE
}

output_dir="backups"
journal_key_file="${PRIVACY_LEDGER_HMAC_KEY_FILE:-}"
journal_path="${PRIVACY_LEDGER_PATH:-}"
registry_head_path="${PRIVACY_BACKUP_REGISTRY_HEAD_PATH:-}"
ledger_dir="${TOW_PRIVACY_LEDGER_DIR:-}"
dry_run=0
retention_days="${PRIVACY_BACKUP_RETENTION_DAYS:-${TOW_BACKUP_RETENTION_DAYS:-}}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir)
      output_dir="${2:?--output-dir requires a value}"
      shift 2
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    --journal-key-file)
      journal_key_file="${2:?--journal-key-file requires a value}"
      shift 2
      ;;
    --journal-path)
      journal_path="${2:?--journal-path requires a value}"
      shift 2
      ;;
    --registry-head-path)
      registry_head_path="${2:?--registry-head-path requires a value}"
      shift 2
      ;;
    --retention-days)
      retention_days="${2:?--retention-days requires a value}"
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
  printf '[prune] %s\n' "$*" >&2
  exit 1
}

# Fill still-unset configuration from the deployment .env without executing it.
# Precedence stays: flags > exported environment > .env values > defaults.
load_deployment_env() {
  local env_file="${TOW_OPS_ENV_FILE:-$repo_root/.env}"
  [[ -f "$env_file" ]] || return 0
  local line key value
  declare -A denv=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
    key="${BASH_REMATCH[2]}"
    value="${BASH_REMATCH[3]}"
    if [[ "$value" =~ ^\"(.*)\"$ || "$value" =~ ^\'(.*)\'$ ]]; then
      value="${BASH_REMATCH[1]}"
    fi
    denv["$key"]="$value"
  done < "$env_file"
  journal_path="${journal_path:-${denv[PRIVACY_LEDGER_PATH]:-}}"
  journal_key_file="${journal_key_file:-${denv[PRIVACY_LEDGER_HMAC_KEY_FILE]:-}}"
  registry_head_path="${registry_head_path:-${denv[PRIVACY_BACKUP_REGISTRY_HEAD_PATH]:-}}"
  retention_days="${retention_days:-${denv[PRIVACY_BACKUP_RETENTION_DAYS]:-${denv[TOW_BACKUP_RETENTION_DAYS]:-}}}"
  ledger_dir="${ledger_dir:-${denv[TOW_PRIVACY_LEDGER_DIR]:-}}"
  if [[ -z "${PRIVACY_LEDGER_HMAC_SECRET:-}" && -n "${denv[PRIVACY_LEDGER_HMAC_SECRET]:-}" ]]; then
    export PRIVACY_LEDGER_HMAC_SECRET="${denv[PRIVACY_LEDGER_HMAC_SECRET]}"
  fi
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$repo_root"

load_deployment_env
if [[ -n "$ledger_dir" && "$ledger_dir" != /* ]]; then
  ledger_dir="$repo_root/$ledger_dir"
fi
if [[ -z "$journal_path" && -n "$ledger_dir" ]]; then
  journal_path="$ledger_dir/erasure.jsonl"
fi
retention_days="${retention_days:-30}"
command -v python3 >/dev/null 2>&1 || fail "Python 3 is required for safe host-path validation."
command -v docker >/dev/null 2>&1 || fail "Docker is unavailable; refusing to inspect or destroy backups."
docker compose version >/dev/null 2>&1 || fail "Docker Compose is unavailable; refusing to inspect or destroy backups."
[[ "$retention_days" =~ ^[1-9][0-9]*$ ]] || fail "--retention-days must be a positive integer."
(( retention_days <= 30 )) || fail "--retention-days must not exceed 30."

if [[ "$output_dir" = /* ]]; then
  backup_root="$output_dir"
else
  backup_root="$repo_root/$output_dir"
fi
if ! backup_root="$(python3 -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).expanduser().resolve(strict=True))' "$backup_root" 2>/dev/null)"; then
  fail "The managed backup root must be an existing path."
fi

if [[ -n "$journal_path" ]]; then
  if ! journal_path="$(python3 -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).expanduser().resolve(strict=True))' "$journal_path" 2>/dev/null)"; then
    fail "The canonical privacy journal must be an existing path."
  fi
fi
if [[ -z "$registry_head_path" ]]; then
  [[ -n "$journal_path" ]] || fail "PRIVACY_LEDGER_PATH, --journal-path, or --registry-head-path is required."
  registry_head_path="$(dirname "$journal_path")/backup-registry.head.json"
fi
registry_head_path="$(python3 -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).expanduser().resolve())' "$registry_head_path")"
[[ -d "$(dirname "$registry_head_path")" ]] || fail "The monotonic backup-registry head parent directory must already exist."
if [[ -n "$journal_key_file" ]]; then
  if ! journal_key_file="$(python3 -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).expanduser().resolve(strict=True))' "$journal_key_file" 2>/dev/null)"; then
    fail "The privacy journal HMAC key file must be an existing path."
  fi
elif [[ -z "${PRIVACY_LEDGER_HMAC_SECRET:-}" ]]; then
  fail "A privacy journal HMAC key file or secret environment variable is required."
fi

for protected_path in "$journal_path" "$registry_head_path"; do
  [[ -n "$protected_path" ]] || continue
  case "$protected_path" in
    "$repo_root"|"$repo_root"/*)
      fail "The canonical privacy journal and registry head must live outside the restorable source/data tree."
      ;;
  esac
done

compose() {
  docker compose "$@"
}

# The pruner only ever destroys authenticated managed backups. Anything else in
# the backup root (legacy plaintext dumps, ad-hoc archives) stays forever, so
# surface it instead of letting unencrypted personal data linger silently.
warn_unmanaged_entries() {
  local entry name unmanaged=0
  for entry in "$backup_root"/* "$backup_root"/.*; do
    [[ -e "$entry" || -L "$entry" ]] || continue
    name="$(basename "$entry")"
    case "$name" in
      .|..|backup-registry.jsonl|backup-registry.head.json) continue ;;
    esac
    if [[ -d "$entry" && ! -L "$entry" ]]; then
      [[ -f "$entry/backup-manifest.json" ]] && continue
      case "$name" in
        .*.partial) continue ;;
      esac
    fi
    unmanaged=$((unmanaged + 1))
  done
  if [[ "$unmanaged" -gt 0 ]]; then
    printf '[prune] Warning: %s unmanaged entries in %s are outside retention management and were kept. Review and remove legacy or plaintext dumps manually.\n' \
      "$unmanaged" "$backup_root" >&2
  fi
}

backend_container="$(compose ps --all --quiet backend || true)"
if [[ -z "$backend_container" ]]; then
  compose create backend >/dev/null
  backend_container="$(compose ps --all --quiet backend || true)"
fi
[[ -n "$backend_container" ]] || fail "Could not resolve the backend service container."
backend_volume="$(
  docker inspect "$backend_container" \
    --format '{{range .Mounts}}{{if eq .Destination "/app/data"}}{{.Name}}{{end}}{{end}}'
)"
[[ -n "$backend_volume" ]] || fail "The backend /app/data named volume was not found."
backend_data_source="$(
  docker inspect "$backend_container" \
    --format '{{range .Mounts}}{{if eq .Destination "/app/data"}}{{.Source}}{{end}}{{end}}'
)"
if [[ -n "$backend_data_source" ]]; then
  for protected_path in "$journal_path" "$registry_head_path"; do
    [[ -n "$protected_path" ]] || continue
    case "$protected_path" in
      "$backend_data_source"|"$backend_data_source"/*)
        fail "The canonical privacy journal and registry head must live outside the /app/data restore domain."
        ;;
    esac
  done
fi

container_backup_root="/run/tow-ops/backups"
container_registry_head_dir="/run/tow-ops/registry-head"
container_registry_head="$container_registry_head_dir/$(basename "$registry_head_path")"
privacy_run_args=(run --rm --no-deps --no-TTY)
privacy_run_args+=(--volume "$backup_root:$container_backup_root")
privacy_run_args+=(--volume "$(dirname "$registry_head_path"):$container_registry_head_dir")
container_secret_args=()
if [[ -n "$journal_key_file" ]]; then
  container_key_file="/run/tow-ops/privacy-ledger-hmac.key"
  privacy_run_args+=(--volume "$journal_key_file:$container_key_file:ro")
  container_secret_args+=(--secret-file "$container_key_file")
else
  privacy_run_args+=(--env PRIVACY_LEDGER_HMAC_SECRET)
fi

privacy_cli() {
  compose "${privacy_run_args[@]}" backend \
    python -m app.scripts.privacy_backup "$@" "${container_secret_args[@]}"
}

registry_head_args=(--registry-head-path "$container_registry_head")
args=(prune --backup-root "$container_backup_root" "${registry_head_args[@]}" --partial-retention-days "$retention_days")
if [[ "$dry_run" -eq 1 ]]; then
  args+=(--dry-run)
  privacy_cli "${args[@]}"
  warn_unmanaged_entries
  exit 0
fi

database_run_args=(run --rm --no-deps --no-TTY)
database_secret_args=()
if [[ -n "$journal_key_file" ]]; then
  container_key_file="/run/tow-privacy/backup-manifest-hmac.key"
  database_run_args+=(--volume "$journal_key_file:$container_key_file:ro")
  database_secret_args+=(--secret-file "$container_key_file")
elif [[ -n "${PRIVACY_LEDGER_HMAC_SECRET:-}" ]]; then
  database_run_args+=(--env PRIVACY_LEDGER_HMAC_SECRET)
else
  printf 'A privacy journal HMAC key file or PRIVACY_LEDGER_HMAC_SECRET is required.\n' >&2
  exit 1
fi

registry_events_command() {
  privacy_cli registry-events "${registry_head_args[@]}" --backup-root "$container_backup_root"
}

sync_database_registry() {
  local registry_events="$1"
  docker compose "${database_run_args[@]}" backend \
  python -m app.scripts.privacy_backup \
  sync-database-registry --registry-file - "${database_secret_args[@]}" \
  <<< "$registry_events" \
  >/dev/null
}

printf '[prune] Preflighting authenticated registry and database synchronization.\n'
registry_events="$(registry_events_command)"
sync_database_registry "$registry_events"

set +e
privacy_cli "${args[@]}"
prune_status=$?
set -e

# The prune command continues past invalid directories and signs every
# successful destruction. Always project those receipts into the database,
# even when the aggregate command exits non-zero.
registry_events="$(registry_events_command)"
sync_database_registry "$registry_events"
warn_unmanaged_entries

if [[ "$prune_status" -ne 0 ]]; then
  printf '[prune] One or more backup directories were retained or failed; valid expired backups were processed and registry state was synchronized.\n' >&2
  exit "$prune_status"
fi
