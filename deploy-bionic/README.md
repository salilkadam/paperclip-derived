# Bionic Kubernetes Deployment

Helm charts and deployment scripts for deploying Bionic to a Kubernetes cluster.

## Quick Start

### Prerequisites

1. **Cluster access** — `kubectl` configured with admin access
2. **Helm** — v3.x installed
3. **Docker** — for building the image
4. **Git** — for version tag

### Pre-deployment Checklist

Before running `deploy.sh`, ensure these are set up:

| Step | Command | Status |
|------|---------|--------|
| 1. Create namespace | `kubectl create ns bionicorg` | ⬜ |
| 2. Create PG user/db | `./deploy/scripts/setup-postgres.sh` | ⬜ |
| 3. Create Keycloak client | `./deploy/scripts/setup-keycloak.sh` | ⬜ |
| 4. Populate Vault secrets | `./deploy/scripts/setup-vault-secrets.sh` | ⬜ |
| 5. Build & push image | `./deploy/scripts/build-and-push.sh` | ⬜ |
| 6. Create DNS record | `org.baisoln.com` → `192.168.0.210` | ⬜ |

> Step 4 generates `paperclip_secrets_master_key` **exactly once** and then
> preserves it forever. On a rebuild of an *existing* Org (DB survives), the
> Vault secret must already contain the original master key — a new key makes
> every previously encrypted managed secret unreadable.

### Deploy

```bash
# 1. Build and push the image
./deploy/scripts/build-and-push.sh

# 2. Run the full deployment (creates namespace, applies Helm, waits for rollout)
./deploy/scripts/deploy.sh

# That's it. The script handles:
# - Creating the bionicOrg namespace
# - Docker pull secret (if credentials provided via DOCKER_USERNAME/DOCKER_PASSWORD)
# - Helm install/upgrade with the correct image tag
# - Waiting for deployment readiness
```

## Helm Values Reference

See `helm/bionic-org/values.yaml` for all configurable options. Key values:

```yaml
namespace: bionicorg
domain: org.bailsoln.com

image:
  repository: docker4zerocool/bionic
  tag: ""  # defaults to chart appVersion
  pullPolicy: Always

postgresql:
  cluster: pg-ceph
  namespace: pg
  database: bionicOrg
  username: bionicOrg

vault:
  path: t6-apps/bionic-org/config
  secretStore: vault-backend
  masterKeySecretKey: paperclip_secrets_master_key

persistence:            # /paperclip instance state — DO NOT disable
  enabled: true
  size: 20Gi
  storageClassName: nfs-client   # RWX: rolling updates never deadlock
  mountPath: /paperclip
  fsGroup: 1000

keycloak:
  url: https://auth.bailsoln.com
  realm: Bionic

ingress:
  className: kong
  tls:
    enabled: true
    secretName: bionic-org-tls
```

## Vault Secrets

Two Vault paths feed this deployment via ESO (both synced every 5 min — never edit the K8s Secrets directly):

1. **`t6-apps/bionic-org/config`** → K8s Secret `bionic-org-secrets` (app config):

| Key | Description |
|-----|-------------|
| `database_url` | PostgreSQL connection string |
| `better_auth_secret` | Better Auth session secret (random) |
| `session_secret` | Session encryption secret (random) |
| `keycloak_client_id` | Keycloak client ID |
| `keycloak_client_secret` | Keycloak client secret |
| `vault_token` | Scoped Vault ops token (policy `bionic-org-app`; see Rotation note below — NOT root since 2026-10-07) |
| `minio_root_user` | MinIO access key |
| `minio_root_password` | MinIO secret key |
| `paperclip_secrets_master_key` | **AES-256-GCM master key** (`local_encrypted` provider). base64 of a 32-byte key. Generated once by `setup-vault-secrets.sh`; NEVER regenerate while encrypted secret versions exist in the DB — all managed secrets (agent API keys, OAuth tokens, provider keys) become permanently undecryptable. Backed up off-cluster. |
| `storage_s3_bucket` | S3 bucket name (if using S3 storage) |
| `storage_s3_endpoint` | S3 endpoint (if using S3 storage) |

