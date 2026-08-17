#!/usr/bin/env bash
# TOW guided installer.
#
# Turns a clone of the deploy kit into a running TOW deployment: asks a few
# questions (or takes flags), generates every secret, writes .env and
# config/tow.yaml, pulls the pinned images, and starts the stack.
#
# Re-running is safe: existing non-empty values are never overwritten; only
# missing keys (for example ones introduced by a newer release) are filled in.
set -Eeuo pipefail

usage() {
  cat <<'USAGE'
Usage: ./install.sh [options]

Interactive by default. Every prompt has a matching flag for unattended use.

Options:
  --eval                Local evaluation mode: http://localhost:8080, no TLS,
                        ledger directory inside the deployment directory.
  --domain URL          Production mode. The public URL users will visit,
                        for example https://tow.example.com
  --tls off|provided    Production TLS mode. "off" expects your own reverse
                        proxy in front (default); "provided" serves TLS from
                        certificates in deploy/certs/.
  --auth builtin|authentik
                        Authentication mode. Default: builtin.
  --admin-email ADDR    Authentik bootstrap admin email.
  --smtp-host HOST      Configure SMTP delivery now (also --smtp-port,
                        --smtp-from, --smtp-username, --smtp-password).
  --openai-key KEY      OpenAI API key (blank disables AI features).
  --exa-key KEY         Exa API key (blank disables AI web search).
  --version TAG         TOW release tag. Default: TOW_VERSION from the
                        environment, an existing .env, or .env.example.
  --ledger-dir DIR      Absolute deletion-ledger directory for production.
                        Default: /var/lib/tow-privacy
  --with-backups        Run scripts/setup-backups.sh after the stack is up.
  --skip-backups        Do not offer backup setup.
  --skip-erasure        Do not offer account-deletion (GDPR erasure) setup.
  --reconfigure         Re-ask the questions and rewrite settings (never
                        secrets) in an existing .env and config/tow.yaml.
  --non-interactive     Fail instead of prompting. Requires --eval or --domain.
  --no-start            Write .env and config/tow.yaml, then stop. No Docker
                        commands are run.
  -h, --help            Show this help.
USAGE
}

log() { printf '[tow-install] %s\n' "$*"; }
warn() { printf '[tow-install] WARNING: %s\n' "$*" >&2; }
fail() { printf '[tow-install] ERROR: %s\n' "$*" >&2; exit 1; }

kit_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
cd "$kit_dir"

mode=""
public_url=""
tls_mode=""
auth_mode=""
admin_email=""
smtp_host=""
smtp_port="587"
smtp_from=""
smtp_username=""
smtp_password=""
smtp_choice=""
smtp_port_in=""
openai_key=""
exa_key=""
version="${TOW_VERSION:-}"
ledger_dir=""
backups_choice=""
skip_erasure=0
reconfigure=0
non_interactive=0
no_start=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --eval) mode="eval"; shift ;;
    --domain) mode="production"; public_url="${2:?--domain requires a URL}"; shift 2 ;;
    --tls) tls_mode="${2:?--tls requires off or provided}"; shift 2 ;;
    --auth) auth_mode="${2:?--auth requires builtin or authentik}"; shift 2 ;;
    --admin-email) admin_email="${2:?--admin-email requires a value}"; shift 2 ;;
    --smtp-host) smtp_choice="now"; smtp_host="${2:?--smtp-host requires a value}"; shift 2 ;;
    --smtp-port) smtp_port="${2:?--smtp-port requires a value}"; shift 2 ;;
    --smtp-from) smtp_from="${2:?--smtp-from requires a value}"; shift 2 ;;
    --smtp-username) smtp_username="${2:?--smtp-username requires a value}"; shift 2 ;;
    --smtp-password) smtp_password="${2:?--smtp-password requires a value}"; shift 2 ;;
    --openai-key) openai_key="${2:?--openai-key requires a value}"; shift 2 ;;
    --exa-key) exa_key="${2:?--exa-key requires a value}"; shift 2 ;;
    --version) version="${2:?--version requires a release tag}"; shift 2 ;;
    --ledger-dir) ledger_dir="${2:?--ledger-dir requires an absolute path}"; shift 2 ;;
    --with-backups) backups_choice="yes"; shift ;;
    --skip-backups) backups_choice="no"; shift ;;
    --skip-erasure) skip_erasure=1; shift ;;
    --reconfigure) reconfigure=1; shift ;;
    --non-interactive) non_interactive=1; shift ;;
    --no-start) no_start=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

# ---------------------------------------------------------------------------
# Prompting helpers
# ---------------------------------------------------------------------------

