#!/usr/bin/env bash
# Guided setup for permanent account deletion (GDPR erasure).
#
# Walks through the attestations deletion needs — retention policy name,
# backup coverage, email relay retention, AI provider retention, optional
# managed-authentik deletion — writes them into config/tow.yaml, runs the
# privacy backfill, checks readiness, and only then enables deletion so
# admins can accept deletion requests at any time.
#
# Requires backups to be set up first (scripts/setup-backups.sh): deletion
# requests can only complete once every backup holding the old data has been
# destroyed on schedule.
set -Eeuo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/setup-erasure.sh [options]

Interactive by default. Every prompt has a matching flag for unattended use.

Options:
  --policy REF           Name/version of your data-retention policy, stamped
                         into deletion evidence (e.g. data-retention-2026).
  --bundled-only-backups Attest that the bundled encrypted backups are the
                         ONLY backup system holding TOW data. Required in
                         --non-interactive mode; there is no default.
  --relay-retention-days N
                         Your SMTP relay's retention window in days (only
                         used when email transport is smtp). Default: 30
  --openai zdr|bounded_retention|none
                         Retention declaration for the configured AI route
                         when OPENAI_API_KEY is set. Default: bounded_retention
  --retention-days N     Provider retention window for bounded_retention.
                         Default: 30
  --managed-authentik-deletion
                         Also delete TOW-managed accounts inside the bundled
                         authentik (never corporate LDAP/SAML/OIDC accounts).
  --authentik-event-retention-days N
                         Configure and require authentik event retention (1-30).
                         Default: 30
  --configure-only       Write config/tow.yaml and stop: no backfill, no
                         readiness check, deletion NOT enabled.
  --project-dir DIR      Deployment directory. Default: the parent of this
                         script's directory.
  --non-interactive      Never prompt; fail when a required value is missing.
  -h, --help             Show this help.
USAGE
}

log() { printf '[setup-erasure] %s\n' "$*"; }
warn() { printf '[setup-erasure] WARNING: %s\n' "$*" >&2; }
fail() { printf '[setup-erasure] ERROR: %s\n' "$*" >&2; exit 1; }

policy=""
bundled_only=0
relay_retention_days=""
openai_mode=""
retention_days="30"
managed_authentik=""
authentik_event_retention_days="30"
configure_only=0
project_dir=""
non_interactive=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --policy) policy="${2:?--policy requires a value}"; shift 2 ;;
    --bundled-only-backups) bundled_only=1; shift ;;
    --relay-retention-days) relay_retention_days="${2:?--relay-retention-days requires a value}"; shift 2 ;;
    --openai) openai_mode="${2:?--openai requires zdr, bounded_retention, or none}"; shift 2 ;;
    --retention-days) retention_days="${2:?--retention-days requires a value}"; shift 2 ;;
    --managed-authentik-deletion) managed_authentik="yes"; shift ;;
    --authentik-event-retention-days) authentik_event_retention_days="${2:?value required}"; shift 2 ;;
    --configure-only) configure_only=1; shift ;;
    --project-dir) project_dir="${2:?--project-dir requires a value}"; shift 2 ;;
    --non-interactive) non_interactive=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
if [[ -z "$project_dir" ]]; then
  project_dir="$(cd "$script_dir/.." && pwd -P)"
fi

[[ -f "$project_dir/compose.yaml" ]] || fail "No compose.yaml in $project_dir; pass the deployment directory with --project-dir."
[[ -f "$project_dir/.env" ]] || fail "No .env in $project_dir; run ./install.sh first."
[[ -f "$project_dir/config/tow.yaml" ]] || fail "No config/tow.yaml in $project_dir; run ./install.sh first."
command -v python3 >/dev/null 2>&1 || fail "Python 3 is required."
if [[ $configure_only -eq 0 ]]; then
  command -v docker >/dev/null 2>&1 || fail "Docker is required."
fi

env_file="$project_dir/.env"
yaml_file="$project_dir/config/tow.yaml"
cd "$project_dir"

read_env_key() {
  sed -n "s/^${1}=//p" "$env_file" | tail -n 1
}

read_yaml_value() {
  # read_yaml_value INDENT KEY -> first value at that exact indentation
  sed -n "s/^${1}${2}: *//p" "$yaml_file" | head -n 1
}

# ---------------------------------------------------------------------------
# Prerequisites: deletion is built on the backup and ledger machinery
# ---------------------------------------------------------------------------