2. **`shared/api-keys`** (org-wide shared provider keys) → K8s Secret `bionic-org-api-keys`, mounted via `envFrom` so adapter child processes inherit provider credentials (keys land lowercase and verbatim). Contains `anthropic_api_key`, `claude_subscription_token`, `github_token`, `openai_api_key`, `gemini_api_key`, `openrouter_api_key`, and more. The deployment exposes uppercase CLI-convention aliases for `CLAUDE_CODE_OAUTH_TOKEN`, `GITHUB_TOKEN`, and `OPENAI_API_KEY` only. **`ANTHROPIC_API_KEY` is deliberately NOT aliased** (`vault.anthropicApiKeyAlias: false`): Claude Code/ACP auth precedence picks `ANTHROPIC_API_KEY` over `CLAUDE_CODE_OAUTH_TOKEN`, so a pod carrying it makes every `claude_local` agent bill the prepaid API account and silently ignore its Claude subscription login. This caused the 2026-10-06 incident where every claude_local run failed with "Credit balance is too low" while the ESO-synced subscription token in the same pod was healthy. Runs that should be on subscription show `usage_json->>'billingType' = 'subscription_included'`; `metered_api`/`api` means something re-introduced an API key.

> **Re-seeding Board managed secrets:** after a Case-C rebuild, read the needed values from `bionic-org-api-keys` (`kubectl -n bionicorg get secret bionic-org-api-keys -o go-template=...`) and enter them once in the Board UI — the UI encrypts them into the DB under the master key; the env wiring covers CLI-level fallback.

## Kubernetes Resources Created

| Resource | Name | Purpose |
|----------|------|---------|
| Namespace | `bionicorg` | Isolation namespace |
| ServiceAccount | `bionic-org-sa` | Service account for the pod |
| ConfigMap | `bionic-org-config` | Non-secret environment variables |
| Service | `bionic-org` | ClusterIP service on port 80→3100 |
| Deployment | `bionic-org` | Main application deployment |
| Ingress | `bionic-org` | Kong ingress with TLS |
| Certificate | `bionic-org-tls` | cert-manager TLS certificate |
| PVC | `bionic-org-data` | NFS RWX 20Gi at `/paperclip`: instance state (signing keys, local_disk storage, agent workspaces) |
| ExternalSecret | `bionic-org-secrets` | Vault → K8s secret sync (5m), app config |
| ExternalSecret | `bionic-org-api-keys` | Vault `shared/api-keys` → K8s secret sync (5m), provider keys |
| ExternalSecret | `bionic-org-pg-superuser` | PG credentials (if separate) |

## Disaster Recovery — rebuilding the Org from scratch

Source of truth for re-creation is **this chart + Vault + the CNPG database**.
The K8s Secret `bionic-org-secrets` is only a 5-minute cache of Vault —
never edit it directly (`kubectl patch` edits get reverted by ESO).

### Case A — app/pods deleted, database and Vault intact (common case)

```bash
helm upgrade --install bionic-org ./deploy/helm/bionic-org --namespace bionicorg
# ESO re-syncs the K8s secret; the master key comes from Vault via
# PAPERCLIP_SECRETS_MASTER_KEY; /paperclip re-attaches from the NFS PVC.
```

### Case B — namespace wiped, DB + Vault + NFS share intact

Run the Pre-deployment Checklist steps 1, 4 (skip 2–3, 6), then `deploy.sh`.
Do **not** let `setup-vault-secrets.sh` regenerate the master key (it won't —
it preserves; only `--rotate-master-key` changes it).

### Case C — everything lost (fresh cluster, fresh DB)

1. Full checklist (steps 1–6). `setup-vault-secrets.sh` generates a brand-new
   master key — fine for a fresh DB; back it up off-cluster immediately.
2. After rollout, sign in via Keycloak and re-enter all managed secrets in the
   Board UI (Anthropic/API-provider keys, Claude OAuth, GitHub token,
   GPU-cluster key). These live encrypted **in the DB** under the master key —
   they are not in Vault or the PVC and cannot be restored from this repo.
3. Recreate the watchdog agent: copy `deploy/` into the app pod and run
   `deploy/scripts/create-sr-engineer-agent.sh`, then bootstrap its Claude
   credential from the Vault-synced `claude_subscription_token` pod env
   (see "Sr. Engineer" section), bind it, and enable the heartbeat. Also
   re-run `register-cluster-mcp-servers.sh` and
   `apply-agent-opencode-data-isolation.sh`.

### Verify any restore