ask() {
  # ask VAR "Question" "default"
  local __var="$1" question="$2" default="${3:-}" reply=""
  if [[ $non_interactive -eq 1 ]]; then
    [[ -n "$default" ]] || fail "Missing required value for: $question (running with --non-interactive)"
    printf -v "$__var" '%s' "$default"
    return 0
  fi
  if [[ -n "$default" ]]; then
    read -r -p "$question [$default]: " reply
    printf -v "$__var" '%s' "${reply:-$default}"
  else
    while [[ -z "$reply" ]]; do
      read -r -p "$question: " reply
    done
    printf -v "$__var" '%s' "$reply"
  fi
}

ask_yes_no() {
  # ask_yes_no "Question" "y|n"  -> sets global reply_yes_no to yes|no
  local question="$1" default="$2" reply=""
  if [[ $non_interactive -eq 1 ]]; then
    [[ "$default" == "y" ]] && reply_yes_no="yes" || reply_yes_no="no"
    return 0
  fi
  local suffix="[y/N]"
  [[ "$default" == "y" ]] && suffix="[Y/n]"
  read -r -p "$question $suffix: " reply
  reply="${reply:-$default}"
  case "$reply" in
    y|Y|yes|YES|Yes) reply_yes_no="yes" ;;
    *) reply_yes_no="no" ;;
  esac
}

ask_secret() {
  # ask_secret VAR "Question" — empty answers allowed.
  local __var="$1" question="$2" reply=""
  if [[ $non_interactive -eq 1 ]]; then
    printf -v "$__var" '%s' ""
    return 0
  fi
  read -r -s -p "$question: " reply
  printf '\n'
  printf -v "$__var" '%s' "$reply"
}

generate_secret() {
  python3 -c 'import secrets, string; print("".join(secrets.choice(string.ascii_letters + string.digits) for _ in range(48)))'
}

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------

command -v python3 >/dev/null 2>&1 || fail "python3 is required."
if [[ $no_start -eq 0 ]]; then
  command -v docker >/dev/null 2>&1 || fail "Docker is required. Install Docker Engine with the Compose plugin first: https://docs.docker.com/engine/install/"
  docker info >/dev/null 2>&1 || fail "The Docker daemon is not reachable. Is Docker running, and is your user in the docker group?"
  compose_version="$(docker compose version --short 2>/dev/null || true)"
  [[ -n "$compose_version" ]] || fail "The Docker Compose plugin is required (docker compose version failed)."
  python3 - "$compose_version" <<'PY' || fail "Docker Compose ${compose_version} is too old; version 2.24 or newer is required."
import sys
raw = sys.argv[1].lstrip("v").split("-")[0]
parts = [int(p) for p in raw.split(".")[:2] if p.isdigit()] or [0]
sys.exit(0 if tuple(parts + [0] * (2 - len(parts))) >= (2, 24) else 1)
PY
  command -v curl >/dev/null 2>&1 || fail "curl is required for the health check."
fi

# ---------------------------------------------------------------------------
# Resolve the release tag
# ---------------------------------------------------------------------------

read_env_key() {
  # read_env_key FILE KEY -> prints the value (empty when missing)
  local file="$1" key="$2"
  [[ -f "$file" ]] || return 0
  sed -n "s/^${key}=//p" "$file" | tail -n 1
}

if [[ -z "$version" ]]; then
  version="$(read_env_key .env TOW_VERSION)"
fi
if [[ -z "$version" ]]; then
  version="$(read_env_key .env.example TOW_VERSION)"
fi
[[ -n "$version" ]] || fail "No TOW release selected. Pass --version vX.Y.Z (releases: https://hub.docker.com/r/anistow/tow-backend/tags)."

# ---------------------------------------------------------------------------
# Questions
# ---------------------------------------------------------------------------

env_exists=0
[[ -f .env ]] && env_exists=1

if [[ $env_exists -eq 1 && $reconfigure -eq 0 ]]; then
  log "Found an existing .env — keeping every configured value and filling in missing keys only."
  log "Use --reconfigure to change the domain, TLS, or auth settings."
fi

