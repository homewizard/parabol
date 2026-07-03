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

Kysely database migrations (`node dist/migrate.js`) run as an `initContainer` on the web Deployment, preceded by a `pg_isready` wait for Postgres. This runs on every pod rollout but is idempotent (a no-op if nothing's pending). It's wired into the web Deployment specifically — not a separate Helm hook Job — because this chart hard-caps `replicaCount` at 1, so there's no risk of migrations racing across multiple pods, and it sidesteps Helm's hook-ordering constraints (a `pre-install` hook can't depend on resources, like the Postgres Secret or the Postgres StatefulSet itself, that the chart's own normal templates create).

Secrets (`SERVER_SECRET`, `POSTGRES_PASSWORD`) are auto-generated on first install and preserved across `helm upgrade` (they're read back from the existing Secret rather than regenerated, and marked `helm.sh/resource-policy: keep`). Override them explicitly via `parabol.secrets.serverSecret` / `postgres.auth.password` if you want deterministic values, or point `postgres.auth.existingSecret` at a Secret you manage yourself.

## Known limitations

- **Single replica only.** The chart hardcodes one `SERVER_ID` per workload (`parabol.serverId`, `embedder.serverId`), which must be a globally unique integer used for Snowflake-style ID generation (`packages/server/generateUID.ts`). Running more than one replica of the web Deployment would mint colliding IDs across pods. `templates/deployment.yaml` enforces `parabol.replicaCount == 1` with a hard failure. Scaling out requires reworking `SERVER_ID` allocation per-pod first (e.g. a StatefulSet with an ordinal-derived offset) — not implemented here.
- **No image published yet.** `image.repository` defaults to a placeholder. Postgres, Valkey, and the migration Job will come up fine on install; the app Deployment (and, if enabled, the embedder worker) will sit in `ImagePullBackOff` until you build and push a real image.
- **GitOps is out of scope for this chart.** This is installed with a plain `helm upgrade --install`. Wiring an ArgoCD `Application`, moving Secrets to SealedSecrets, etc. is deliberately left for later.
- Postgres/Valkey are custom templates, not Bitnami subcharts — Bitnami's `postgresql`/`redis` charts hardcode image-specific env var names, data paths, and entrypoint behavior that aren't compatible with the `pgvector/pgvector` and `valkey/valkey` images this chart uses.