```bash
kubectl -n bionicorg get pods,externalsecret,pvc
# Externalsecret READY=True, PVC Bound, pod env resolves master key:
kubectl -n bionicorg exec deploy/bionic-org -- node -e \
  'console.log("master key set:", !!process.env.PAPERCLIP_SECRETS_MASTER_KEY)'
curl -sk https://org.baisoln.com/api/health
# Then check a heartbeat run reaches a real model call (no
# "Secret decryption failed" in pod logs).
```

## Google Drive artifact space ("AI Team")

Agent-created documents are dropped into the approved Google Drive space
"AI Team" (folder id `1MmJAx3Rkag90KSSlFISiVvkuWwvO38dK`) via the
`Loc-Google Workspace` MCP connection (`https://mcp.baisoln.com/gworkspace/mcp`,
Kong `apikey` header from the `loc-gworkspace-apikey` Paperclip secret).
The linked Google account is `salil-bionicaisolutions` (tenant `base`).
Every gworkspace call needs explicit `tenant_id: "base"` plus `account: "<alias>"`;
the catalog exposes 23 `gw_*` tools and has **no file-delete verb**, so cleanup of
a stray artifact must be done in the Drive UI.

### Credential chain (three separate links — do not conflate them)

1. **Paperclip → Kong**: the bound secret value must equal a registered Kong
   key-auth credential. Ours is `mcp-shared-apikey` in namespace `mcp`
   (Vault `shared/api-keys` key `mcp_api_key`, ESO `refreshInterval: 1h`).
   The gworkspace app trusts *only* Kong-injected `x-consumer-username`, and it
   rejects Kong's `gworkspace-anon` anonymous fallback, so an unregistered key
   returns `401` rather than degrading.
2. **Kong → gworkspace app**: `mcp-gworkspace-key-auth` on
   `mcp-gworkspace-ingress`, `key_names: [apikey, X-API-Key]`.
3. **gworkspace app → Google**: the tenant OAuth client from Vault
   `t6-apps/mcp/config` key `gworkspace_tenants_json` → ESO
   `mcp-gworkspace-tenants` → `/etc/mcp/tenants.json`. The `GOOGLE_AUTH_TOKEN`
   pod env (Vault `t6-apps/bionic-org/config`) is **not** this client and is read
   by no code path.

ESO caches for an hour; after changing Vault, force a reconcile with
`kubectl annotate externalsecret <name> force-sync=$(date +%s)`.

### Known failure mode: health says `ok`, every call returns 401

Health checks resolve credentials from `tool_connections.credential_refs`, but
agent dispatch resolves them from `connection_grants.credential_secret_refs`
(`resolveCredentialHeadersUnrecorded` in `server/src/services/tool-gateway.ts`
skips a header ref with no matching grant ref). A connection whose grant refs
are empty therefore reports healthy while every real call goes to Kong
unauthenticated.

Signatures: `tool_call_events.metadata.execution.response.httpStatus = 401` with
`credential_refs` populated but `select credential_secret_refs from
connection_grants` returning `[]`.

Repair with the supported reconnect flow (`POST /api/tool-connections/:id/reconnect`),
then confirm the grant ref landed; `deploy/scripts/fix-gws-grant-credential-ref.sh`
and `fix-gws-grant-credential-ref-sql.sh` do both and are idempotent. Verify with
`deploy/scripts/prove-drive-list-e2e.sh` (read path) and
`prove-drive-write-e2e.sh` (write path).

### Consent: "Google hasn't verified this app" / blocked

The default scope preset includes `gmail.modify` and `gmail.send`, which are
Google **restricted** scopes. An unverified OAuth client requesting them is hard-
blocked for anyone not on the consent screen's test-user list, so a Drive-only
connect fails as part of the whole preset. Add the operator as a test user (or set
the audience to Internal) before re-consenting. Existing refresh tokens keep
working — only *new* consents are blocked — so a block does not explain an
already-linked account failing.

### Google OAuth client retirement (executed 2026-10-07)

The old gworkspace OAuth client for tenant `base`
(`1046539951552-m2ib…apps.googleusercontent.com`, secret sha8 `dcbe8619`) is
retired. Tenant `base` now uses `382016492812-li56…apps.googleusercontent.com`
(secret sha8 `8b6327ae`, `state_signing_key` preserved), live in Vault
`t6-apps/mcp/config` → `gworkspace_tenants_json`.