if [[ $env_exists -eq 0 || $reconfigure -eq 1 ]]; then
  if [[ -z "$mode" ]]; then
    [[ $non_interactive -eq 1 ]] && fail "--non-interactive requires --eval or --domain URL."
    printf '\nHow will this TOW deployment be used?\n'
    printf '  1) Production — a real domain, real users\n'
    printf '  2) Local evaluation — try TOW on this machine first\n'
    local_choice=""
    while [[ "$local_choice" != "1" && "$local_choice" != "2" ]]; do
      read -r -p "Choose 1 or 2 [1]: " local_choice
      local_choice="${local_choice:-1}"
    done
    [[ "$local_choice" == "1" ]] && mode="production" || mode="eval"
  fi

  if [[ "$mode" == "production" ]]; then
    if [[ -z "$public_url" ]]; then
      ask public_url "Public URL users will visit (e.g. https://tow.example.com)"
    fi
    [[ "$public_url" =~ ^https?:// ]] || fail "The public URL must start with http:// or https:// (got: $public_url)."
    public_url="${public_url%/}"
    if [[ -z "$tls_mode" ]]; then
      tls_choice=""
      if [[ $non_interactive -eq 1 ]]; then
        tls_choice="1"
      else
        printf '\nWho terminates TLS (HTTPS)?\n'
        printf '  1) My own reverse proxy in front of TOW (recommended)\n'
        printf '  2) TOW'\''s bundled nginx, using certificates I place in deploy/certs/\n'
      fi
      while [[ "$tls_choice" != "1" && "$tls_choice" != "2" ]]; do
        read -r -p "Choose 1 or 2 [1]: " tls_choice
        tls_choice="${tls_choice:-1}"
      done
      [[ "$tls_choice" == "1" ]] && tls_mode="off" || tls_mode="provided"
    fi
    [[ "$tls_mode" == "off" || "$tls_mode" == "provided" ]] || fail "--tls must be off or provided."
  else
    public_url="http://localhost:8080"
    tls_mode="off"
  fi

  if [[ -z "$auth_mode" ]]; then
    auth_choice=""
    if [[ $non_interactive -eq 1 ]]; then
      auth_choice="1"
    else
      printf '\nHow should users sign in?\n'
      printf '  1) Built-in email/password accounts (simplest)\n'
      printf '  2) Bundled authentik identity provider (SSO, MFA, LDAP/SAML/OIDC)\n'
    fi
    while [[ "$auth_choice" != "1" && "$auth_choice" != "2" ]]; do
      read -r -p "Choose 1 or 2 [1]: " auth_choice
      auth_choice="${auth_choice:-1}"
    done
    [[ "$auth_choice" == "1" ]] && auth_mode="builtin" || auth_mode="authentik"
  fi
  [[ "$auth_mode" == "builtin" || "$auth_mode" == "authentik" ]] || fail "--auth must be builtin or authentik."

  if [[ "$auth_mode" == "authentik" && -z "$admin_email" ]]; then
    ask admin_email "Admin email for the authentik bootstrap account" "admin@example.com"
  fi

  if [[ -z "$smtp_choice" ]]; then
    ask_yes_no $'\nConfigure outgoing email (SMTP) now? TOW needs it for invites and\nsignup verification; you can add it later in config/tow.yaml' "n"
    smtp_choice="$reply_yes_no"
    [[ "$smtp_choice" == "yes" ]] && smtp_choice="now" || smtp_choice="later"
  fi
  if [[ "$smtp_choice" == "now" ]]; then
    [[ -n "$smtp_host" ]] || ask smtp_host "SMTP relay host"
    ask smtp_port_in "SMTP port" "$smtp_port"; smtp_port="$smtp_port_in"
    ask smtp_from "From address" "TOW <noreply@${public_url#*://}>"
    [[ -n "$smtp_username" ]] || ask smtp_username "SMTP username (blank for none)" " "
    smtp_username="${smtp_username# }"
    [[ -n "$smtp_password" ]] || ask_secret smtp_password "SMTP password (hidden, blank for none)"
  fi

  if [[ -z "$openai_key" && $non_interactive -eq 0 ]]; then
    ask_secret openai_key "OpenAI API key for AI features (hidden, blank to disable)"
  fi
  if [[ -z "$exa_key" && $non_interactive -eq 0 ]]; then
    ask_secret exa_key "Exa API key for AI web search (hidden, blank to disable)"
  fi

  if [[ "$mode" == "production" && -z "$ledger_dir" ]]; then
    ask ledger_dir "Deletion-ledger directory (absolute, outside this directory)" "/var/lib/tow-privacy"
  fi
fi

# Values derived from the answers (fresh install / reconfigure only; the
# backfill path below reuses whatever the existing .env already says).
public_host=""
proxy_bind="0.0.0.0"
http_port="80"
https_port="443"
cookie_secure="false"
compose_profiles=""
authentik_public_url=""
oidc_issuer=""
if [[ $env_exists -eq 0 || $reconfigure -eq 1 ]]; then
  public_host="${public_url#*://}"
  public_host="${public_host%%/*}"
  public_host="${public_host%%:*}"
  if [[ "$mode" == "eval" ]]; then
    http_port="8080"
    https_port="8443"
  fi
  case "$public_url" in
    https://*) cookie_secure="true" ;;
  esac
  if [[ "$mode" == "production" && "$tls_mode" == "off" ]]; then
    # Your own reverse proxy is in front: it owns ports 80/443 on this host,
    # so keep the bundled proxy private on loopback ports it can bind.
    proxy_bind="127.0.0.1"
    http_port="8080"
    https_port="8443"
  fi
  if [[ "$auth_mode" == "authentik" ]]; then
    compose_profiles="authentik"
    authentik_public_url="${public_url}/authentik"
    oidc_issuer="${public_url}/authentik/application/o/tow/"
  fi
  if [[ "$mode" == "eval" && -z "$ledger_dir" ]]; then
    ledger_dir="${kit_dir}/.tow/privacy-ledger"
  fi
fi

# ---------------------------------------------------------------------------
# Write .env
# ---------------------------------------------------------------------------

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"

new_secret_or_keep() {
  # new_secret_or_keep KEY — reuse a non-empty existing value, generate otherwise.
  local existing
  existing="$(read_env_key .env "$1")"
  if [[ -n "$existing" ]]; then
    printf '%s' "$existing"
  else
    generate_secret
  fi
}

write_env_file() {
  local target="$1"
  local app_secret webhook_secret postgres_password meili_key privacy_identity privacy_ledger org_auth_key web_push_subscription_secret
  app_secret="$(new_secret_or_keep APP_SECRET)"
  webhook_secret="$(new_secret_or_keep WEBHOOK_SECRET_KEY)"
  postgres_password="$(new_secret_or_keep POSTGRES_PASSWORD)"
  meili_key="$(new_secret_or_keep MEILISEARCH_API_KEY)"
  privacy_identity="$(new_secret_or_keep PRIVACY_IDENTITY_HMAC_SECRET)"
  privacy_ledger="$(new_secret_or_keep PRIVACY_LEDGER_HMAC_SECRET)"
  org_auth_key="$(new_secret_or_keep ORG_AUTH_SECRET_KEY)"
  web_push_subscription_secret="$(new_secret_or_keep WEB_PUSH_SUBSCRIPTION_SECRET)"

  local ak_secret_key="" ak_pg_password="" ak_bootstrap_password="" ak_bootstrap_token="" oidc_client_secret=""
  local ak_path_enabled="false" ak_web_path="/" ak_public_url_value="http://localhost:9000"
  if [[ "$auth_mode" == "authentik" ]]; then
    ak_secret_key="$(new_secret_or_keep AUTHENTIK_SECRET_KEY)"
    ak_pg_password="$(new_secret_or_keep AUTHENTIK_POSTGRES_PASSWORD)"
    ak_bootstrap_password="$(new_secret_or_keep AUTHENTIK_BOOTSTRAP_PASSWORD)"
    ak_bootstrap_token="$(new_secret_or_keep AUTHENTIK_BOOTSTRAP_TOKEN)"
    oidc_client_secret="$(new_secret_or_keep OIDC_CLIENT_SECRET)"
    ak_path_enabled="true"
    ak_web_path="/authentik/"
    ak_public_url_value="$authentik_public_url"
  fi

  local backup_recipient existing_ledger_dir csp_connect_src google_email_oauth_secret microsoft_email_oauth_secret
  local web_push_vapid_public_key web_push_vapid_private_key web_push_vapid_subject
  backup_recipient="$(read_env_key .env PRIVACY_BACKUP_AGE_RECIPIENT)"
  existing_ledger_dir="$(read_env_key .env TOW_PRIVACY_LEDGER_DIR)"
  csp_connect_src="$(read_env_key .env CSP_CONNECT_SRC)"
  google_email_oauth_secret="$(read_env_key .env EMAIL_GOOGLE_OAUTH_CLIENT_SECRET)"
  microsoft_email_oauth_secret="$(read_env_key .env EMAIL_MICROSOFT_OAUTH_CLIENT_SECRET)"
  web_push_vapid_public_key="$(read_env_key .env WEB_PUSH_VAPID_PUBLIC_KEY)"
  web_push_vapid_private_key="$(read_env_key .env WEB_PUSH_VAPID_PRIVATE_KEY)"
  web_push_vapid_subject="$(read_env_key .env WEB_PUSH_VAPID_SUBJECT)"
  web_push_vapid_subject="${web_push_vapid_subject:-mailto:${admin_email:-admin@example.com}}"
  [[ -n "$existing_ledger_dir" ]] && ledger_dir="$existing_ledger_dir"

  cat > "$target" <<EOF
# TOW deployment secrets and Compose bootstrap values.
# Generated by install.sh on ${timestamp}. Re-running install.sh keeps every
# non-empty value; it only fills in keys that are missing or empty.
# Non-secret runtime settings live in config/tow.yaml.

# Exact release tag for every TOW image. Change only when following the
# update procedure: https://docs.tow.dev/deployment/upgrades
TOW_VERSION=${version}

# The URL users visit. Also read by the one-shot authentik bootstrap job.
PUBLIC_APP_URL=${public_url}

# Bundled nginx proxy.
PUBLIC_HOST=${public_host}
PROXY_BIND=${proxy_bind}
PROXY_HTTP_PORT=${http_port}
PROXY_HTTPS_PORT=${https_port}
TLS_MODE=${tls_mode}
PROXY_CLIENT_MAX_BODY_SIZE=25m
# Optional additional API/WebSocket origins allowed by the browser CSP.
CSP_CONNECT_SRC=${csp_connect_src}
TLS_CERT_DIR=./deploy/certs
TLS_CERT_PATH=/etc/nginx/certs/fullchain.pem
TLS_KEY_PATH=/etc/nginx/certs/privkey.pem

# Database.
POSTGRES_USER=tow
POSTGRES_DB=tow
POSTGRES_PASSWORD=${postgres_password}

# Signs sessions and auth state.
APP_SECRET=${app_secret}

# Encrypts webhook configuration and retained delivery data.
WEBHOOK_SECRET_KEY=${webhook_secret}

# Search.
MEILISEARCH_API_KEY=${meili_key}

# Backup and account-deletion prerequisites. Generated once; never rotate or
# remove them while the deployment holds data. scripts/setup-backups.sh fills
# PRIVACY_BACKUP_AGE_RECIPIENT.
PRIVACY_IDENTITY_HMAC_SECRET=${privacy_identity}
PRIVACY_LEDGER_HMAC_SECRET=${privacy_ledger}
PRIVACY_BACKUP_AGE_RECIPIENT=${backup_recipient}
TOW_PRIVACY_LEDGER_DIR=${ledger_dir}

# Required before organisation admins can save LDAP/SAML/OIDC source secrets.
ORG_AUTH_SECRET_KEY=${org_auth_key}

# AI integrations. Leave blank to disable the related capability.
OPENAI_API_KEY=${openai_key}
EXA_API_KEY=${exa_key}

# SMTP credentials. Host, port, and TLS live in config/tow.yaml.
SMTP_USERNAME=${smtp_username}
SMTP_PASSWORD=${smtp_password}

# Optional native project-mailbox OAuth applications. Client IDs and the
# Microsoft tenant live under email.oauth in config/tow.yaml.
EMAIL_GOOGLE_OAUTH_CLIENT_SECRET=${google_email_oauth_secret}
EMAIL_MICROSOFT_OAUTH_CLIENT_SECRET=${microsoft_email_oauth_secret}

# Optional browser Web Push. Add a stable VAPID key pair to enable it.
WEB_PUSH_VAPID_PUBLIC_KEY=${web_push_vapid_public_key}
WEB_PUSH_VAPID_PRIVATE_KEY=${web_push_vapid_private_key}
WEB_PUSH_VAPID_SUBJECT=${web_push_vapid_subject}
WEB_PUSH_SUBSCRIPTION_SECRET=${web_push_subscription_secret}

# Optional docs service (docker compose --profile docs).
DOCS_BIND=127.0.0.1
DOCS_PORT=3001

# Bundled authentik identity provider. Populated when auth mode is authentik;
# ignored (and safe to leave empty) with built-in auth.
COMPOSE_PROFILES=${compose_profiles}
AUTHENTIK_TAG=2026.5.0
AUTHENTIK_PUBLIC_URL=${ak_public_url_value}
AUTHENTIK_INTERNAL_URL=http://authentik-server:9000
AUTHENTIK_WEB__PATH=${ak_web_path}
AUTHENTIK_PATH_ENABLED=${ak_path_enabled}
AUTHENTIK_BOOTSTRAP_EMAIL=${admin_email:-admin@example.com}
AUTHENTIK_BOOTSTRAP_PASSWORD=${ak_bootstrap_password}
AUTHENTIK_BOOTSTRAP_TOKEN=${ak_bootstrap_token}
AUTHENTIK_SECRET_KEY=${ak_secret_key}
AUTHENTIK_POSTGRES_PASSWORD=${ak_pg_password}
OIDC_CLIENT_ID=tow
OIDC_CLIENT_SECRET=${oidc_client_secret}
TOW_AUTHENTIK_APPLICATION_SLUG=tow
TOW_AUTHENTIK_APPLICATION_NAME=TOW
SIGNUP_ENABLED=false
AUTHENTIK_POSTGRES_MAX_CONNECTIONS=200
AUTHENTIK_POSTGRESQL__CONN_MAX_AGE=0
AUTHENTIK_POSTGRESQL__CONN_HEALTH_CHECKS=true
EOF
  chmod 600 "$target"
}

backfill_env_file() {
  # Fill missing/empty keys in an existing .env from .env.example's key list,
  # generating secrets where the fresh template would. Never touches non-empty
  # values. Prints the keys it changed, one per line.
  python3 - .env <<'PY'
import re
import secrets
import string
import sys

path = sys.argv[1]
alphabet = string.ascii_letters + string.digits


def gen() -> str:
    return "".join(secrets.choice(alphabet) for _ in range(48))


GENERATED = {
    "APP_SECRET",
    "WEBHOOK_SECRET_KEY",
    "POSTGRES_PASSWORD",
    "MEILISEARCH_API_KEY",
    "PRIVACY_IDENTITY_HMAC_SECRET",
    "PRIVACY_LEDGER_HMAC_SECRET",
    "ORG_AUTH_SECRET_KEY",
    "WEB_PUSH_SUBSCRIPTION_SECRET",
}
# Keys newer releases may introduce, with their safe defaults.
DEFAULTS = {
    "WEBHOOK_SECRET_KEY": None,
    "ORG_AUTH_SECRET_KEY": None,  # None -> generate
    "EMAIL_GOOGLE_OAUTH_CLIENT_SECRET": "",
    "EMAIL_MICROSOFT_OAUTH_CLIENT_SECRET": "",
    "WEB_PUSH_VAPID_PUBLIC_KEY": "",
    "WEB_PUSH_VAPID_PRIVATE_KEY": "",
    "WEB_PUSH_VAPID_SUBJECT": "mailto:admin@example.com",
    "WEB_PUSH_SUBSCRIPTION_SECRET": None,
}

with open(path, encoding="utf-8") as fh:
    lines = fh.read().splitlines()

present: dict[str, str] = {}
for line in lines:
    match = re.match(r"^([A-Z][A-Z0-9_]*)=(.*)$", line)
    if match:
        present[match.group(1)] = match.group(2)

changed: list[str] = []
out: list[str] = []
for line in lines:
    match = re.match(r"^([A-Z][A-Z0-9_]*)=$", line)
    if match and match.group(1) in GENERATED:
        key = match.group(1)
        out.append(f"{key}={gen()}")
        changed.append(key)
    else:
        out.append(line)

appended: list[str] = []
for key, default in DEFAULTS.items():
    if key not in present:
        value = gen() if default is None else default
        appended.append(f"{key}={value}")
        changed.append(key)
if appended:
    out.append("")
    out.append("# Added by install.sh for this release.")
    out.extend(appended)

if changed:
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(out) + "\n")
    print("\n".join(changed))
PY
}

if [[ $env_exists -eq 0 ]]; then
  write_env_file .env
  log "Wrote .env with generated secrets (file mode 600)."
elif [[ $reconfigure -eq 1 ]]; then
  cp .env ".env.backup-${timestamp}"
  write_env_file .env.reconfigured
  mv .env.reconfigured .env
  log "Rewrote .env (previous file saved as .env.backup-${timestamp}; existing secrets kept)."
else
  changed_keys="$(backfill_env_file)"
  if [[ -n "$changed_keys" ]]; then
    log "Filled previously empty keys in .env: $(printf '%s' "$changed_keys" | tr '\n' ' ')"
  else
    log ".env is already complete — nothing to change."
  fi
fi

# ---------------------------------------------------------------------------
# Write config/tow.yaml
# ---------------------------------------------------------------------------

render_tow_yaml() {
  local target="$1"
  TOW_RENDER_URL="$public_url" \
  TOW_RENDER_COOKIE_SECURE="$cookie_secure" \
  TOW_RENDER_AUTH_MODE="$auth_mode" \
  TOW_RENDER_ISSUER="$oidc_issuer" \
  TOW_RENDER_SMTP="$smtp_choice" \
  TOW_RENDER_SMTP_HOST="$smtp_host" \
  TOW_RENDER_SMTP_PORT="$smtp_port" \
  TOW_RENDER_SMTP_FROM="$smtp_from" \
  python3 - config/tow.example.yaml "$target" <<'PY'
import os
import pathlib
import sys

source, target = sys.argv[1], sys.argv[2]
content = pathlib.Path(source).read_text(encoding="utf-8")


def replace_once(old: str, new: str) -> None:
    global content
    if content.count(old) != 1:
        raise SystemExit(
            f"config/tow.example.yaml changed shape; expected exactly one "
            f"occurrence of {old!r}. Update install.sh to match."
        )
    content = content.replace(old, new)


url = os.environ["TOW_RENDER_URL"]
replace_once("  public_app_url:\n", f"  public_app_url: {url}\n")
replace_once(
    "  backend_cors_origins:\n    - http://localhost:3000\n    - http://localhost:8000\n",
    f"  backend_cors_origins:\n    - {url}\n",
)
replace_once(
    "  session_cookie_secure: false\n",
    f"  session_cookie_secure: {os.environ['TOW_RENDER_COOKIE_SECURE']}\n",
)

if os.environ["TOW_RENDER_AUTH_MODE"] == "authentik":
    issuer = os.environ["TOW_RENDER_ISSUER"]
    replace_once("  mode: builtin\n", "  mode: oidc\n")
    replace_once("    issuer:\n", f"    issuer: {issuer}\n")
    replace_once("    client_id:\n", "    client_id: tow\n")
    replace_once(
        "  organization_auth:\n    # Enables organisation owners/admins to configure their own authentik-backed provider.\n    enabled: false\n",
        "  organization_auth:\n    # Enables organisation owners/admins to configure their own authentik-backed provider.\n    enabled: true\n",
    )

if os.environ["TOW_RENDER_SMTP"] == "now":
    replace_once("  transport: console\n", "  transport: smtp\n")
    replace_once(
        "  from_address: TOW <noreply@example.com>\n",
        f"  from_address: {os.environ['TOW_RENDER_SMTP_FROM']}\n",
    )
    replace_once("    host:\n", f"    host: {os.environ['TOW_RENDER_SMTP_HOST']}\n")
    replace_once("    port: 587\n", f"    port: {os.environ['TOW_RENDER_SMTP_PORT']}\n")

pathlib.Path(target).write_text(content, encoding="utf-8")
PY
}

if [[ ! -f config/tow.yaml ]]; then
  if [[ $env_exists -eq 1 && $reconfigure -eq 0 ]]; then
    fail "config/tow.yaml is missing but .env already exists. Run ./install.sh --reconfigure to answer the setup questions again and render it."
  fi
  render_tow_yaml config/tow.yaml
  log "Wrote config/tow.yaml (auth mode: ${auth_mode:-builtin})."
elif [[ $reconfigure -eq 1 ]]; then
  cp config/tow.yaml "config/tow.yaml.backup-${timestamp}"
  render_tow_yaml config/tow.yaml.reconfigured
  mv config/tow.yaml.reconfigured config/tow.yaml
  log "Rewrote config/tow.yaml (previous file saved as config/tow.yaml.backup-${timestamp})."
else
  log "config/tow.yaml already exists — leaving it untouched."
  yaml_url="$(sed -n 's/^  public_app_url: *//p' config/tow.yaml | head -n 1)"
  if [[ -z "$yaml_url" ]]; then
    warn "runtime.public_app_url is empty in config/tow.yaml; set it to the URL users visit."
  fi
fi

# ---------------------------------------------------------------------------
# Deletion-ledger directory (required bind mount for the backend)
# ---------------------------------------------------------------------------

effective_ledger_dir="$(read_env_key .env TOW_PRIVACY_LEDGER_DIR)"
if [[ -n "$effective_ledger_dir" && ! -d "$effective_ledger_dir" ]]; then
  if mkdir -p "$effective_ledger_dir" 2>/dev/null; then
    chmod 700 "$effective_ledger_dir" 2>/dev/null || true
  elif [[ $no_start -eq 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
      log "Creating ${effective_ledger_dir} (needs sudo)."
      sudo install -d -m 0700 "$effective_ledger_dir" || fail "Could not create ${effective_ledger_dir}."
    else
      fail "Create the ledger directory first: install -d -m 0700 ${effective_ledger_dir}"
    fi
  fi
fi

if [[ $no_start -eq 1 ]]; then
  log "--no-start: configuration written. Start later with: docker compose up -d --wait"
  exit 0
fi

# ---------------------------------------------------------------------------
# Pull, start, verify
# ---------------------------------------------------------------------------

log "Pulling the ${version} images (this can take a few minutes)..."
docker compose pull

log "Starting TOW..."
docker compose up -d --wait

effective_auth_mode="$auth_mode"
if [[ -z "$effective_auth_mode" ]]; then
  effective_auth_mode="$(sed -n 's/^  mode: *//p' config/tow.yaml | head -n 1)"
fi

if [[ "$effective_auth_mode" == "oidc" || "$effective_auth_mode" == "authentik" ]]; then
  if [[ -n "$(read_env_key .env AUTHENTIK_BOOTSTRAP_TOKEN)" ]]; then
    log "Configuring authentik (one-shot bootstrap job)..."
    docker compose --profile authentik run --rm authentik-bootstrap
  fi
fi

health_port="$(read_env_key .env PROXY_HTTP_PORT)"
health_url="http://127.0.0.1:${health_port:-80}/api/health"
log "Waiting for ${health_url} ..."
healthy=0
for _ in $(seq 1 30); do
  if curl -fsS "$health_url" >/dev/null 2>&1; then
    healthy=1
    break
  fi
  sleep 2
done
if [[ $healthy -eq 0 ]]; then
  warn "TOW did not answer on ${health_url}. Inspect with: docker compose ps && docker compose logs backend proxy"
  exit 1
fi

# ---------------------------------------------------------------------------
# Backups
# ---------------------------------------------------------------------------

final_url="$(read_env_key .env PUBLIC_APP_URL)"
if [[ "$mode" == "eval" && -z "$backups_choice" ]]; then
  # Evaluation installs should not be pushed into sudo/systemd setup.
  backups_choice="no"
fi
backup_recipient_now="$(read_env_key .env PRIVACY_BACKUP_AGE_RECIPIENT)"
if [[ -z "$backup_recipient_now" && "$backups_choice" != "no" ]]; then
  if [[ -z "$backups_choice" ]]; then
    ask_yes_no $'\nSet up daily encrypted backups now? (Strongly recommended before real\nusers arrive; account deletion cannot complete without them.)' "y"
    backups_choice="$reply_yes_no"
  fi
  if [[ "$backups_choice" == "yes" ]]; then
    backup_args=()
    [[ $non_interactive -eq 1 ]] && backup_args+=(--non-interactive)
    scripts/setup-backups.sh "${backup_args[@]}"
  else
    log "Skipping backups. Set them up before go-live with: scripts/setup-backups.sh"
  fi
fi

# ---------------------------------------------------------------------------
# Account deletion (GDPR erasure)
# ---------------------------------------------------------------------------

if [[ $skip_erasure -eq 0 && $non_interactive -eq 0 && "$mode" != "eval" ]]; then
  erasure_enabled_now="$(sed -n 's/^  full_erasure_enabled: *//p' config/tow.yaml | head -n 1)"
  if [[ "$erasure_enabled_now" == "true" ]]; then
    : # already enabled — nothing to offer
  elif [[ -n "$(read_env_key .env PRIVACY_BACKUP_AGE_RECIPIENT)" ]]; then
    ask_yes_no $'\nAlso set up permanent account deletion (GDPR "right to erasure") now?\nA few attestation questions, then deletion is enabled once its readiness\ncheck passes. You can also run scripts/setup-erasure.sh at any time' "n"
    if [[ "$reply_yes_no" == "yes" ]]; then
      scripts/setup-erasure.sh \
        || warn "Deletion setup did not finish; your answers are saved — re-run scripts/setup-erasure.sh after fixing the reported blockers."
    fi
  else
    log "Account deletion setup needs backups first; run scripts/setup-backups.sh, then scripts/setup-erasure.sh."
  fi
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

printf '\n'
log "TOW is running: ${final_url}"
if [[ "$mode" == "production" && "$tls_mode" == "off" ]]; then
  log "Point your reverse proxy at http://127.0.0.1:$(read_env_key .env PROXY_HTTP_PORT) — server block example:"
  log "https://docs.tow.dev/deployment/production-hardening"
fi
if [[ "$effective_auth_mode" == "oidc" || "$effective_auth_mode" == "authentik" ]]; then
  log "Sign in via authentik. Bootstrap admin: $(read_env_key .env AUTHENTIK_BOOTSTRAP_EMAIL) (password: AUTHENTIK_BOOTSTRAP_PASSWORD in .env)."
  log "The first successful OIDC login becomes the TOW server admin."
else
  log "Open the URL and register the first account — it becomes the server admin."
fi
log "Documentation: https://docs.tow.dev/deployment/"
