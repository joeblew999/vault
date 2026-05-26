# vault

Monorepo of vault runners. Pure orchestration — upstream repos clone in on demand (gitignored), and `mise` tasks here drive them.

## Runners

### Servers (Bitwarden-API-compatible — pick one)

Both implement the Bitwarden REST API on Cloudflare Workers. They are **alternatives**, not complementary pieces.

- **`ov:`** [connyay/orangevault](https://github.com/connyay/orangevault) — Rust → WASM. D1, R2, KV, Durable Objects. Client-side encryption (server only sees ciphertext). AGPL-3.0.
- **`nw:`** [joeblew999/nodewarden](https://github.com/joeblew999/nodewarden) (fork of [shuaiplus/nodewarden](https://github.com/shuaiplus/nodewarden), `joeblew999` branch) — TypeScript. Ships a webapp UI in `webapp/`. Already has a full mise-driven deploy lifecycle. LGPL-3.0.

### Multi-tenant / auth building block

- [connyay/example-multitenant-worker](https://github.com/connyay/example-multitenant-worker) — Multi-tenant SaaS auth on Workers (Rust). Macaroon-based authz. *No license declared — read-only reference until that changes.*

### Existing client integration

- [jdx/fnox](https://github.com/jdx/fnox) ships a `bitwarden` provider out of the box. Any orangevault or nodewarden deployment is a drop-in backend for the fnox + Bitwarden/Vaultwarden installed base — no fnox changes needed.

## First-time spin-up

```bash
# One-time per machine
fnox set --global -p keychain CLOUDFLARE_API_TOKEN
fnox set --global -p keychain CLOUDFLARE_ACCOUNT_ID

# Install toolchain (node, wrangler, fnox, nu)
mise install

# Clone both runners into ./orangevault and ./nodewarden (gitignored)
mise run all:setup

# Run one locally
mise run nw:dev      # or ov:dev
```

## Task reference

| Task | Description |
|---|---|
| `mise run all:setup` | Clone both runners |
| `mise run ov:setup` / `mise run nw:setup` | Clone one runner |
| `mise run ov:dev` / `mise run nw:dev` | Run locally (wrangler dev) |
| `mise run ov:deploy` / `mise run nw:deploy` | Deploy to Workers |
| `mise run ov:tail` / `mise run nw:tail` | Tail Worker logs |

`nw:*` tasks delegate to nodewarden's own mise tasks (it has a fully-featured `mise.toml`). `ov:*` tasks call wrangler directly (orangevault has no mise.toml).

## Conventions

- **Clones are not vendored.** They land in `./orangevault/` and `./nodewarden/`, both gitignored. The vault repo only holds orchestration. No AGPL/LGPL distribution concerns for this repo.
- **One CF project per runner, one fnox item per runner.** Don't cross-contaminate secrets between the two.
- **Per-runner local overrides** (wrangler IDs, `.dev.vars`) live inside the cloned dirs — they're outside this repo's git tree so local edits don't leak upstream or here.