Proven before the switch with `deploy/scripts/probe_google_redirect_uris.py`
(uses a guaranteed-bad control URI; Google answers HTTP 200 to both accepted
and rejected `redirect_uri`s, so only the **body/redirect target**
discriminates): the callback `https://mcp.baisoln.com/gworkspace/oauth/callback`
is **registered on the new client**.

The switch is executed by
`deploy/scripts/switch-tenant-client-3b-write.sh` (fetch → transform → full
`kv put @file`; never `kv put` with a partial map — this Vault build lacks
`-stdin` on `kv patch`). Vault keeps the previous version, so rollback is
`vault kv put …` from version N-1 or the Vault UI.

Consequence measured after the switch: Google refresh tokens are bound to the
issuing `client_id`; all three pre-existing accounts
(`salil-bionicaisolutions`, `salil-personal-gmail`, `salil-bionicaisol`) now
fail refresh with `unauthorized_client` and need one fresh consent each. New
consents should be **drive-scoped** (`scopes: ["drive"]`) to avoid the
restricted-scope block above. Get a consent URL with
`deploy/scripts/mint-gws-consent-url.mjs <account>` (mints the canonical URL
directly from the upstream MCP endpoint). Until the redaction fix is deployed
the board's gateway test-call path still returns `auth_url:
"***REDACTED***"` (the shared redactor matched the `auth_url` field name; see
`doc/plans/2026-10-07-gws-consent-url-rewrite-bug.md`), so do **not** use
`gws-auth-url-bionicorg.sh` against an unfixed build. After the fix deploys,
`deploy/scripts/repro-testcall-authurl-rewrite.sh` proves the gateway path is
clean (`canonical: true`) and `deploy/scripts/decode-authurl-state.mjs`
decodes any `state` blob.

Post-switch blocker (resolved same day): the new GCP project had **no APIs
enabled**, so Drive calls returned Google 403 "Google Drive API has not been
used in project 382016492812". The owning project is **`bionic-core-503216`**
(project number `382016492812` = the `client_id` prefix; API enablement is
always enforced on the project that *issued* the OAuth client). Operator
enabled Drive/Gmail/Calendar/People there; E2E proof then passed green:
`ACCOUNTS="bionicorg" bash deploy/scripts/prove-drive-list-e2e.sh` →
`decision: allowed`, real children of the AI Team root, ground-truth
`tool_call_events … httpStatus = 200`. Use
`deploy/scripts/run-gws-drive-list-probe.sh` to probe upstream directly
(`gw_list_files` args are only `tenant_id`/`account`/`query`/`max_results`).

Security note found during this work: Vault `t6-apps/bionic-org/config` stores
a **root** Vault token as `vault_token`, which ESO mirrors into the
`bionic-org-secrets` k8s Secret. That is an operator follow-up to scope down.

**Rotation completed 2026-10-07.** The stored token is now an **orphan,
periodic (720h) service token** under policy `bionic-org-app`, which grants
exactly `secret/{data,metadata}/t6-apps/bionic-org/config` and
`secret/{data,metadata}/t6-apps/mcp/config` (read/update/patch). No root token
is stored anywhere anymore. Facts an operator needs:
- ESO never used `vault_token` (it authenticates via Vault JWT with role
  `eso-reader`); the app container mounts `VAULT_TOKEN` but no code reads it.
  Consumers are the ops scripts (`switch-tenant-client-*`,
  `probe-bionic-vault-token.sh`), which now self-renew the token on every use
  so the 720h period never lapses. A token unused for 30 days dies — rerun any
  script with the break-glass flow below, then re-point the config field.
- **Never revoke the token's parent to retire it in the same breath as
  creating a replacement**: revoking a parent cascades to children (this bit
  us during the rotation and required root regeneration).
- Break-glass when no token works: `bash deploy/scripts/vault-regenerate-root.sh`
  (regenerates root from the two shares in `vault/vault-unseal-keys`, t=2/3;
  pitfalls documented in the script header). Regenerated root cannot be
  revoked; durable mitigation for share leakage is `vault operator rotate`.
- `capabilities-self` needs sudo and fails on the scoped token; use
  `probe-bionic-vault-token.sh`, which proves capabilities functionally.

### Layout (one folder per org role = the owner)

| Folder | ID | Owner role |
|---|---|---|
| CEO | `1XGRgQDdZZOeDwVU9omlg6bNE5eEaZFeC` | Chief Executive Officer |
| COO | `1-UGS4ohfHND3mi1LBIX4eJUln6mxw2ey` | Chief Operating Officer |
| CMO | `10Ncj5HLJW0NdX0asahftmL1yPmO0W0P3` | Chief Marketing Officer |
| CIO | `1AZI8sLSO5hjx9B9D2HEfEfYysRg4kdCo` | Head of Development |
| CLO | `1APCrCwB98knSn7GYjUXpURlhuVRISmZb` | Chief Legal Officer |
| Project Manager | `1RPveSfN6e8zCmnJwNBk5o3G9JVooAimM` | Project Manager |
| Sr. Engineer | `16QRpoyGqlaVFTosGBRfoiBg0dkMzY0Y5` | Senior Engineer (error warden, IT) |
| _shared | `1X3mLZ0IP1pJDJtMm5WZwoAzBb_qoh5dz` | cross-role documents |

Each folder contains an `OWNER.md` naming the accountable role and its
Paperclip agent ids; `README.md` at the root restates the convention.

### Rules for agents

- Always pass your role folder's `folder_id` to `gw_create_file` — never
  drop artifacts at the AI Team root or outside it.
- Drive-side `owner` is always the single linked OAuth account; role
  ownership is expressed by folder placement + `OWNER.md`, not Drive ACLs.
  (Strict per-role Drive ownership would need per-role Google accounts or
  a Shared Drive — not set up.)
- `gw_list_files` has no `folder_id` argument: filter with a Drive query,
  e.g. `'<folder_id>' in parents and trashed=false`.

### Reseed after disaster

```sh
# Idempotent: skips anything that already exists.
kubectl -n bionicorg exec -i deploy/bionic-org -c bionic -- \
  node - < deploy/scripts/gdrive-seed-ai-team.mjs
