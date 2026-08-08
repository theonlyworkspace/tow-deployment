# TOW self-hosted deployment kit

Everything needed to run [TOW (The Only Workspace)](https://malinda.ai) on your
own server: one Compose file, a guided installer, and the operations scripts
for backups and restore. TOW's application images are prebuilt and published to
Docker Hub — nothing is compiled on your machine.

Full documentation: **https://docs.tow.dev/deployment/**

## Requirements

- A Linux host with [Docker Engine and the Compose plugin](https://docs.docker.com/engine/install/)
  (Compose 2.24 or newer), 4 GB RAM recommended.
- For production: a domain name, an SMTP relay for outgoing email, and `age`
  (`apt install age`) for encrypted backups.

## Install

```bash
git clone https://github.com/theonlyworkspace/tow-deployment.git
cd tow-deployment
./install.sh
```

The installer asks a handful of questions (domain, who terminates TLS, how
users sign in, SMTP), generates every secret, writes `.env` and
`config/tow.yaml`, pulls the pinned release images, starts the stack, and
offers to set up daily encrypted backups. For a quick look on your own machine
choose *local evaluation* — TOW comes up on `http://localhost:8080`.

Unattended installs work too, for example:

```bash
./install.sh --non-interactive --domain https://tow.example.com --auth builtin
```

Re-running `./install.sh` is always safe: it never overwrites configured
values or secrets, it only fills in keys a newer release added. Use
`./install.sh --reconfigure` to change answers later.

## What is in this kit

| Path | Purpose |
| --- | --- |
| `compose.yaml` | The production stack (app, workers, Postgres, Meilisearch, nginx proxy, optional authentik and docs services). |
| `install.sh` | Guided installer. |
| `.env.example` | Documented template for the secrets file the installer writes. |
| `config/tow.example.yaml` | Documented template for the runtime configuration. |
| `deploy/nginx/` | The bundled proxy's templates — no editing needed. |
| `deploy/systemd/` | Templates for the daily backup and prune timers. |
| `scripts/` | Backup, restore, prune, and scheduling tools (`setup-backups.sh` wires them all up), plus guided account-deletion setup (`setup-erasure.sh`). |
| `compose.override.example.yaml` | Optional override for air-gapped / private-registry deployments. |

`.env`, `config/tow.yaml`, certificates in `deploy/certs/`, and anything in
`secrets/` are yours; updates never touch them.

## Upgrade

```bash
git pull
docker compose pull
docker compose stop backend frontend search-worker email-worker web-push-worker inbound-email-worker migration-worker
docker compose up -d --wait
```

Each release of this kit pins the matching image tag in `TOW_VERSION`. Take a
backup before upgrading and read
[the upgrade guide](https://docs.tow.dev/deployment/upgrades) for the details
(maintenance window behavior, no-downgrade rule, upgrading from pre-kit
deployments).

## Backups

```bash
scripts/setup-backups.sh
```

One command: generates the encryption key, initializes the deletion ledger,
takes the first encrypted backup, and installs daily systemd timers. See
[backup and restore](https://docs.tow.dev/deployment/backup-and-restore).

## Account deletion (GDPR erasure)

```bash
scripts/setup-erasure.sh
```

Asks the required attestation questions (retention policy, backup coverage,
provider retention), verifies readiness, and enables permanent account
deletion. Requires backups to be set up first. See
[user deactivation and deletion](https://docs.tow.dev/deployment/user-deactivation-and-erasure).

## License

TOW is source-available software (TOW Source-Available Self-Host License
v1.0): free self-hosted use for up to 20 users; a commercial license is
required beyond that. See https://malinda.ai for details.