for key in PRIVACY_IDENTITY_HMAC_SECRET PRIVACY_LEDGER_HMAC_SECRET PRIVACY_BACKUP_AGE_RECIPIENT; do
  [[ -n "$(read_env_key "$key")" ]] \
    || fail "$key is not set in .env. Run scripts/setup-backups.sh first — deletion cannot work without encrypted backups and the deletion ledger."
done
ledger_dir="$(read_env_key TOW_PRIVACY_LEDGER_DIR)"
[[ "$ledger_dir" = /* ]] \
  || fail "TOW_PRIVACY_LEDGER_DIR must be an absolute path (run scripts/setup-backups.sh first)."
if command -v systemctl >/dev/null 2>&1; then
  if ! systemctl is-enabled --quiet tow-backup-prune.timer 2>/dev/null; then
    warn "The tow-backup-prune.timer does not look enabled. Deletion requests"
    warn "only complete when pruning destroys expired backups on schedule;"
    warn "run scripts/setup-backups.sh (or install-backup-schedule.sh)."
  fi
fi

email_transport="$(read_yaml_value '  ' transport)"
auth_mode="$(read_yaml_value '  ' mode)"
oidc_issuer="$(read_yaml_value '    ' issuer)"
openai_base_url="$(read_env_key OPENAI_BASE_URL)"
[[ -n "$openai_base_url" ]] || openai_base_url="$(read_yaml_value '  ' openai_base_url)"
existing_policy="$(read_yaml_value '  ' policy_reference)"
openai_key="$(read_env_key OPENAI_API_KEY)"
compose_profiles="$(read_env_key COMPOSE_PROFILES)"
processor_key="$(
  python3 - "$openai_base_url" <<'PY'
import sys
from urllib.parse import urlsplit

base_url = sys.argv[1].strip()
if not base_url:
    print("openai")
else:
    hostname = (urlsplit(base_url).hostname or "").lower()
    if hostname == "api.openai.com" or hostname.endswith(".openai.com"):
        print("openai")
    elif hostname == "openrouter.ai" or hostname.endswith(".openrouter.ai"):
        print("openrouter")
    else:
        print(f"custom:{hostname or 'unknown'}")
PY
)"

# ---------------------------------------------------------------------------
# Questions
# ---------------------------------------------------------------------------

if [[ $non_interactive -eq 0 ]]; then
  printf '\nPermanent account deletion ("right to erasure") setup. TOW handles the\n'
  printf 'deletion mechanics and evidence; the answers below are attestations\n'
  printf 'about YOUR deployment that end up in that evidence. Answer accurately.\n\n'
fi

if [[ -z "$policy" ]]; then
  default_policy="${existing_policy:-data-retention-$(date -u +%Y)}"
  if [[ $non_interactive -eq 1 ]]; then
    fail "--policy is required with --non-interactive."
  fi
  read -r -p "Name or version of your data-retention policy [${default_policy}]: " policy
  policy="${policy:-$default_policy}"
fi

if [[ $bundled_only -eq 0 ]]; then
  if [[ $non_interactive -eq 1 ]]; then
    fail "--bundled-only-backups is required with --non-interactive (the backup-coverage attestation has no default)."
  fi
  printf '\nAre the bundled encrypted backups (scripts/backup-system.sh and its\n'
  printf 'timers) the ONLY backup system that holds TOW data? Database dumps,\n'
  printf 'volume snapshots, and VM images all count as backup systems.\n'
  read -r -p "Bundled backups are the only backup system [y/N]: " reply
  case "$reply" in
    y|Y|yes|YES|Yes) bundled_only=1 ;;
    *)
      fail "Deletion with external backup systems needs the external_contract declaration, which this script does not write. See https://docs.tow.dev/deployment/user-deactivation-and-erasure#backup-coverage-and-the-deletion-ledger"
      ;;
  esac
fi

if [[ "$email_transport" == "smtp" && -z "$relay_retention_days" ]]; then
  if [[ $non_interactive -eq 1 ]]; then
    relay_retention_days="30"
  else
    printf '\nYour email goes through an SMTP relay. How many days does the relay\n'
    printf 'retain messages after delivery? (Check your provider'\''s documentation.)\n'
    read -r -p "Relay retention window in days [30]: " relay_retention_days
    relay_retention_days="${relay_retention_days:-30}"
  fi
fi
if [[ "$email_transport" != "smtp" && $non_interactive -eq 0 ]]; then
  warn "Email transport is '${email_transport:-console}', so users will not receive"
  warn "deletion cancellation emails — an admin can always cancel a scheduled"
  warn "request instead. Configure SMTP for the full self-service flow."
fi

if [[ -n "$openai_key" && -z "$openai_mode" ]]; then
  if [[ $non_interactive -eq 1 ]]; then
    openai_mode="bounded_retention"
  else
    printf '\nAn AI API key is configured for the %s route. How does that processor\n' "$processor_key"
    printf 'retain your request data? Declare zdr only when account-level\n'
    printf 'guardrails or your contract enforce zero data retention; otherwise\n'
    printf 'declare the bounded retention window.\n'
    read -r -p "Zero-data-retention policy for ${processor_key}? [y/N]: " reply
    case "$reply" in
      y|Y|yes|YES|Yes) openai_mode="zdr" ;;
      *)
        openai_mode="bounded_retention"
        read -r -p "Provider retention window in days [${retention_days}]: " reply
        retention_days="${reply:-$retention_days}"
        ;;
    esac
  fi
fi
[[ -z "$openai_key" ]] && openai_mode="none"
case "$openai_mode" in
  zdr|bounded_retention|none) ;;
  *) fail "--openai must be zdr, bounded_retention, or none." ;;
esac

if [[ "$auth_mode" == "oidc" && "$compose_profiles" == *authentik* && -z "$managed_authentik" ]]; then
  if [[ $non_interactive -eq 1 ]]; then
    managed_authentik="no"
  else
    printf '\nThis deployment runs the bundled authentik. Should deletion also\n'
    printf 'remove the account inside authentik? This applies only to accounts\n'
    printf 'TOW provisioned there — corporate LDAP/SAML/OIDC source accounts are\n'
    printf 'never deleted.\n'
    read -r -p "Delete TOW-managed authentik accounts too? [y/N]: " reply
    case "$reply" in
      y|Y|yes|YES|Yes) managed_authentik="yes" ;;
      *) managed_authentik="no" ;;
    esac
  fi
fi
managed_authentik="${managed_authentik:-no}"
if [[ "$managed_authentik" == "yes" ]]; then
  [[ -n "$oidc_issuer" ]] || fail "auth.oidc.issuer is empty in config/tow.yaml; managed authentik deletion needs the exact issuer URL."
  [[ -n "$(read_env_key AUTHENTIK_BOOTSTRAP_TOKEN)" ]] || fail "AUTHENTIK_BOOTSTRAP_TOKEN is empty in .env; managed authentik deletion needs API access."
fi

# ---------------------------------------------------------------------------
# Write the privacy configuration (everything except the master switch)
# ---------------------------------------------------------------------------

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
cp "$yaml_file" "${yaml_file}.backup-${timestamp}"
log "Backed up config/tow.yaml to config/tow.yaml.backup-${timestamp}."

apply_privacy_config() {
  TOW_ERASE_POLICY="$policy" \
  TOW_ERASE_EMAIL_TRANSPORT="$email_transport" \
  TOW_ERASE_RELAY_DAYS="$relay_retention_days" \
  TOW_ERASE_OPENAI_MODE="$openai_mode" \
  TOW_ERASE_PROCESSOR_KEY="$processor_key" \
  TOW_ERASE_RETENTION_DAYS="$retention_days" \
  TOW_ERASE_MANAGED_AUTHENTIK="$managed_authentik" \
  TOW_ERASE_ISSUER="$oidc_issuer" \
  TOW_ERASE_AUTHENTIK_EVENT_DAYS="$authentik_event_retention_days" \
  TOW_ERASE_ENABLE="${1:-}" \
  python3 - "$yaml_file" <<'PY'
import os
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

match = re.search(r"(?ms)^privacy:\n(.*?)(?=^[a-z_]+:|\Z)", text)
if match is None:
    raise SystemExit("config/tow.yaml has no top-level privacy: section; restore it from config/tow.example.yaml.")
block = match.group(0)
original_block = block


def set_line(pattern: str, replacement: str, required: bool = True) -> None:
    global block
    new, count = re.subn(pattern, replacement, block, count=1, flags=re.M)
    if count != 1:
        if required:
            raise SystemExit(
                f"Could not find {pattern!r} in the privacy section of config/tow.yaml; "
                "it no longer matches the shipped template. Apply the settings by hand "
                "(see the user-deactivation-and-erasure documentation)."
            )
        return
    block = new


set_line(r"^  policy_reference:.*$", f"  policy_reference: {os.environ['TOW_ERASE_POLICY']}")
set_line(r"^    coverage_mode:.*$", "    coverage_mode: bundled_only")

if os.environ["TOW_ERASE_EMAIL_TRANSPORT"] == "smtp":
    set_line(r"^    relay_retention_mode:.*$", "    relay_retention_mode: bounded_retention")
    set_line(
        r"^    relay_retention_days:.*$",
        f"    relay_retention_days: {os.environ['TOW_ERASE_RELAY_DAYS']}",
    )

openai_mode = os.environ["TOW_ERASE_OPENAI_MODE"]
if openai_mode != "none":
    processor_key = os.environ["TOW_ERASE_PROCESSOR_KEY"]
    processor_pattern = rf"^      {re.escape(processor_key)}:.*$"
    if re.search(processor_pattern, block, flags=re.M):
        set_line(processor_pattern, f"      {processor_key}: {openai_mode}")
    elif re.search(r"^    registry: \{\}$", block, flags=re.M):
        set_line(r"^    registry: \{\}$", f"    registry:\n      {processor_key}: {openai_mode}")
    else:
        set_line(r"^    registry:$", f"    registry:\n      {processor_key}: {openai_mode}")
    if openai_mode == "bounded_retention":
        set_line(
            r"^    bounded_retention_days:.*$",
            f"    bounded_retention_days: {os.environ['TOW_ERASE_RETENTION_DAYS']}",
        )

if os.environ["TOW_ERASE_MANAGED_AUTHENTIK"] == "yes":
    issuer = os.environ["TOW_ERASE_ISSUER"]
    set_line(
        r"^    managed_authentik_user_deletion_enabled:.*$",
        "    managed_authentik_user_deletion_enabled: true",
    )
    if re.search(r"^    managed_authentik_issuers: \[\]$", block, flags=re.M):
        set_line(
            r"^    managed_authentik_issuers: \[\]$",
            f"    managed_authentik_issuers:\n      - {issuer}",
        )
    set_line(
        r"^    authentik_event_retention_days:.*$",
        f"    authentik_event_retention_days: {os.environ['TOW_ERASE_AUTHENTIK_EVENT_DAYS']}",
    )

if os.environ["TOW_ERASE_ENABLE"] == "true":
    set_line(r"^  full_erasure_enabled:.*$", "  full_erasure_enabled: true")

if block != original_block:
    path.write_text(text.replace(original_block, block, 1), encoding="utf-8")
PY
}

apply_privacy_config ""
log "Wrote the privacy configuration (policy: ${policy}, coverage: bundled_only)."

if [[ $configure_only -eq 1 ]]; then
  log "--configure-only: deletion is configured but NOT enabled."
  log "Finish later by re-running scripts/setup-erasure.sh."
  exit 0
fi

# ---------------------------------------------------------------------------
# Backfill, readiness, enable
# ---------------------------------------------------------------------------

[[ -n "$(docker compose ps -q backend 2>/dev/null)" ]] \
  || fail "The stack is not running; start it (docker compose up -d --wait) and re-run this script."

if [[ "$managed_authentik" == "yes" ]]; then
  log "Enabling authentik GDPR cleanup and applying ${authentik_event_retention_days}-day event retention..."
  docker compose run --rm backend python -m app.scripts.configure_authentik_privacy
fi

log "Indexing historical data for erasure lineage (privacy backfill)..."
docker compose run --rm backend python -m app.scripts.privacy_backfill --dry-run
docker compose run --rm backend python -m app.scripts.privacy_backfill

log "Checking erasure readiness..."
if ! docker compose run --rm backend python -m app.scripts.privacy_readiness; then
  printf '\n'
  fail "Readiness is blocked (see the lines above). Fix each blocker, then re-run scripts/setup-erasure.sh — your answers are saved and deletion stays disabled until readiness passes."
fi

log "Readiness passed. Enabling deletion..."
apply_privacy_config "true"
docker compose up -d --wait --force-recreate backend search-worker email-worker web-push-worker inbound-email-worker migration-worker

log "Re-checking readiness with deletion enabled (some checks only run now)..."
if ! docker compose run --rm backend python -m app.scripts.privacy_readiness; then
  printf '\n'
  warn "Deletion is enabled but still gated: requests are refused until every"
  warn "blocker above is fixed. Re-check with:"
  warn "  docker compose run --rm backend python -m app.scripts.privacy_readiness"
  exit 1
fi

printf '\n'
log "Account deletion is enabled and ready."
log "Admins manage requests through the admin API (see /api/openapi.json);"
log "users can request deletion of their own account."
log "Recommended final test: create a deletion request for a dedicated test"
log "account, open the emailed cancellation link, cancel, and sign back in."
log "Details: https://docs.tow.dev/deployment/user-deactivation-and-erasure"
