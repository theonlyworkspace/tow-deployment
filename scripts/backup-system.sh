#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/backup-system.sh [options]

Creates an age-encrypted, managed backup of the running Docker Compose system.
The backup contains the PostgreSQL custom dump and backend /app/data volume,
plus the bundled Authentik database and volumes when that profile is in use.
Runtime secrets, source/Git state, Docker inspection output, and resolved
Compose configuration are deliberately excluded.

Configuration is resolved in order: flags, exported environment variables,
values read from the deployment .env beside compose.yaml, then derived
defaults. With a completed production .env no exports are needed. Set
TOW_OPS_ENV_FILE to use another env file, or /dev/null to disable loading.

Required configuration:
  --age-recipient RECIPIENT       PRIVACY_BACKUP_AGE_RECIPIENT
  --journal-path PATH             PRIVACY_LEDGER_PATH
                                   Default: TOW_PRIVACY_LEDGER_DIR/erasure.jsonl
  --journal-key-file PATH         PRIVACY_LEDGER_HMAC_KEY_FILE
                                   (or PRIVACY_LEDGER_HMAC_SECRET)
  --registry-head-path PATH       PRIVACY_BACKUP_REGISTRY_HEAD_PATH
                                   Default: beside the canonical journal.

Options:
  --label NAME                    Backup directory prefix. Default: system-backup
  --output-dir DIR                Managed backup root. Default: backups
  --retention-days DAYS           Destruction deadline. Default: 30
  --no-prune                      Do not prune older expired managed backups.
  --skip-authentik                Exclude bundled Authentik state even when the
                                  authentik profile is in use.
  -h, --help                      Show this help.
USAGE
}

label="system-backup"
output_dir="backups"
retention_days="${PRIVACY_BACKUP_RETENTION_DAYS:-${TOW_BACKUP_RETENTION_DAYS:-}}"
age_recipient="${PRIVACY_BACKUP_AGE_RECIPIENT:-${TOW_BACKUP_AGE_RECIPIENT:-}}"
journal_path="${PRIVACY_LEDGER_PATH:-}"
journal_key_file="${PRIVACY_LEDGER_HMAC_KEY_FILE:-}"
registry_head_path="${PRIVACY_BACKUP_REGISTRY_HEAD_PATH:-}"
ledger_dir="${TOW_PRIVACY_LEDGER_DIR:-}"
prune_after_backup=1
skip_authentik=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --label)
      label="${2:?--label requires a value}"
      shift 2
      ;;
    --output-dir)
      output_dir="${2:?--output-dir requires a value}"
      shift 2
      ;;
    --retention-days)
      retention_days="${2:?--retention-days requires a value}"
      shift 2
      ;;
    --age-recipient)
      age_recipient="${2:?--age-recipient requires a value}"
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
    --no-prune)
      prune_after_backup=0
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
  printf '[backup] %s\n' "$*" >&2
  exit 1
}

log() {
  printf '[backup] %s\n' "$*"
}

safe_name() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '-'
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
  age_recipient="${age_recipient:-${denv[PRIVACY_BACKUP_AGE_RECIPIENT]:-}}"
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

require_cmd age
require_cmd docker
require_cmd python3
require_cmd sha256sum
docker compose version >/dev/null 2>&1 || fail "Docker Compose is required."

[[ -n "$age_recipient" ]] || fail "An age recipient is required. Set PRIVACY_BACKUP_AGE_RECIPIENT or use --age-recipient."
[[ -n "$journal_path" ]] || fail "The canonical privacy journal path is required."
if [[ -z "$journal_key_file" && -z "${PRIVACY_LEDGER_HMAC_SECRET:-}" ]]; then
  fail "A privacy journal HMAC key file or secret environment variable is required."
fi
[[ "$retention_days" =~ ^[1-9][0-9]*$ ]] || fail "--retention-days must be a positive integer."
(( retention_days <= 30 )) || fail "--retention-days must not exceed 30."

if ! journal_path="$(python3 -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).expanduser().resolve(strict=True))' "$journal_path" 2>/dev/null)"; then
  fail "The canonical privacy journal must be an existing path."
fi
if [[ -z "$registry_head_path" ]]; then
  registry_head_path="$(dirname "$journal_path")/backup-registry.head.json"
