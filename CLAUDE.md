# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Parabol is an open-source, self-hostable collaborative workspace for structured team meetings (retrospectives, sprint poker, standups, check-ins) and real-time collaborative documents ("Pages"), exposed via a public GraphQL API. It's a pnpm monorepo running on Node.js, PostgreSQL, and Valkey (Redis-compatible). See [README.md](README.md) for the full feature/integration list.

## Common commands

### Setup
```bash
pnpm i
cp .env.example .env   # fill in required vars
pnpm db:start           # docker compose: Postgres+pgvector, Valkey, pgadmin, redis-commander, text-embeddings-inference
pnpm dev                # pm2-managed dev processes (webpack, socket server, embedder, relay watch, codegen watch, migrations)
```
App runs at `https://localhost:3000/`. Individual dev processes are defined in [pm2.dev.config.js](pm2.dev.config.js).

### Build / typecheck / lint
- `pnpm build` — production build
- `pnpm typecheck` — runs `tsgo --noEmit` in every package via `pnpm -r`. Use `tsgo`, not `tsc`, when invoking TypeScript directly (e.g. `npx tsgo -p packages/server/tsconfig.json --noEmit`).
- `pnpm biome` — Biome check (the only linter/formatter; no ESLint/Prettier). To fix a single file: `pnpm exec biome check --write <file>`. Do **not** run `pnpm biome --write` — the `biome` script already expands to `biome check`, so that becomes `biome check check --write` and fails.

### Tests
- `pnpm test:client` — Jest for `packages/client`. Single file: `pnpm test:client -- path/to/File.test.tsx`. Single case: append `-- -t "test name"`.
- `pnpm test:server` — Jest for `packages/server`, runs `--runInBand` against real Postgres/Valkey (needs `pnpm db:start` and `.env` set up per [docs/integrationTesting.md](docs/integrationTesting.md)).
- `pnpm --filter parabol-embedder test`, `pnpm --filter parabol-mattermost-plugin test` — Jest for those packages.
- `cd packages/integration-tests && pnpm test` — Playwright E2E, requires a running dev server.

### GraphQL / DB codegen
- `pnpm codegen` — regenerate `resolverTypes.ts` from `codegen.json` + typeDefs. Run after touching `codegen.json` or any `typeDefs/*.graphql`.
- `pnpm relay:build` / `pnpm relay:watch` — regenerate client Relay artifacts.
- `pnpm pg:generate` — regenerate Kysely Postgres types from the live DB schema.

## Monorepo layout

pnpm workspaces (`pnpm-workspace.yaml`) + Nx (`nx.json`):

| Package | Purpose |
|---|---|
| `packages/client` | React 18 + Relay frontend |
| `packages/server` | GraphQL API server |
| `packages/embedder` | Vector embedding service (semantic search) |
| `packages/mattermost-plugin` | Mattermost plugin integration |
| `packages/integration-tests` | Playwright E2E suite |
| `packages/types` | Shared TS global/augment types (no own `package.json`) |

## Server architecture (`packages/server`)

- **Entry**: [server.ts](packages/server/server.ts) boots on **uWebSockets.js**. GraphQL is served via **GraphQL Yoga** ([yoga.ts](packages/server/yoga.ts)), with a plugin stack for auth cookies, PAT `@scope` validation, query cost/armor limits, audit logs, persisted operations, and `@defer`/`@stream`.
- **Schema is SDL-first**: types/mutations/queries are authored as `.graphql` files under `graphql/public/typeDefs/`, then concatenated into the generated `graphql/public/schema.graphql` — never hand-edit that generated file. Mutations return `*Success` types directly (the old `union *Payload = ErrorPayload | *Success` pattern is deprecated; throw `GraphQLError` on failure instead). Full conventions (payload source types, codegen mappers, dataLoader wiring) are in the `graphql` skill — see [.claude/skills/graphql/SKILL.md](.claude/skills/graphql/SKILL.md).
- **Authorization** is centralized in [graphql/public/permissions.ts](packages/server/graphql/public/permissions.ts) + `graphql/public/rules/`, using `graphql-shield` rules composed via `composeResolvers.ts` (a lighter alternative to `graphql-middleware`). Inline auth checks in resolvers are legacy and being migrated out — see [.claude/skills/migrate-permissions/SKILL.md](.claude/skills/migrate-permissions/SKILL.md).
- **Database**: PostgreSQL via **Kysely** (typed query builder, replaced Knex). Migrations live in `postgres/migrations/` and run through `kysely-ctl`. Row types come from `select*()` helpers in [postgres/select.ts](packages/server/postgres/select.ts), which explicitly list columns (excluding sensitive ones like `hashedToken`/`password`). The old `packages/server/database/` types directory is deprecated — use `postgres/types/` instead.
- **DataLoaders**: [dataloader/RootDataLoader.ts](packages/server/dataloader/RootDataLoader.ts) — resolvers should batch through `dataLoader.get('name').load(id)` rather than querying Postgres directly, and mutations must `dataLoader.clearAll('name')` on writes that invalidate cached data.
- **Realtime**: a Valkey/Redis-backed pubsub ([utils/getPubSub.ts](packages/server/utils/getPubSub.ts)) drives GraphQL subscriptions (`graphql/public/subscriptions/`) over WebSockets. See [docs/serviceDiagram.md](docs/serviceDiagram.md) for the mutation → pubsub → subscription flow across replicas. A separate `/yjs` WebSocket route handles Hocuspocus/Yjs collaborative editing for Pages.
- **Background jobs**: [chronos.ts](packages/server/chronos.ts) — cron-based, leader-elected across replicas, handling things like digest emails, OAuth token refresh, and recurring meetings.
- **Integrations**: one manager per provider under `integrations/` (Jira Cloud/Server, GitHub, GitLab, Linear, Google Calendar/Drive, Zoom), most extending a shared `OAuth2Manager`. See [docs/integrations.md](docs/integrations.md) for the viewer/assignee/access-user model governing whose credentials are used for a given action.

## Client architecture (`packages/client`)

- React 18 + **Relay** (not Apollo) for GraphQL data fetching; the Relay compiler reads the server's generated `schema.graphql` (`relay.config.js`) and writes artifacts to `packages/client/__generated__/`.
- New mutations must use the `use*Mutation` hook pattern — see [useShareTopicMutation.ts](packages/client/mutations/useShareTopicMutation.ts) and the existing rule in [.claude/CLAUDE.md](.claude/CLAUDE.md).
- Styling, Tailwind/paletteV3 usage, component-size limits, UI primitives (Radix-based, in `packages/client/ui/`), and sanitization rules are documented in [.claude/skills/client-components/SKILL.md](.claude/skills/client-components/SKILL.md) and [.claude/CLAUDE.md](.claude/CLAUDE.md) — check both before adding UI code. Note: many older components still use Emotion `styled`, but Tailwind is required for anything new.
- Directory orientation: `components/` (UI), `modules/` (feature areas), `mutations/` / `subscriptions/` (Relay operations), `hooks/`, `ui/` (Radix primitives), `styles/` (incl. `paletteV3.ts`), `utils/`.

## Cross-cutting notes

- TypeScript strict mode everywhere ([tsconfig.base.json](tsconfig.base.json)); typecheck with `tsgo`, not `tsc`.
- Husky's pre-commit hook runs `pnpm precommit` (lint-staged per package).
- PR/review conventions: [docs/codeReview.md](docs/codeReview.md).
