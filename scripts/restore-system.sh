#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/restore-system.sh --backup DIR [options]

Restores a managed encrypted TOW backup without writing plaintext backup data
to the host. Application services remain offline until database migrations,
canonical privacy-erasure replay, replay checkpoint verification, and a full
Meilisearch rebuild all succeed. Backups that contain bundled Authentik state
are restored together with it.

Configuration is resolved in order: flags, exported environment variables,
values read from the deployment .env beside compose.yaml, then derived
defaults. Set TOW_OPS_ENV_FILE to use another env file, or /dev/null to
disable loading.

Required configuration:
  --backup DIR                    Managed backup directory
  --age-identity PATH             TOW_BACKUP_AGE_IDENTITY
  --journal-path PATH             PRIVACY_LEDGER_PATH
                                   Default: TOW_PRIVACY_LEDGER_DIR/erasure.jsonl
  --journal-key-file PATH         PRIVACY_LEDGER_HMAC_KEY_FILE
                                   (or PRIVACY_LEDGER_HMAC_SECRET)
  --registry-head-path PATH       PRIVACY_BACKUP_REGISTRY_HEAD_PATH
                                   Default: beside the canonical journal.

Options:
  --no-start                      Leave all application services stopped after
                                  successful verification.
  --skip-authentik                Restore only core application state from a
                                  backup that also contains Authentik state.
  -h, --help                      Show this help.
USAGE
}

backup_dir=""
age_identity="${TOW_BACKUP_AGE_IDENTITY:-}"
journal_path="${PRIVACY_LEDGER_PATH:-}"
journal_key_file="${PRIVACY_LEDGER_HMAC_KEY_FILE:-}"
registry_head_path="${PRIVACY_BACKUP_REGISTRY_HEAD_PATH:-}"
ledger_dir="${TOW_PRIVACY_LEDGER_DIR:-}"
start_after_restore=1
skip_authentik=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --backup)
      backup_dir="${2:?--backup requires a value}"
      shift 2
      ;;
    --age-identity)
      age_identity="${2:?--age-identity requires a value}"
      shift 2
      ;;
    --journal-path)
      journal_path="${2:?--journal-path requires a value}"
      shift 2
      ;;
    --journal-key-file)
      journal_key_file="${2:?--journal-key-file requires a value}"
      shift 2
      ;;
    --registry-head-path)
      registry_head_path="${2:?--registry-head-path requires a value}"
      shift 2
      ;;
    --no-start)
      start_after_restore=0
      shift
      ;;
    --skip-authentik)
      skip_authentik=1
      shift
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

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'Required command not found: %s\n' "$1" >&2
    exit 1
  fi
}

fail() {
  printf '[restore] %s\n' "$*" >&2
  exit 1
}