fi
registry_head_path="$(python3 -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).expanduser().resolve())' "$registry_head_path")"
if [[ -n "$journal_key_file" ]]; then
  if ! journal_key_file="$(python3 -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).expanduser().resolve(strict=True))' "$journal_key_file" 2>/dev/null)"; then
    fail "The privacy journal HMAC key file must be an existing path."
  fi
fi
[[ -d "$(dirname "$registry_head_path")" ]] || fail "The monotonic backup-registry head parent directory must already exist."
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

if [[ "$output_dir" = /* ]]; then
  backup_root="$output_dir"
else
  backup_root="$repo_root/$output_dir"
fi
mkdir -p "$backup_root"
chmod 700 "$backup_root"
backup_root="$(python3 -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).resolve(strict=True))' "$backup_root")"

compose() {
  docker compose "$@"
}

# Authentik services live behind the opt-in "authentik" Compose profile. Only
# these calls may activate it; plain compose() must never start that profile.
compose_ak() {
  docker compose --profile authentik "$@"
}

container_backup_root="/run/tow-ops/backups"
container_journal_dir="/run/tow-ops/journal"
container_registry_head_dir="/run/tow-ops/registry-head"
container_journal="$container_journal_dir/$(basename "$journal_path")"
container_registry_head="$container_registry_head_dir/$(basename "$registry_head_path")"
privacy_run_args=(run --rm --no-deps --no-TTY)
privacy_run_args+=(--volume "$backup_root:$container_backup_root")
privacy_run_args+=(--volume "$(dirname "$journal_path"):$container_journal_dir:ro")
privacy_run_args+=(--volume "$(dirname "$registry_head_path"):$container_registry_head_dir")

privacy_cli() {
  compose "${privacy_run_args[@]}" backend \
    python -m app.scripts.privacy_backup "$@" "${container_secret_args[@]}"
}

container_secret_args=()
if [[ -n "$journal_key_file" ]]; then
  container_key_file="/run/tow-ops/privacy-ledger-hmac.key"
  privacy_run_args+=(--volume "$journal_key_file:$container_key_file:ro")
  container_secret_args+=(--secret-file "$container_key_file")
elif [[ -n "${PRIVACY_LEDGER_HMAC_SECRET:-}" ]]; then
  privacy_run_args+=(--env PRIVACY_LEDGER_HMAC_SECRET)
fi
journal_args=(--journal-path "$container_journal")
registry_head_args=(--registry-head-path "$container_registry_head")

log "Verifying the canonical privacy journal"
privacy_cli head "${journal_args[@]}" >/dev/null

# Validate the public recipient before creating any backup state.
printf '' | age --encrypt --recipient "$age_recipient" >/dev/null

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
backup_id="$(python3 -c 'from uuid import uuid4; print(uuid4())')"
backup_name="$(safe_name "$label")-$timestamp-${backup_id:0:8}"
backup_dir="$backup_root/$backup_name"
partial_dir="$backup_root/.${backup_name}.partial"
partial_created=0
finalized_unregistered=0
database_intent_active=0
managed_backup_exists=0
[[ ! -e "$backup_dir" && ! -L "$backup_dir" ]] || fail "Refusing to overwrite an existing backup path."

local_registry_contains_backup() {
  local events
  events="$(privacy_cli registry-events "${registry_head_args[@]}" --backup-root "$container_backup_root" 2>/dev/null)" || return 2
  python3 -c \
    'import json, sys; events = json.load(sys.stdin); raise SystemExit(0 if any(event.get("event") == "created" and event.get("backup_id") == sys.argv[1] for event in events) else 1)' \
    "$backup_id" <<< "$events"
}

cleanup_partial() {
  local exit_status=$?
  local registry_status=1
  local retained_bytes=0
  trap - EXIT
  set +e
  if [[ "$partial_created" -eq 1 && -d "$partial_dir" ]]; then
    rm -rf -- "$partial_dir"
  fi
  # A finalized directory is not retention-managed until its signed local
  # registry event is durable. Never leave an unregistered backup behind for
  # the conservative pruner to ignore indefinitely.
  if [[ "$finalized_unregistered" -eq 1 && "$managed_backup_exists" -eq 0 ]]; then
    local_registry_contains_backup
    registry_status=$?
    if [[ "$registry_status" -eq 0 ]]; then
      managed_backup_exists=1
      finalized_unregistered=0
    elif [[ "$registry_status" -eq 1 ]]; then
      if [[ -d "$backup_dir" ]]; then
        rm -rf -- "$backup_dir"
      fi
    else
      log "Could not authenticate the local backup registry; retaining backup bytes and intent for reconciliation."
      managed_backup_exists=1
    fi
  fi
  if [[ -e "$partial_dir" || -L "$partial_dir" || -e "$backup_dir" || -L "$backup_dir" ]]; then
    retained_bytes=1
  fi
  # Abandoning the database intent is safe only after every partial/final
  # artifact has been removed and before a signed local registry event exists.
  # If cleanup or acknowledgement is uncertain, retain the intent so erasures
  # continue to fail closed until an operator reconciles it.
  if [[ "$database_intent_active" -eq 1 && "$managed_backup_exists" -eq 0 && "$retained_bytes" -eq 0 ]]; then
    if database_privacy_cli abandon-database-backup --backup-id "$backup_id" >/dev/null; then
      database_intent_active=0
    else
      log "Could not abandon backup intent $backup_id; it remains fail-closed for operator reconciliation."
    fi
  fi
  exit "$exit_status"
}
trap cleanup_partial EXIT

mkdir "$partial_dir"
partial_created=1
chmod 700 "$partial_dir"

database_run_args=(run --rm --no-deps --no-TTY)
database_secret_args=()
if [[ -n "$journal_key_file" ]]; then
  container_key_file="/run/tow-privacy/backup-manifest-hmac.key"
  database_run_args+=(--volume "$journal_key_file:$container_key_file:ro")
  database_secret_args+=(--secret-file "$container_key_file")
elif [[ -n "${PRIVACY_LEDGER_HMAC_SECRET:-}" ]]; then
  database_run_args+=(--env PRIVACY_LEDGER_HMAC_SECRET)
else
  fail "A privacy journal HMAC key file or PRIVACY_LEDGER_HMAC_SECRET is required."
fi

database_privacy_cli() {
  compose "${database_run_args[@]}" backend \
    python -m app.scripts.privacy_backup "$@" "${database_secret_args[@]}"
}

db_container="$(compose ps --quiet db || true)"
[[ -n "$db_container" ]] || fail "No running Compose db service was found."

backend_container="$(compose ps --all --quiet backend || true)"
if [[ -z "$backend_container" ]]; then
  log "Creating a stopped backend container to resolve its data volume"
  compose create backend >/dev/null
  backend_container="$(compose ps --all --quiet backend || true)"
fi
[[ -n "$backend_container" ]] || fail "Could not resolve the backend service container."
backend_image="$(docker inspect "$backend_container" --format '{{.Config.Image}}')"
[[ -n "$backend_image" ]] || fail "Could not resolve the backend service image."

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

log "Scanning the backend data volume for unsupported archive entry types and hard links"
unsafe_archive_entry="$(
  docker run --rm --volume "$backend_volume:/data:ro" alpine \
    sh -lc 'find /data -xdev \( \( ! -type d ! -type f \) -o \( -type f -links +1 \) \) -print -quit'
)"
if [[ -n "$unsafe_archive_entry" ]]; then
  fail "The backend data volume contains a link, device, socket, multiply-linked file, or other unsupported entry (path suppressed)."
fi

authentik_active=0
authentik_volume_names=()
authentik_volume_layouts=()
authentik_volume_labels=(authentik-data authentik-media authentik-templates)
authentik_volume_destinations=(/data /data/media /templates)
authentik_data_layout_marker=".tow-authentik-data-layout-v1"
if [[ "$skip_authentik" -eq 1 ]]; then
  log "Excluding bundled Authentik state by request (--skip-authentik)"
else
  authentik_db_container="$(compose_ak ps --all --quiet authentik-db || true)"
  if [[ -z "$authentik_db_container" ]]; then
    log "No bundled Authentik profile detected; backing up core services only"
  else
    authentik_db_running="$(compose_ak ps --quiet authentik-db || true)"
    [[ -n "$authentik_db_running" ]] ||
      fail "The bundled Authentik database exists but is not running. Start the authentik profile or pass --skip-authentik."
    authentik_active=1
  fi
fi

if [[ "$authentik_active" -eq 1 ]]; then
  authentik_server_container="$(compose_ak ps --all --quiet authentik-server || true)"
  if [[ -z "$authentik_server_container" ]]; then
    log "Creating a stopped authentik-server container to resolve its volumes"
    compose_ak create --no-deps authentik-server >/dev/null
    authentik_server_container="$(compose_ak ps --all --quiet authentik-server || true)"
  fi
  [[ -n "$authentik_server_container" ]] || fail "Could not resolve the authentik-server service container."
  for authentik_index in "${!authentik_volume_destinations[@]}"; do
    authentik_destination="${authentik_volume_destinations[$authentik_index]}"
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
    log "Scanning the Authentik ${authentik_volume_labels[$authentik_index]#authentik-} volume for unsupported archive entry types and hard links"
    authentik_volume_layout="plain"
    if [[ "${authentik_volume_labels[$authentik_index]}" == "authentik-data" ]]; then
      # Authentik 2026.5 ships one structural link in /data:
      # /data/media -> /media. The separately mounted media volume owns the
      # target. Preserve the layout without placing a link in the archive:
      # record an authenticated regular-file marker and reconstruct the one
      # exact link during restore. Every other link remains forbidden.
      authentik_volume_layout="$(
        docker run --rm --volume "$authentik_volume:/data:ro" alpine sh -lc '
          marker=/data/.tow-authentik-data-layout-v1
          if [ -e "$marker" ] || [ -L "$marker" ]; then
            printf "unsafe\n"
          elif [ -L /data/media ] && [ "$(readlink /data/media)" = /media ]; then
            if find /data -xdev \
              \( \( ! -type d ! -type f \) -o \( -type f -links +1 \) \) \
              ! -path /data/media -print -quit | grep -q .; then
              printf "unsafe\n"
            else
              printf "media-symlink\n"
            fi
          elif find /data -xdev \
            \( \( ! -type d ! -type f \) -o \( -type f -links +1 \) \) \
            -print -quit | grep -q .; then
            printf "unsafe\n"
          else
            printf "plain\n"
          fi
        '
      )"
      [[ "$authentik_volume_layout" == "plain" || "$authentik_volume_layout" == "media-symlink" ]] \
        || fail "An Authentik volume contains a link, device, socket, multiply-linked file, or other unsupported entry (path suppressed)."
      unsafe_archive_entry=""
    else
      unsafe_archive_entry="$(
        docker run --rm --volume "$authentik_volume:/data:ro" alpine \
          sh -lc 'find /data -xdev \( \( ! -type d ! -type f \) -o \( -type f -links +1 \) \) -print -quit'
      )"
    fi
    if [[ -n "$unsafe_archive_entry" ]]; then
      fail "An Authentik volume contains a link, device, socket, multiply-linked file, or other unsupported entry (path suppressed)."
    fi
    authentik_volume_layouts+=("$authentik_volume_layout")
  done
fi

log "Registering the fail-closed backup intent before reading snapshot bytes"
database_privacy_cli begin-database-backup \
  --backup-id "$backup_id" \
  --created-at "$created_at" \
  --retention-days "$retention_days" \
  >/dev/null
database_intent_active=1

log "Streaming the PostgreSQL dump through age encryption"
compose exec -T db sh -lc 'exec pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc' |
  age --encrypt --recipient "$age_recipient" --output "$partial_dir/tow-db.dump.age"

log "Streaming the backend data volume through age encryption"
docker run --rm --volume "$backend_volume:/data:ro" alpine \
  sh -lc 'cd /data && exec tar -czf - .' |
  age --encrypt --recipient "$age_recipient" --output "$partial_dir/backend-data-volume.tgz.age"

artifact_files=(tow-db.dump.age backend-data-volume.tgz.age)
if [[ "$authentik_active" -eq 1 ]]; then
  log "Streaming the Authentik PostgreSQL dump through age encryption"
  compose_ak exec -T authentik-db sh -lc 'exec pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc' |
    age --encrypt --recipient "$age_recipient" --output "$partial_dir/authentik-db.dump.age"
  artifact_files+=(authentik-db.dump.age)
  for authentik_index in "${!authentik_volume_names[@]}"; do
    authentik_volume_label="${authentik_volume_labels[$authentik_index]}"
    log "Streaming the Authentik ${authentik_volume_label#authentik-} volume through age encryption"
    if [[ "${authentik_volume_layouts[$authentik_index]}" == "media-symlink" ]]; then
      layout_dir="$partial_dir/.authentik-data-layout"
      mkdir -m 0700 "$layout_dir"
      printf 'media-symlink=/media\n' > "$layout_dir/$authentik_data_layout_marker"
      chmod 0600 "$layout_dir/$authentik_data_layout_marker"
      docker run --rm \
        --volume "${authentik_volume_names[$authentik_index]}:/data:ro" \
        --volume "$layout_dir:/layout:ro" \
        --entrypoint tar \
        "$backend_image" \
        --exclude=./media -C /data -czf - . -C /layout "$authentik_data_layout_marker" |
        age --encrypt --recipient "$age_recipient" --output "$partial_dir/${authentik_volume_label}-volume.tgz.age"
      rm -rf -- "$layout_dir"
    else
      docker run --rm --volume "${authentik_volume_names[$authentik_index]}:/data:ro" alpine \
        sh -lc 'cd /data && exec tar -czf - .' |
        age --encrypt --recipient "$age_recipient" --output "$partial_dir/${authentik_volume_label}-volume.tgz.age"
    fi
    artifact_files+=("${authentik_volume_label}-volume.tgz.age")
  done
fi

manifest_artifact_args=()
for artifact_file in "${artifact_files[@]}"; do
  manifest_artifact_args+=(--artifact "$artifact_file")
done

privacy_cli create-manifest \
  "${journal_args[@]}" \
  --backup-dir "$container_backup_root/$(basename "$partial_dir")" \
  --backup-id "$backup_id" \
  --created-at "$created_at" \
  --retention-days "$retention_days" \
  "${manifest_artifact_args[@]}" \
  >/dev/null

(
  cd "$partial_dir"
  sha256sum "${artifact_files[@]}" backup-manifest.json > SHA256SUMS.txt
)

cat > "$partial_dir/README.txt" <<'README'
TOW managed encrypted backup
============================

This directory intentionally contains no .env file, resolved Compose config,
Docker inspection output, source tree, Git state, upload filenames, or plaintext
database/data dumps. Backups taken while the bundled Authentik profile is in
use also contain the encrypted Authentik database and volumes.

Do not decrypt these artifacts to disk. Use scripts/restore-system.sh, which
keeps application services offline until canonical privacy erasures have been
replayed and verified.
README

chmod 600 "$partial_dir"/*
mv --no-target-directory "$partial_dir" "$backup_dir"
partial_created=0
finalized_unregistered=1

privacy_cli register "${registry_head_args[@]}" \
  --backup-root "$container_backup_root" \
  --backup-dir "$container_backup_root/$(basename "$backup_dir")" \
  >/dev/null
finalized_unregistered=0
managed_backup_exists=1
database_privacy_cli register-database --manifest-file - < "$backup_dir/backup-manifest.json" >/dev/null
database_intent_active=0
trap - EXIT

if [[ "$prune_after_backup" -eq 1 ]]; then
  log "Preflighting signed registry synchronization before physical pruning"
  registry_events="$(privacy_cli registry-events "${registry_head_args[@]}" --backup-root "$container_backup_root")"
  database_privacy_cli sync-database-registry --registry-file - <<< "$registry_events" >/dev/null
  log "Pruning managed backups whose retention deadline has passed"
  set +e
  privacy_cli prune "${registry_head_args[@]}" \
    --backup-root "$container_backup_root" \
    --partial-retention-days "$retention_days"
  prune_status=$?
  set -e
  registry_events="$(privacy_cli registry-events "${registry_head_args[@]}" --backup-root "$container_backup_root")"
  database_privacy_cli sync-database-registry --registry-file - <<< "$registry_events" >/dev/null
  if [[ "$prune_status" -ne 0 ]]; then
    fail "One or more managed backup directories could not be authenticated or pruned; valid entries were still processed and registry state was synchronized."
  fi
fi

log "Backup complete: $backup_dir"
