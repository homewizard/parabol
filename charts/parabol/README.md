# parabol

Self-hosted deployment of [Parabol](https://github.com/ParabolInc/parabol) with bundled Postgres (pgvector) and Valkey, packaged as a single Helm chart so the whole stack maps to one release / one future ArgoCD `Application`.

## Prerequisites

- A container image built from `docker/images/parabol-ubi/dockerfiles/basic.dockerfile` in this repo, pushed to a registry your cluster can pull from. There is currently no public Parabol image, so this is a required manual step before the app Deployment will actually start (see "Known limitations" below).
- A default StorageClass, or set `postgres.persistence.storageClassName` explicitly.

## Install

```sh
helm upgrade --install parabol charts/parabol \
  -n parabol --create-namespace \
  --kube-context <your-context> \
  --set image.repository=<your-registry>/parabol \
  --set image.tag=<your-tag>
```

## Configuration

See `values.yaml` for the full set of options, grouped as:

| Key | Description |
| --- | --- |
| `image.*` | Parabol app image (registry/repository/tag/pullSecrets) |
| `parabol.*` | Web server workload: replicas, env, resources, probes, security context |
| `service.*` / `ingress.*` | How to reach the app (ClusterIP by default; optional Ingress, e.g. `ingressClassName: tailscale`) |
| `postgres.*` | Bundled Postgres (pgvector) StatefulSet + PVC + credentials |
| `valkey.*` | Bundled Valkey (Redis-compatible cache/pub-sub) |
| `embedder.*` | Optional AI embeddings: Parabol's own embedder worker plus the Hugging Face `text-embeddings-inference` model server it talks to. Disabled by default. |

The `preDeploy` bundle (`node dist/preDeploy.js`) runs as an `initContainer` on the web Deployment, preceded by a `pg_isready` wait for Postgres. It runs Kysely migrations *and* stores persisted GraphQL queries (`queryMap.json`) into the `QueryMap` table — the production client only sends query hashes, so the server 404s with `PersistedQueryNotFound` on every operation until that table is populated. It also primes integration providers from env and pushes CDN assets, both of which are no-ops with this chart's defaults (no OAuth/integration secrets configured, `FILE_STORE_PROVIDER=local`). This runs on every pod rollout but is idempotent. It's wired into the web Deployment specifically — not a separate Helm hook Job — because this chart hard-caps `replicaCount` at 1, so there's no risk of it racing across multiple pods, and it sidesteps Helm's hook-ordering constraints (a `pre-install` hook can't depend on resources, like the Postgres Secret or the Postgres StatefulSet itself, that the chart's own normal templates create).

Secrets (`SERVER_SECRET`, `POSTGRES_PASSWORD`) are auto-generated on first install and preserved across `helm upgrade` (they're read back from the existing Secret rather than regenerated, and marked `helm.sh/resource-policy: keep`). Override them explicitly via `parabol.secrets.serverSecret` / `postgres.auth.password` if you want deterministic values, or point `postgres.auth.existingSecret` at a Secret you manage yourself.

### Login methods (`parabol.env.auth.*`)

By default all of Parabol's login methods are available: email+password ("internal"), Google, Microsoft (Azure AD/Entra ID), and the SSO "enter your email to find your org's SAML provider" flow. Toggle each independently:

```yaml
parabol:
  env:
    auth:
      internal:
        enabled: true   # email + password (also gates forgot/reset-password)
      google:
        enabled: false
        clientId: ""    # OAuth 2.0 Client ID from Google Cloud Console
      microsoft:
        enabled: false
        tenantId: "common"  # or a specific Azure AD tenant ID
        clientId: ""        # Application (client) ID from the Azure AD app registration
      sso:
        enabled: true   # set false too if you want ONLY the Google/Microsoft buttons, no email form
  secrets:
    auth:
      google:
        clientSecret: ""
      microsoft:
        clientSecret: ""
```

**To hide the email/password form entirely (e.g. a Google-only instance), you must disable both `internal` and `sso`** — Parabol's client renders the email form whenever *either* is enabled (`packages/client/components/GenericAuthentication.tsx`), since with SSO on it doubles as the "enter your email to find your org's IdP" field. `internal.enabled: false` alone leaves a bare email input with a "Sign in with SSO" button.

The chart fails the render if all four (`internal`/`google`/`microsoft`/`sso`) are disabled at once (nobody could log in), and fails if `google`/`microsoft` is enabled without its client ID/secret. These map straight to Parabol's own `AUTH_INTERNAL_DISABLED` / `AUTH_GOOGLE_DISABLED` / `AUTH_MICROSOFT_DISABLED` / `AUTH_SSO_DISABLED` / `GOOGLE_OAUTH_CLIENT_ID` / `GOOGLE_OAUTH_CLIENT_SECRET` / `MICROSOFT_TENANT_ID` / `MICROSOFT_CLIENT_ID` / `MICROSOFT_CLIENT_SECRET` env vars (see `.env.example`). Both the login-page buttons and the server-side mutations respect these.

The Deployment's pod template carries a `checksum/config` / `checksum/secret` annotation derived from the ConfigMap/Secret content, so changing any of these values and running `helm upgrade` triggers an automatic rolling restart — no manual pod restart needed to pick up the new values. (The `preDeploy` initContainer also re-bakes the client's `index.html` from the current env on every pod start, so no image rebuild is needed either.)

To keep an OAuth client secret out of Helm values/release state entirely, set `parabol.secrets.auth.google.existingSecret` (or `.microsoft.existingSecret`) to the name of a Secret you manage out-of-band — e.g.:

```sh
kubectl create secret generic parabol-google-oauth -n parabol \
  --from-literal=GOOGLE_OAUTH_CLIENT_SECRET='<your-client-secret>'
```

```yaml
parabol:
  secrets:
    auth:
      google:
        existingSecret: "parabol-google-oauth"
```

The referenced Secret must contain a key named exactly `GOOGLE_OAUTH_CLIENT_SECRET` (or `MICROSOFT_CLIENT_SECRET`). `existingSecret` takes precedence over `clientSecret` when both are set.

The Google/Microsoft OAuth redirect URIs are hardcoded per-provider (not configurable) as `<proto>://<host>/auth/google` and `<proto>://<host>/auth/microsoft` respectively — register exactly those in the Google Cloud Console OAuth client / Azure AD app registration.

#### Debugging Google `401: invalid_client` / "OAuth client was not found"

This is Google rejecting the `client_id`, not a chart/server-side error. The client's OAuth popup builds its authorize URL directly from `GOOGLE_OAUTH_CLIENT_ID` (`packages/client/utils/GoogleClientManager.ts`), so the fastest way to find the actual value in use is to open the "Continue with Google" popup and read `client_id=` straight out of its address bar (`https://accounts.google.com/o/oauth2/v2/auth?client_id=...`) — that's the ground truth, independent of Helm/env plumbing. Compare it byte-for-byte against Cloud Console. Common causes:

- Wrong GCP **project** — easy to mix up if you created a fresh project to dodge a per-project OAuth client quota.
- Wrong client **type** — must be "Web application", not Desktop/Android/iOS/TV (those produce this exact error with Parabol's popup-based authorization-code flow).
- The client was deleted or never finished creating.
- Stale value: since `helm upgrade` alone doesn't restart pods unless something in the pod template changes, older chart versions without the `checksum/config` annotation (see above) could leave a pod running with a previously-baked, stale `GOOGLE_OAUTH_CLIENT_ID` — confirm with `kubectl exec -n <namespace> deploy/<release> -c parabol -- printenv GOOGLE_OAUTH_CLIENT_ID`.
- Browser-side staleness: Parabol's client is a PWA with an offline service worker that can precache an old `index.html` (and thus an old baked-in client ID) from a previous visit. Hard-refresh or unregister the service worker (DevTools → Application → Service Workers) if you tested this instance before changing the client ID.

### Enterprise tier for self-hosting (`IS_ENTERPRISE`)

`parabol.env.isEnterprise` defaults to `true`, which makes every **newly created** organization default to `enterprise` tier with no Stripe subscription involved — this is Parabol's own documented mechanism for self-hosted/PPMI deployments (`.env.example`, `packages/server/utils/defaultTier.ts`), not a paywall bypass. Set `parabol.env.isSingleOrg: true` alongside it if you want to lock the instance to a single organization.

This only affects orgs created *after* the setting takes effect. If you already created an org before deploying with `isEnterprise: true` (e.g. while testing), its tier won't retroactively change on its own. Parabol ships a `setIsEnterprise` admin script for this, but it's built by a separate webpack config (`scripts/webpack/toolbox.config.js`) that isn't part of the production build and isn't copied into this chart's image — it's not runnable from inside the deployed container. For a one-off fix, either delete the test org and sign up again (simplest), or update it directly in Postgres:

```sh
kubectl exec -n <namespace> <postgres-pod> --context <your-context> -- \
  psql -U <postgres.auth.user> -d <postgres.auth.database> \
  -c "UPDATE \"Organization\" SET tier = 'enterprise';"
```

## Known limitations

- **Single replica only.** The chart hardcodes one `SERVER_ID` per workload (`parabol.serverId`, `embedder.serverId`), which must be a globally unique integer used for Snowflake-style ID generation (`packages/server/generateUID.ts`). Running more than one replica of the web Deployment would mint colliding IDs across pods. `templates/deployment.yaml` enforces `parabol.replicaCount == 1` with a hard failure. Scaling out requires reworking `SERVER_ID` allocation per-pod first (e.g. a StatefulSet with an ordinal-derived offset) — not implemented here.
- **No image published yet.** `image.repository` defaults to a placeholder. Postgres and Valkey will come up fine on install; the app Deployment (and, if enabled, the embedder worker) will sit in `ImagePullBackOff` until you build and push a real image.
- **GitOps is out of scope for this chart.** This is installed with a plain `helm upgrade --install`. Wiring an ArgoCD `Application`, moving Secrets to SealedSecrets, etc. is deliberately left for later.
- Postgres/Valkey are custom templates, not Bitnami subcharts — Bitnami's `postgresql`/`redis` charts hardcode image-specific env var names, data paths, and entrypoint behavior that aren't compatible with the `pgvector/pgvector` and `valkey/valkey` images this chart uses.