log() {
  printf '[restore] %s\n' "$*"
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
  age_identity="${age_identity:-${denv[TOW_BACKUP_AGE_IDENTITY]:-}}"
  journal_path="${journal_path:-${denv[PRIVACY_LEDGER_PATH]:-}}"
  journal_key_file="${journal_key_file:-${denv[PRIVACY_LEDGER_HMAC_KEY_FILE]:-}}"
  registry_head_path="${registry_head_path:-${denv[PRIVACY_BACKUP_REGISTRY_HEAD_PATH]:-}}"
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

require_cmd age
require_cmd docker
require_cmd python3
docker compose version >/dev/null 2>&1 || fail "Docker Compose is required."

[[ -n "$backup_dir" ]] || fail "--backup is required."
[[ -n "$age_identity" ]] || fail "An age identity is required."
[[ -n "$journal_path" ]] || fail "The canonical privacy journal path is required."
if [[ -z "$journal_key_file" && -z "${PRIVACY_LEDGER_HMAC_SECRET:-}" ]]; then
  fail "A privacy journal HMAC key file or secret environment variable is required."
fi

backup_dir="$(python3 -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).expanduser().resolve(strict=True))' "$backup_dir")"
journal_path="$(python3 -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).expanduser().resolve(strict=True))' "$journal_path")"
if [[ -z "$registry_head_path" ]]; then
  registry_head_path="$(dirname "$journal_path")/backup-registry.head.json"
fi
registry_head_path="$(python3 -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).expanduser().resolve())' "$registry_head_path")"
age_identity="$(python3 -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).expanduser().resolve(strict=True))' "$age_identity")"
if [[ -n "$journal_key_file" ]]; then
  journal_key_file="$(python3 -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).expanduser().resolve(strict=True))' "$journal_key_file")"
fi
[[ -d "$(dirname "$registry_head_path")" ]] || fail "The monotonic backup-registry head parent directory must already exist."
python3 -c '
import os
import stat
import sys

file_stat = os.stat(sys.argv[1], follow_symlinks=False)
if not stat.S_ISREG(file_stat.st_mode) or file_stat.st_mode & 0o077:
    raise SystemExit("age identity must be a regular file with no group/world permissions")
' "$age_identity"

case "$journal_path" in
  "$repo_root"|"$repo_root"/*)
    fail "The canonical privacy journal must live outside the restorable source/data tree."
    ;;
esac
case "$registry_head_path" in
  "$repo_root"|"$repo_root"/*)
    fail "The monotonic backup-registry head must live outside the restorable source/data tree."
    ;;
esac

compose() {
  docker compose "$@"
}

# Authentik services live behind the opt-in "authentik" Compose profile. Only
# these calls may activate it; plain compose() must never start that profile.
compose_ak() {
  docker compose --profile authentik "$@"
}

# Reject absolute paths, traversal, and non-file/dir entries in a tar stream.
tar_preflight_scan() {
  python3 -c '
import pathlib
import sys
import tarfile

with tarfile.open(fileobj=sys.stdin.buffer, mode="r|gz") as archive:
    for member in archive:
        path = pathlib.PurePosixPath(member.name)
        if path.is_absolute() or ".." in path.parts:
            raise SystemExit(f"unsafe archive path: {member.name}")
        if not (member.isdir() or member.isfile()):
            raise SystemExit(f"unsafe archive entry type: {member.name}")
'
}

# Re-emit a tar stream with neutral ownership and restrictive permissions,
# rejecting every unsafe path or entry type.
sanitized_tar_rewrite() {
  python3 -c '
import copy
import pathlib
import sys
import tarfile

with (
    tarfile.open(fileobj=sys.stdin.buffer, mode="r|gz") as source,
    tarfile.open(fileobj=sys.stdout.buffer, mode="w|") as destination,
):
    for member in source:
        path = pathlib.PurePosixPath(member.name)
        if path.is_absolute() or ".." in path.parts:
            raise SystemExit(f"unsafe archive path: {member.name}")
        if not (member.isdir() or member.isfile()):
            raise SystemExit(f"unsafe archive entry type: {member.name}")
        sanitized = copy.copy(member)
        sanitized.uid = 0
        sanitized.gid = 0
        sanitized.uname = ""
        sanitized.gname = ""
        sanitized.mode = 0o700 if member.isdir() else 0o600
        sanitized.pax_headers = {}
        if member.isdir():
            destination.addfile(sanitized)
            continue
        content = source.extractfile(member)
        if content is None:
            raise SystemExit(f"could not read archive member: {member.name}")
        destination.addfile(sanitized, content)
'
}

backup_root="$(dirname "$backup_dir")"
container_backup_root="/run/tow-ops/backups"
container_backup_dir="$container_backup_root/$(basename "$backup_dir")"
container_journal_dir="/run/tow-ops/journal"
container_registry_head_dir="/run/tow-ops/registry-head"
container_journal="$container_journal_dir/$(basename "$journal_path")"
container_registry_head="$container_registry_head_dir/$(basename "$registry_head_path")"
privacy_run_args=(run --rm --no-deps --no-TTY)
# Registry authentication takes an exclusive O_RDWR lock and may reconcile an
# authenticated append-ahead crash gap, so the backup root cannot be mounted
# read-only even though restore never removes backup bytes here.
privacy_run_args+=(--volume "$backup_root:$container_backup_root")
privacy_run_args+=(--volume "$(dirname "$journal_path"):$container_journal_dir:ro")
privacy_run_args+=(--volume "$(dirname "$registry_head_path"):$container_registry_head_dir")
ops_secret_args=()
if [[ -n "$journal_key_file" ]]; then
  ops_key_file="/run/tow-ops/privacy-ledger-hmac.key"
  privacy_run_args+=(--volume "$journal_key_file:$ops_key_file:ro")
  ops_secret_args+=(--secret-file "$ops_key_file")
else
  privacy_run_args+=(--env PRIVACY_LEDGER_HMAC_SECRET)
fi

privacy_cli() {
  compose "${privacy_run_args[@]}" backend \
    python -m app.scripts.privacy_backup "$@" "${ops_secret_args[@]}"
}

journal_args=(--journal-path "$container_journal")
registry_head_args=(--registry-head-path "$container_registry_head")

log "Authenticating the backup artifacts, expiry, and canonical journal ancestry"
privacy_cli verify-backup \
  "${journal_args[@]}" \
  --backup-dir "$container_backup_dir" \
  >/dev/null
log "Authenticating the monotonic managed-backup registry before destructive restore work"
registry_events="$(privacy_cli registry-events "${registry_head_args[@]}" --backup-root "$container_backup_root")"
python3 -c '
import hashlib
import json
import pathlib
import sys

events = json.loads(sys.stdin.read())
manifest_bytes = pathlib.Path(sys.argv[1]).read_bytes()
manifest = json.loads(manifest_bytes)
backup_id = manifest.get("backup_id")
manifest_digest = hashlib.sha256(manifest_bytes).hexdigest()
if not any(
    event.get("event") == "created"
    and event.get("backup_id") == backup_id
    and event.get("manifest_sha256") == manifest_digest
    and event.get("manifest_hmac") == manifest.get("manifest_hmac")
    for event in events
):
    raise SystemExit("the restored backup is absent from the authenticated monotonic registry")
' "$backup_dir/backup-manifest.json" <<< "$registry_events"

db_archive="$backup_dir/tow-db.dump.age"
data_archive="$backup_dir/backend-data-volume.tgz.age"

# The manifest was authenticated by verify-backup above; its artifact list is
# the source of truth for whether this backup carries bundled Authentik state.
authentik_artifact_names=(
  authentik-db.dump.age
  authentik-data-volume.tgz.age
  authentik-media-volume.tgz.age
  authentik-templates-volume.tgz.age
)
manifest_artifact_names="$(python3 -c '
import json
import pathlib
import sys

manifest = json.loads(pathlib.Path(sys.argv[1]).read_bytes())
for artifact in manifest.get("artifacts", []):
    print(artifact["name"])
' "$backup_dir/backup-manifest.json")"
backup_has_authentik=0
if grep -qFx 'authentik-db.dump.age' <<< "$manifest_artifact_names"; then
  for authentik_artifact in "${authentik_artifact_names[@]}"; do
    grep -qFx "$authentik_artifact" <<< "$manifest_artifact_names" ||
      fail "The backup lists Authentik state but is missing $authentik_artifact."
  done
  backup_has_authentik=1
fi

restore_authentik=0
if [[ "$backup_has_authentik" -eq 1 ]]; then
  if [[ "$skip_authentik" -eq 1 ]]; then
    log "Backup contains bundled Authentik state; restoring core services only by request (--skip-authentik)"
  else
    authentik_db_container="$(compose_ak ps --all --quiet authentik-db || true)"
    [[ -n "$authentik_db_container" ]] ||
      fail "This backup contains bundled Authentik state, but this deployment has no authentik profile services. Start the authentik profile first, or pass --skip-authentik to restore core services only."
    restore_authentik=1
  fi
elif [[ "$skip_authentik" -eq 0 ]]; then
  authentik_db_container="$(compose_ak ps --all --quiet authentik-db || true)"
  if [[ -n "$authentik_db_container" ]]; then
    log "Warning: this deployment uses the authentik profile, but the backup contains no Authentik state; Authentik will not be modified"
  fi
fi

db_container="$(compose ps --quiet db || true)"
[[ -n "$db_container" ]] || fail "A running Compose db service is required for restore validation."

log "Preflighting age authentication and PostgreSQL archive structure"
age --decrypt --identity "$age_identity" "$db_archive" |
  compose exec -T db pg_restore --list >/dev/null

log "Preflighting age authentication and safe backend archive paths"
age --decrypt --identity "$age_identity" "$data_archive" | tar_preflight_scan

authentik_volume_archives=(
  authentik-data-volume.tgz.age
  authentik-media-volume.tgz.age
  authentik-templates-volume.tgz.age
)
authentik_volume_destinations=(/data /data/media /templates)
authentik_data_layout_marker=".tow-authentik-data-layout-v1"
authentik_volume_names=()
if [[ "$restore_authentik" -eq 1 ]]; then
  authentik_db_running="$(compose_ak ps --quiet authentik-db || true)"
  [[ -n "$authentik_db_running" ]] || fail "A running authentik-db service is required to restore Authentik state."
  authentik_redis_running="$(compose_ak ps --quiet authentik-redis || true)"
  [[ -n "$authentik_redis_running" ]] || fail "A running authentik-redis service is required to restore Authentik state."

  log "Preflighting age authentication and Authentik PostgreSQL archive structure"
  age --decrypt --identity "$age_identity" "$backup_dir/authentik-db.dump.age" |
    compose_ak exec -T authentik-db pg_restore --list >/dev/null
  for authentik_archive_name in "${authentik_volume_archives[@]}"; do
    log "Preflighting age authentication and safe Authentik archive paths ($authentik_archive_name)"
    age --decrypt --identity "$age_identity" "$backup_dir/$authentik_archive_name" | tar_preflight_scan
  done

  authentik_server_container="$(compose_ak ps --all --quiet authentik-server || true)"
  if [[ -z "$authentik_server_container" ]]; then
    compose_ak create --no-deps authentik-server >/dev/null
    authentik_server_container="$(compose_ak ps --all --quiet authentik-server || true)"
  fi
  [[ -n "$authentik_server_container" ]] || fail "Could not resolve the authentik-server service container."
  for authentik_destination in "${authentik_volume_destinations[@]}"; do
    authentik_volume="$(
      docker inspect "$authentik_server_container" \
        --format "{{range .Mounts}}{{if eq .Destination \"$authentik_destination\"}}{{.Name}}{{end}}{{end}}"
    )"
    [[ -n "$authentik_volume" ]] || fail "The Authentik $authentik_destination named volume was not found."
    authentik_volume_names+=("$authentik_volume")
    authentik_volume_source="$(
      docker inspect "$authentik_server_container" \
        --format "{{range .Mounts}}{{if eq .Destination \"$authentik_destination\"}}{{.Source}}{{end}}{{end}}"
    )"
    if [[ -n "$authentik_volume_source" ]]; then
      for protected_path in "$journal_path" "$registry_head_path"; do
        case "$protected_path" in
          "$authentik_volume_source"|"$authentik_volume_source"/*)
            fail "The canonical privacy journal and registry head must live outside every Authentik restore domain."
            ;;
        esac
      done
    fi
  done
fi

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
    case "$protected_path" in
      "$backend_data_source"|"$backend_data_source"/*)
        fail "The canonical privacy journal and registry head must live outside the /app/data restore domain."
        ;;
    esac
  done
fi

offline=0
restore_failed() {
  if [[ "$offline" -eq 1 ]]; then
    printf '[restore] Restore failed; application services remain stopped. Correct the error and rerun restore.\n' >&2
  fi
}
trap restore_failed ERR

log "Stopping every application, schema job, and replica writer"
compose stop schema-migrate backend search-worker email-worker inbound-email-worker migration-worker frontend meilisearch >/dev/null
offline=1
if [[ "$restore_authentik" -eq 1 ]]; then
  log "Stopping Authentik application services"
  compose_ak stop authentik-server authentik-worker >/dev/null
fi

log "Replacing backend data while writers are offline"
docker run --rm --volume "$backend_volume:/data" alpine \
  sh -lc 'find /data -mindepth 1 -delete'
age --decrypt --identity "$age_identity" "$data_archive" |
  sanitized_tar_rewrite |
  docker run --rm --interactive --volume "$backend_volume:/data" alpine \
    sh -lc 'exec tar -C /data -xf - -o --no-same-permissions'

log "Replacing PostgreSQL while application services are offline"
compose exec -T db sh -lc 'exec dropdb -U "$POSTGRES_USER" --if-exists --force "$POSTGRES_DB"'
compose exec -T db sh -lc 'exec createdb -U "$POSTGRES_USER" -O "$POSTGRES_USER" "$POSTGRES_DB"'
age --decrypt --identity "$age_identity" "$db_archive" |
  compose exec -T db sh -lc 'exec pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" --exit-on-error'

if [[ "$restore_authentik" -eq 1 ]]; then
  log "Replacing Authentik volumes while its services are offline"
  for authentik_index in "${!authentik_volume_names[@]}"; do
    authentik_volume="${authentik_volume_names[$authentik_index]}"
    authentik_archive="$backup_dir/${authentik_volume_archives[$authentik_index]}"
    docker run --rm --volume "$authentik_volume:/data" alpine \
      sh -lc 'find /data -mindepth 1 -delete'
    age --decrypt --identity "$age_identity" "$authentik_archive" |
      sanitized_tar_rewrite |
      docker run --rm --interactive --volume "$authentik_volume:/data" alpine \
        sh -lc 'exec tar -C /data -xf - -o --no-same-permissions'
    if [[ "$authentik_index" -eq 0 ]]; then
      docker run --rm --volume "$authentik_volume:/data" alpine sh -lc '
        marker=/data/.tow-authentik-data-layout-v1
        if [ -e "$marker" ] || [ -L "$marker" ]; then
          [ -f "$marker" ] && [ ! -L "$marker" ] ||
            { printf "invalid Authentik data layout marker\n" >&2; exit 1; }
          [ "$(cat "$marker")" = "media-symlink=/media" ] ||
            { printf "unknown Authentik data layout marker\n" >&2; exit 1; }
          [ ! -e /data/media ] && [ ! -L /data/media ] ||
            { printf "refusing to replace an existing Authentik media path\n" >&2; exit 1; }
          rm -- "$marker"
          ln -s /media /data/media
        fi
      '
    fi
  done

  log "Replacing the Authentik PostgreSQL database while its services are offline"
  compose_ak exec -T authentik-db sh -lc 'exec dropdb -U "$POSTGRES_USER" --if-exists --force "$POSTGRES_DB"'
  compose_ak exec -T authentik-db sh -lc 'exec createdb -U "$POSTGRES_USER" -O "$POSTGRES_USER" "$POSTGRES_DB"'
  age --decrypt --identity "$age_identity" "$backup_dir/authentik-db.dump.age" |
    compose_ak exec -T authentik-db sh -lc 'exec pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" --exit-on-error'

  log "Flushing Authentik Redis sessions and cache after database replacement"
  compose_ak exec -T authentik-redis redis-cli FLUSHALL >/dev/null

  # The restored Authentik database predates any managed-account deletion that
  # happened after this backup was taken. The erasure replay below re-applies
  # those deletions through the Authentik API, so the API must be up before
  # replay runs — but only for replay: the public proxy stays stopped until
  # every restore gate has passed.
  log "Stopping the public proxy until replay has re-applied managed Authentik deletions"
  compose stop proxy >/dev/null
  log "Starting Authentik for managed-deletion replay"
  compose_ak up --detach --wait authentik-db authentik-redis authentik-server
fi

log "Migrating the restored database with the current application image"
compose run --rm --no-deps schema-migrate

container_journal="/run/tow-privacy/erasure.journal"
container_key="/run/tow-privacy/journal-hmac.key"
replay_run_args=(
  run --rm --no-deps
  --volume "$journal_path:$container_journal:ro"
)
container_secret_args=()
if [[ -n "$journal_key_file" ]]; then
  replay_run_args+=(--volume "$journal_key_file:$container_key:ro")
  container_secret_args+=(--secret-file "$container_key")
else
  if [[ -n "${PRIVACY_LEDGER_HMAC_SECRET:-}" ]]; then
    replay_run_args+=(--env PRIVACY_LEDGER_HMAC_SECRET)
  else
    fail "A privacy journal HMAC key file or PRIVACY_LEDGER_HMAC_SECRET is required."
  fi
fi
replay_command_args=(--journal-path "$container_journal" "${container_secret_args[@]}")

log "Registering the restored backup and reconciling its signed lifecycle registry"
compose "${replay_run_args[@]}" backend \
  python -m app.scripts.privacy_backup \
  register-database --manifest-file - \
  "${container_secret_args[@]}" \
  < "$backup_dir/backup-manifest.json" \
  >/dev/null
compose "${replay_run_args[@]}" backend \
  python -m app.scripts.privacy_backup \
  sync-database-registry --registry-file - \
  "${container_secret_args[@]}" \
  <<< "$registry_events" \
  >/dev/null

log "Starting only PostgreSQL and Meilisearch for erasure verification"
compose up --detach --wait db meilisearch

log "Replaying and verifying every canonical privacy erasure"
compose "${replay_run_args[@]}" backend \
  python -m app.scripts.replay_privacy_erasure_journal "${replay_command_args[@]}"

log "Reconstructing search replicas from the erased relational state"
compose run --rm --no-deps backend python -m app.scripts.rebuild_search_index

log "Rerunning all erasure handlers after search reconstruction"
compose "${replay_run_args[@]}" backend \
  python -m app.scripts.replay_privacy_erasure_journal \
  "${replay_command_args[@]}"

if [[ "$start_after_restore" -eq 1 ]]; then
  log "All restore gates passed; starting the application"
  if [[ "$restore_authentik" -eq 1 ]]; then
    compose_ak up --detach --wait
  fi
  compose up --detach --wait
  offline=0
else
  log "All restore gates passed; application services remain stopped by request"
fi

trap - ERR
log "Restore complete"