```

Requires server image `mcp-servers-gworkspace:oauth-prm-3` or newer
(`gw_create_folder`; merged upstream in
`Bionic-AI-Solutions/multitenant-mcp-servers` main, PR #17) and the
`mcp_api_key` env on the app pod (from `bionic-org-api-keys`). To rebuild
that image quickly see `deploy/mcp/gworkspace-image/oauth-prm-3.Dockerfile`.

## Troubleshooting

### Pod stuck in ContainerCreating

```bash
kubectl -n bionicorg describe pod -l app=bionic-org
# Check for image pull issues (need dockerhub-pull-secret)
```

### ExternalSecret not syncing

```bash
kubectl -n bionicorg describe externalsecret bionic-org-secrets
kubectl -n bionicorg get externalsecret -o wide   # READY column + STATUS
# Check Vault path exists: vault kv get t6-apps/bionic-org/config
```

> **ESO fails SILENTLY.** A failed sync leaves `Ready=False` with
> `reason=SecretSyncedError` but the target K8s Secret keeps serving **stale
> data** (deletionPolicy Retain), and app pods never see Vault changes — no pod
> log shows anything. After any Vault write, always confirm the ES flips to
> `Synced`/`Ready=True`; force an immediate re-sync with:
> `kubectl -n bionicorg annotate externalsecret <name> force-sync="$(date +%s)" --overwrite`
> (restarting the ESO controller does NOT force re-sync).

Known causes:

- **`vault.kvMount` must be the KV v2 *mount name*** (`secret` on this
  cluster), not a folder. ESO builds `<kvMount>/data/<key>`; a folder path
  here 403s every sync. (`--reuse-values` also hides NEW chart value keys —
  pass new keys via `--set` on the upgrade that first introduces them.)
- **Missing Vault policy.** The JWT role `eso-reader` must have
  `token_policies=["eso-bionic-org-policy"]` AND that policy must exist
  (re-create both with `deploy/scripts/setup-vault-jwt.sh`; login 403s while
  the policy is missing, 401s while the role/JWT config is broken — a useful
  distinction). The shared store's policy must list every tenant's KV path.
- **Shared-store path prefix (cross-tenant blast radius, 2026-10-06).** The
  instance ClusterSecretStore `vault-backend` is shared by every tenant
  namespace, and its tenant ExternalSecrets write **bare** keys
  (`t6-apps/<x>/config`, `shared/*`, `t5-gateway/...`). Two ways to break all
  of them at once:
  1. Setting the store's `vault.path` (chart `vault.kvMount`) to a *folder*
     like `t6-apps/bionic-org/config` instead of the KV mount name `secret` —
     ESO then prefixes every tenant's key and every foreign sync 403s.
  2. Writing the shared JWT role `eso-reader` with `token_policies` that
     **replace** (rather than merge) the existing list, dropping the broad
     read policy other tenants rely on. `setup-vault-jwt.sh` now merges
     additively and always attaches the broad `eso-reader` policy
     (`secret/data/*` read + `secret/metadata/*` read/list) alongside the org
     policy.
  After **any** Vault role/policy/store change: `kubectl rollout restart
  deploy/external-secrets -n external-secrets` (the controller caches store
  login tokens for up to 1h) and then confirm `kubectl get externalsecret -A`
  shows every row READY=True — foreign tenants' ES failures are invisible from
  the bionicorg namespace.

### Claude agents fail with "Credit balance is too low"

```bash
# The pod must NOT have uppercase ANTHROPIC_API_KEY:
kubectl -n bionicorg exec deploy/bionic-org -c bionic -- \
  sh -c '[ -n "$ANTHROPIC_API_KEY" ] && echo POISONED || echo clean'
```

If POISONED, something set `vault.anthropicApiKeyAlias=true` (see the provider
keys section above) — unset it and `kubectl -n bionicorg rollout restart
deploy/bionic-org`. If clean but runs still fail, the subscription token itself
(`shared/api-keys` key `claude_subscription_token`) is expired/revoked: refresh
it in Vault, force-sync, rollout-restart the pod (pod env freezes at container
start), and for Board-managed agents rotate the matching owner user-secret via
the Board UI or the claude-oauth-token API.

### TLS not provisioning

```bash
kubectl -n bionicorg describe certificate bionic-org-tls
# Verify letsencrypt-prod ClusterIssuer is ready
kubectl get clusterissuer letsencrypt-prod
```

### Ingress not routing

```bash
kubectl -n bionicorg describe ingress bionic-org
# Check Kong pods are running
kubectl get pods -n kong
```

### Database connection failure

```bash
# Test connectivity from the pod
kubectl -n bionicorg exec -it deployment/bionic-org -- bash
psql "postgresql://bionicOrg:<password>@pg-ceph-rw.pg.svc.cluster.local:5432/bionicOrg"
```

## Customization

### Override values from CLI

```bash
helm upgrade --install bionic-org ./deploy/helm/bionic-org \
  --namespace bionicorg \
  --set image.tag=abc1234 \
  --set domain=custom.bailsoln.com \
  --set "env.PAPERCLIP_STORAGE_PROVIDER=s3"
```

### Using MinIO/S3 instead of local disk

Set in Helm values or via env override:

```yaml
env:
  PAPERCLIP_STORAGE_PROVIDER: s3
```

Then ensure Vault has:
- `storage_s3_bucket`
- `storage_s3_endpoint`
- `storage_s3_region` (optional)

## Architecture

```
                    ┌─────────────┐
                    │   DNS       │
                    │ org.bailsoln│
                    │    .com     │
                    └──────┬──────┘
                           │
                    ┌──────▼──────┐
                    │     Kong    │
                    │  Ingress    │
                    │  (K3s LB)   │
                    └──────┬──────┘
                           │
              ┌────────────▼────────────┐
              │     bionicOrg Namespace  │
              │                         │
              │  ┌─────────────────┐    │
              │  │  Deployment     │    │
              │  │  (Port 3100)    │    │
              │  └────────┬────────┘    │
              │           │              │
              │  ┌────────▼────────┐    │
              │  │   Service       │    │
              │  │   (Port 80)     │    │
              │  └─────────────────┘    │
              └────────────┬────────────┘
                           │
              ┌────────────▼────────────┐
              │    CNPG (pg-ceph)       │
              │    PostgreSQL 5432       │
              └─────────────────────────┘
                           │
              ┌────────────▼────────────┐
              │    Vault (ESO)          │
              │    t6-apps/bionic-org/  │
              └─────────────────────────┘
```

## Cluster MCP servers (Loc-*)

`deploy/mcp/bionic-org-mcp-servers.json` is the discovered catalog of every
MCP-shaped workload in the cluster (internal DNS, Streamable HTTP where
supported). `deploy/scripts/register-cluster-mcp-servers.sh` registers the
`status: ready` entries into a Paperclip company as `Loc-*` tool connections
(auth kind `none` — internal cluster traffic bypasses the mcp-ingress API-key
wall; `PAPERCLIP_DEPLOYMENT_EXPOSURE=private` lets the endpoint guard accept
private URLs) and runs health-check + catalog refresh for each. Re-run it
any time after recreating the org from scratch.

Cluster prerequisites applied for these connections (see
`cluster_prerequisites` in the catalog JSON): the comfy host allowlist, the
mail-bridge service client-IP session affinity, and the private exposure flag.

Entries that are `oauth_gated` (Letta, Google Workspace: Keycloak realm
`mcp` bearer required), `sse_only` (search MCP: Paperclip speaks Streamable
HTTP), `unavailable` (qdrant, scaled to zero), `not_mcp` (docs swagger-ui),
or `unreachable` (archon) are documented but intentionally not registered.

## Per-agent OpenCode data isolation

All agents execute `opencode run` as the same OS user in the app pod, so they
would otherwise share one SQLite database
(`/paperclip/.local/share/opencode/opencode.db`). opencode 1.18.x kills the
whole run on `SQLITE_BUSY` (upstream anomalyco/opencode#33320, #47566, #48416),
which surfaced as `Error: Unexpected error / database is locked` and
`Failed to execute statement` whenever two agents started together.

`scripts/apply-agent-opencode-data-isolation.sh` gives every agent its own
`XDG_DATA_HOME`/`XDG_STATE_HOME` under the `/paperclip` PVC
(`/paperclip/agents/<agentId>/opencode/…`), seeded with a copy of the shared DB
so session resume keeps working. The bindings live in
`agents.adapter_config.env` (plain values), so they survive pod restarts; run
the script again after adding agents.

## Sr. Engineer (IT department watchdog agent)

A 6th agent, **Sr. Engineer** (`6c3d9ec8-604d-4621-98b3-761931c72225`), reports
to the CIO, carries `metadata.department = "IT"`, and patrols Paperclip failures
on a 5-minute heartbeat: failed/timed-out runs, the recovery backlog, and its
own assigned issues. It retries transient failures, applies the known-failure
catalogue fixes, and goes back to sleep when there is nothing actionable. Its
brain is the Claude subscription (`claude_local` adapter).

- Runbook (instructions bundle entry file): `deploy/agents/sr-engineer-AGENTS.md`
- Idempotent creation: `deploy/scripts/create-sr-engineer-agent.sh`
  (requires `PAPERCLIP_BOARD_TOKEN`; runs inside the app pod)

Claude auth note: `claude_local` has **no device login** and the setup-token
session flow needs a managed sandbox environment. This deployment uses the
Vault path instead — the subscription token lives in Vault at
`shared/api-keys` key `claude_subscription_token`, synced by ESO into the
`bionic-org-api-keys` secret and injected into the pod as both
`claude_subscription_token` and `CLAUDE_CODE_OAUTH_TOKEN`. One-time bootstrap
(rotate the Vault value to rotate the credential, then re-run step 1):

1. `POST /api/companies/<cid>/claude-oauth-token {"token":"sk-ant-oat01-..."}`
   (read the token from the pod env — never paste it into tickets/logs).
2. `PATCH /api/agents/<id> {"applyStoredClaudeLogin":true}`
3. `PATCH /api/agents/<id> {"runtimeConfig":{"heartbeat":{"enabled":true,"intervalSec":300,"maxConcurrentRuns":1}}}`

Done 2026-10-06: bound (`secretId 37564ea7`), first on-demand run succeeded
(claude-opus-5, exit 0), heartbeat enabled — 5-minute timer patrols active.

The heartbeat ships **disabled** at creation so the agent never loops
`setup_failed` before its Claude login exists. Memory: with 6 agents at
`maxConcurrentRuns:1` the pod stays under the 6Gi limit; re-check
`kubectl top pod` after the first week of patrol activity.

See `doc/plans/2026-10-07-gws-consent-url-rewrite-bug.md` for the
test-calls `auth_url` bug found during this work (root cause: field-name
redaction of the consent URL, not a state rewrite) and the
`mint-gws-consent-url.mjs` workaround.
