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
    let user_id = (step3_admin_lists_user $creds.email)
    step4_bw_login $creds.email $creds.password
    let api = (step5_get_apikey $creds.email $creds.password)
    step6_apikey_login $api.client_id $api.client_secret
    step7_bw_logout
    step8_admin_delete_user $user_id $creds.email

    print ""
    print "✓ all steps passed"
}

def step1_preflight [] {
    print "── 1/8 preflight ─────────────────────────────"
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
    let admin_token = (try { ^fnox get ORANGEVAULT_ADMIN_TOKEN | complete } catch { null })
    if $admin_token == null or $admin_token.exit_code != 0 {
        print --stderr "  ✗ ORANGEVAULT_ADMIN_TOKEN not in fnox keychain"
        print --stderr "    fnox set --global -p keychain ORANGEVAULT_ADMIN_TOKEN"
        exit 1
    }
    print $"  ✓ cli binary present"
    print $"  ✓ orangevault         /alive    HTTP 200"
    print $"  ✓ orangevault-admin   /healthz  HTTP 200"
    print $"  ✓ ORANGEVAULT_ADMIN_TOKEN in fnox"
}

def step2_register [] {
    print ""
    print "── 2/8 register via orangevault-cli ──────────"
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
    print "── 3/8 admin ListUsers contains new account ──"

    # Verify auth gate first: unauthenticated request must be rejected.
    let unauth_code = (
        ^curl -s -o /dev/null -w "%{http_code}"
            -X POST
            -H "Content-Type: application/json"
            -d '{}'
            $"($ADMIN_SERVER)/orangevault_admin.v1.AdminService/ListUsers"
        | str trim
    )
    if $unauth_code != "401" {
        print --stderr $"  ✗ unauthenticated request returned HTTP ($unauth_code), expected 401"
        exit 1
    }
    print "  ✓ auth gate: unauthenticated → HTTP 401"

    let token = (^fnox get ORANGEVAULT_ADMIN_TOKEN | str trim)
    let resp = (
        ^curl -s -X POST
            -H "Content-Type: application/json"
            -H $"Authorization: Bearer ($token)"
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
    $id
}

def step4_bw_login [email: string, password: string] {
    print ""
    print "── 4/8 bw login + sync prove the protocol ────"
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

def step5_get_apikey [email: string, password: string] {
    print ""
    print "── 5/8 orangevault-cli get-apikey ────────────"
    try { ^bw logout out+err> /dev/null }
    let out = (
        ^($CLI_BIN) get-apikey
            --server $OV_SERVER
            --email $email
            --password $password
        | complete
    )
    if $out.exit_code != 0 {
        print --stderr $"  ✗ get-apikey failed:"
        print --stderr $out.stderr
        exit 1
    }
    # stdout is two lines: BW_CLIENTID=... and BW_CLIENTSECRET=...
    let lines = ($out.stdout | lines)
    let client_id = ($lines | where {|l| $l | str starts-with "BW_CLIENTID="} | first | str replace "BW_CLIENTID=" "")
    let client_secret = ($lines | where {|l| $l | str starts-with "BW_CLIENTSECRET="} | first | str replace "BW_CLIENTSECRET=" "")
    if ($client_id | is-empty) or ($client_secret | is-empty) {
        print --stderr "  ✗ get-apikey output missing BW_CLIENTID / BW_CLIENTSECRET"
        exit 1
    }
    print $"  ✓ client_id     = ($client_id)"
    print $"  ✓ client_secret = ($client_secret | str substring 0..8)… \(($client_secret | str length) chars\)"
    { client_id: $client_id, client_secret: $client_secret }
}

def step6_apikey_login [client_id: string, client_secret: string] {
    print ""
    print "── 6/8 bw login --apikey \(no master password\) ─"
    $env.BW_CLIENTID = $client_id
    $env.BW_CLIENTSECRET = $client_secret
    try { ^bw logout out+err> /dev/null }
    try { ^bw config server $OV_SERVER out+err> /dev/null }
    let login = (^bw login --apikey | complete)
    if $login.exit_code != 0 {
        print --stderr $"  ✗ bw login --apikey failed:"
        print --stderr $"    ($login.stderr | str substring 0..500)"
        exit 1
    }
    if not ($login.stdout | str contains "logged in") {
        print --stderr $"  ✗ unexpected bw output: ($login.stdout)"
        exit 1
    }
    print "  ✓ bw login --apikey   logged in (vault locked)"
}

def step7_bw_logout [] {
    print ""
    print "── 7/8 cleanup (bw logout) ───────────────────────────────"
    try { ^bw logout out+err> /dev/null }
    print "  ✓ bw logged out"
}

def step8_admin_delete_user [user_id: string, email: string] {
    print ""
    print "── 8/8 admin DeleteUser \(cleanup\) ────────────"
    let token = (^fnox get ORANGEVAULT_ADMIN_TOKEN | str trim)
    let body = ({ userId: $user_id } | to json)
    let resp = (
        ^curl -s -w "\n%{http_code}" -X POST
            -H "Content-Type: application/json"
            -H $"Authorization: Bearer ($token)"
            -d $body
            $"($ADMIN_SERVER)/orangevault_admin.v1.AdminService/DeleteUser"
    )
    let parts = ($resp | lines)
    let code = ($parts | last | str trim)
    let body = ($parts | drop 1 | str join "\n")
    if $code != "200" {
        print --stderr $"  ✗ DeleteUser HTTP ($code): ($body)"
        exit 1
    }
    let deleted = ($body | from json | get deletedRows)
    print $"  ✓ deleted ($email)  rows=($deleted)"
}
