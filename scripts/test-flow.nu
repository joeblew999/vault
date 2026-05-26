#!/usr/bin/env nu
# End-to-end test of the vault stack against the deployed orangevault +
# orangevault-admin workers.
#
# Exercises every layer of the pipeline:
#   1. orangevault-cli register      — real Bitwarden crypto, POSTs /accounts/register
#   2. orangevault-admin ListUsers   — confirms the new account is in D1
#   3. bw login                      — confirms a stock Bitwarden client can
#                                       log into the account we just made
#                                       (proves the crypto matches the protocol)
#   4. bw logout                     — cleanup
#
# Uses a unique email per run so the test is idempotent against the
# deployed server. Doesn't delete the account — see admin DeleteUser
# (TODO) for that.

const OV_SERVER     = "https://orangevault.gedw99.workers.dev"
const ADMIN_SERVER  = "https://orangevault-admin.gedw99.workers.dev"
const CLI_BIN       = "orangevault/cli/target/release/orangevault-cli"

def main [] {
    print "═══ Vault stack end-to-end test ═══"
    print $"  orangevault:        ($OV_SERVER)"
    print $"  orangevault-admin:  ($ADMIN_SERVER)"
    print ""

    step1_preflight
    let creds = (step2_register)
    step3_admin_lists_user $creds.email
    step4_bw_login $creds.email $creds.password
    step5_bw_logout

    print ""
    print "✓ all steps passed"
}

def step1_preflight [] {
    print "── 1/5 preflight ─────────────────────────────"
    if not ($CLI_BIN | path exists) {
        print --stderr $"  ✗ ($CLI_BIN) missing — run: mise run cli:build"
        exit 1
    }
    let ov_code = (^curl -s -o /dev/null -w "%{http_code}" $"($OV_SERVER)/alive" | str trim)
    if $ov_code != "200" {
        print --stderr $"  ✗ orangevault not responding \(HTTP ($ov_code)\)"
        exit 1
    }
    let admin_code = (^curl -s -o /dev/null -w "%{http_code}" $"($ADMIN_SERVER)/healthz" | str trim)
    if $admin_code != "200" {
        print --stderr $"  ✗ orangevault-admin not responding \(HTTP ($admin_code)\)"
        exit 1
    }
    print $"  ✓ cli binary present"
    print $"  ✓ orangevault         /alive    HTTP 200"
    print $"  ✓ orangevault-admin   /healthz  HTTP 200"
}

def step2_register [] {
    print ""
    print "── 2/5 register via orangevault-cli ──────────"
    let suffix = (random chars --length 8 | str downcase)
    let email = $"e2e-($suffix)@orangevault.local"
    let password = $"pw-(random chars --length 16)"
    let name = $"E2E ($suffix)"

    let result = (
        ^($CLI_BIN) register
            --server $OV_SERVER
            --email $email
            --password $password
            --name $name
        | complete
    )
    if $result.exit_code != 0 {
        print --stderr $"  ✗ cli register failed:"
        print --stderr $result.stderr
        exit 1
    }
    print $"  ✓ registered ($email)"
    { email: $email, password: $password, name: $name }
}

def step3_admin_lists_user [email: string] {
    print ""
    print "── 3/5 admin ListUsers contains new account ──"
    let resp = (
        ^curl -s -X POST
            -H "Content-Type: application/json"
            -d '{"limit":100}'
            $"($ADMIN_SERVER)/orangevault_admin.v1.AdminService/ListUsers"
        | from json
    )
    let users = ($resp | get -o users | default [])
    let found = ($users | where {|u| ($u | get -o email) == $email})
    if ($found | is-empty) {
        print --stderr $"  ✗ ($email) NOT in admin ListUsers response"
        print --stderr $"  emails seen: ($users | get email | str join ', ')"
        exit 1
    }
    let id = ($found | first | get id)
    print $"  ✓ ($email) found  id=($id)"
}

def step4_bw_login [email: string, password: string] {
    print ""
    print "── 4/5 bw login + sync prove the protocol ────"
    try { ^bw logout out+err> /dev/null }
    try { ^bw config server $OV_SERVER out+err> /dev/null }
    let login = (^bw login $email $password --raw | complete)
    if $login.exit_code != 0 {
        print --stderr $"  ✗ bw login failed:"
        print --stderr $"    ($login.stderr | str substring 0..500)"
        exit 1
    }
    let session = ($login.stdout | str trim)
    if ($session | is-empty) or ($session | str length) < 20 {
        print --stderr $"  ✗ bw login returned empty/short session"
        exit 1
    }
    print $"  ✓ bw login   session=($session | str substring 0..30)…"

    # Pull the full vault — exercises /api/sync (RSA key load + cipher list
    # + folder list + sends + collections + policies + profile). Fails if
    # any of those endpoints is broken for a freshly-registered account.
    let sync = (^bw sync --session $session | complete)
    if $sync.exit_code != 0 {
        print --stderr $"  ✗ bw sync failed:"
        print --stderr $"    ($sync.stderr | str substring 0..500)"
        exit 1
    }
    print "  ✓ bw sync    full vault pulled"

    # New account → empty cipher list. Confirms the list endpoint returns
    # a well-formed (empty) array, not an error.
    let items = (^bw list items --session $session | complete)
    if $items.exit_code != 0 {
        print --stderr $"  ✗ bw list items failed:"
        print --stderr $"    ($items.stderr | str substring 0..500)"
        exit 1
    }
    let parsed = ($items.stdout | from json)
    print $"  ✓ bw list    ($parsed | length) item\(s\) in fresh vault"
}

def step5_bw_logout [] {
    print ""
    print "── 5/5 cleanup ───────────────────────────────"
    try { ^bw logout out+err> /dev/null }
    print "  ✓ bw logged out"
}
