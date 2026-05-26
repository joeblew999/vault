# vault
mono repo of vault runners.

## Things to look at

- [connyay/orangevault](https://github.com/connyay/orangevault) — Bitwarden-compatible password vault API in Rust, compiled to WASM, deployed on Cloudflare Workers. Client-side encryption (server sees only ciphertext). Uses D1, R2, KV, Durable Objects. AGPL-3.0.
  - **fnox integration**: [jdx/fnox](https://github.com/jdx/fnox) ships a `bitwarden` provider out of the box, so any orangevault deployment is a drop-in backend for the large set of devs already using fnox + Bitwarden/Vaultwarden — no fnox changes needed.
- [connyay/example-multitenant-worker](https://github.com/connyay/example-multitenant-worker) — Multi-tenant SaaS auth on Cloudflare Workers (Rust). Sessions, invites, billing account membership, organizations, SSO, password reset. Authz via macaroons (signature + caveat checks, no DB on hot path). No license declared.
