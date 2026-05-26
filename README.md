# vault

Monorepo of vault runners. Orchestration only — each runner is a separate fork cloned into a subdir; `mise` tasks here drive them and a nushell-based demo proves the fnox ⇄ runner secret sync.

## Runners

### Servers (Bitwarden-API-compatible — pick one)

Both implement the Bitwarden REST API on Cloudflare Workers. They are **alternatives**, not complementary pieces.

- **`ov:`** [joeblew999/orangevault](https://github.com/joeblew999/orangevault) (fork of [connyay/orangevault](https://github.com/connyay/orangevault), `main` branch) — Rust → WASM. D1, R2, KV, Durable Objects. Client-side encryption (server only sees ciphertext). Carries its own `mise.toml` for deploy lifecycle. AGPL-3.0.
- **`nw:`** [joeblew999/nodewarden](https://github.com/joeblew999/nodewarden) (fork of [shuaiplus/nodewarden](https://github.com/shuaiplus/nodewarden), `joeblew999` branch) — TypeScript. Ships a webapp UI in `webapp/`. Full mise-driven deploy lifecycle. LGPL-3.0.

### Multi-tenant / auth building block

- [connyay/example-multitenant-worker](https://github.com/connyay/example-multitenant-worker) — Multi-tenant SaaS auth on Workers (Rust). Macaroon-based authz. *No license declared — read-only reference until that changes.*

### Existing client integration

- [jdx/fnox](https://github.com/jdx/fnox) ships a `bitwarden` provider out of the box. Any orangevault or nodewarden deployment is a drop-in backend for the fnox + Bitwarden/Vaultwarden installed base — no fnox changes needed.

## First-time spin-up

```bash
# One-time per machine (all CF Workers repos share these via global ~/.config/fnox/config.toml)
fnox set --global -p keychain CLOUDFLARE_API_TOKEN
fnox set --global -p keychain CLOUDFLARE_ACCOUNT_ID
fnox set --global -p keychain ORANGEVAULT_DOMAIN    # production domain for orangevault deploy

# Install toolchain (fnox, nu)
mise install

# Clone both runners into ./orangevault and ./nodewarden
mise run all:setup

# Run one locally (ov:dev auto-applies D1 migrations on first run)
mise run ov:dev      # https://localhost:8787  — accept self-signed cert in browser
mise run nw:dev      # nodewarden
```

## Live deployments

| Runner | URL | Web vault |
|---|---|---|
| orangevault | https://orangevault.gedw99.workers.dev | https://orangevault.gedw99.workers.dev/ |
| nodewarden | https://nodewarden.gedw99.workers.dev | — |

Point any Bitwarden client (web / browser extension / desktop / mobile) at the orangevault URL for the full standard-client experience.

## Two-way fnox ⇄ orangevault sync demo

Uses a dummy `FNOX_OV_DEMO` secret. Push to orangevault as a Bitwarden secure-note → mutate server-side → pull back into fnox keychain → verify both directions match.

```bash
# Against local dev (mise run ov:dev must be running in another terminal)
mise run demo:sync

# Against the deployed orangevault (no dev server needed)
mise run demo:sync:remote     # reads ORANGEVAULT_DOMAIN from fnox
```

The remote variant is the real proof: keychain → CF Workers → CF D1 → keychain, end-to-end.

## Task reference

| Task | Description |
|---|---|
| `mise run all:setup` | Clone both runners |
| `mise run ov:setup` / `mise run nw:setup` | Clone one runner |
| `mise run ov:dev` / `mise run nw:dev` | Run locally (wrangler dev; ov uses HTTPS) |
| `mise run ov:deploy` / `mise run nw:deploy` | Deploy to Workers |
| `mise run ov:tail` / `mise run nw:tail` | Tail Worker logs |
| `mise run demo:sync` | Two-way sync demo against local dev |
| `mise run demo:sync:remote` | Two-way sync demo against the deployed orangevault |

Both `ov:*` and `nw:*` tasks delegate into their respective runner's own `mise.toml`. The vault repo only carries the clone helpers, the demo, and the orchestrator.

## Conventions

- **Clones are NOT gitignored** — they're un-ignored so VS Code's Explorer surfaces them as nested working trees. Each clone is its own git repo with its own remote and branch.
- **One CF project per runner, one fnox item per runner.** Don't cross-contaminate secrets between the two.
- **Secrets live in `~/.config/fnox/config.toml` (global keychain).** Each runner has its own per-repo `fnox.toml` documenting *which* keys it needs; mise tasks read them via `fnox get` at deploy/dev time.
- **`bw` CLI is not used.** Modern Bitwarden CLI dropped the `register` subcommand. The demo talks to orangevault's HTTP API directly with placeholder crypto fields (same trick orangevault's own integration tests use).
