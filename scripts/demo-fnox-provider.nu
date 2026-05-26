#!/usr/bin/env nu
# End-to-end proof that fnox's `bitwarden` provider reads secrets
# from the deployed orangevault.
#
# Flow:
#   1. Register a stable demo account (idempotent — already-exists is OK)
#   2. Mint API key via orangevault-cli get-apikey
#   3. bw login --apikey  (client_credentials grant, no master password)
#   4. bw unlock          → BW_SESSION
#   5. bw create item     ← put a known secret into the vault (idempotent)
#   6. Generate /tmp fnox.toml using the bitwarden provider
#   7. fnox get THE_SECRET
#   8. Assert the value matches what we put in
#   9. Cleanup
#
# Net: proves the *entire* chain — orangevault hosts the data, bw is the
# Bitwarden client, fnox reads through bw, you get the secret in any mise
# task that does `fnox get` or `fnox exec`.

const OV_SERVER  = "https://orangevault.gedw99.workers.dev"
const EMAIL      = "fnox-demo@orangevault.local"
const PASSWORD   = "fnox-demo-master-pw-stable-12345678"
const ITEM_NAME  = "fnox-demo-secret"
const SECRET_VAL = "the-quick-brown-fox-jumps-over-the-lazy-dog"
const FNOX_KEY   = "FNOX_DEMO_SECRET"
const CLI_BIN    = "orangevault/cli/target/release/orangevault-cli"

def main [] {
    print "═══ fnox bitwarden provider ⇄ orangevault demo ═══"
    print ""

    step1_register
    let api = (step2_apikey)
    let session = (step3_bw_login_unlock $api)
    step4_put_secret $session
    let tmp = (step5_fnox_config)
    step6_assert_fnox_get $tmp $session
    step7_cleanup $tmp

    print ""
    print "✓ demo complete — fnox is now plumbed through bw→orangevault"
}

def step1_register [] {
    print "── 1/7 register / reuse stable demo account ──"
    let out = (
        ^($CLI_BIN) register
            --server $OV_SERVER
            --email $EMAIL
            --password $PASSWORD
            --name "Fnox Demo"
        | complete
    )
    # exit 0 = new account; non-zero with "already" in stderr = existing
    if $out.exit_code == 0 {
        print $"  ✓ registered new ($EMAIL)"
    } else if ($out.stderr | str contains "HTTP 409") {
        print $"  ✓ ($EMAIL) already exists \(idempotent skip\)"
    } else {
        print --stderr $"  ✗ register failed: ($out.stderr | str substring 0..400)"
        exit 1
    }
}

def step2_apikey [] {
    print ""
    print "── 2/7 mint API key ──────────────────────────"
    let out = (
        ^($CLI_BIN) get-apikey
            --server $OV_SERVER
            --email $EMAIL
            --password $PASSWORD
        | complete
    )
    if $out.exit_code != 0 {
        print --stderr $"  ✗ get-apikey failed: ($out.stderr | str substring 0..400)"
        exit 1
    }
    let lines = ($out.stdout | lines)
    let client_id = ($lines | where {|l| $l | str starts-with "BW_CLIENTID="} | first | str replace "BW_CLIENTID=" "")
    let client_secret = ($lines | where {|l| $l | str starts-with "BW_CLIENTSECRET="} | first | str replace "BW_CLIENTSECRET=" "")
    print $"  ✓ client_id     = ($client_id)"
    print $"  ✓ client_secret = ($client_secret | str substring 0..8)…"
    { client_id: $client_id, client_secret: $client_secret }
}

def step3_bw_login_unlock [api: record] {
    print ""
    print "── 3/7 bw login --apikey + unlock ────────────"
    try { ^bw logout out+err> /dev/null }
    try { ^bw config server $OV_SERVER out+err> /dev/null }

    $env.BW_CLIENTID = $api.client_id
    $env.BW_CLIENTSECRET = $api.client_secret
    let login = (^bw login --apikey | complete)
    if $login.exit_code != 0 {
        print --stderr $"  ✗ bw login failed: ($login.stderr | str substring 0..400)"
        exit 1
    }
    print "  ✓ bw login --apikey   (vault locked)"

    let session = (^bw unlock $PASSWORD --raw | str trim)
    if ($session | is-empty) {
        print --stderr "  ✗ bw unlock returned empty session"
        exit 1
    }
    print $"  ✓ bw unlock           BW_SESSION=($session | str substring 0..24)…"
    $session
}

def step4_put_secret [session: string] {
    print ""
    print "── 4/7 store secret in vault \(idempotent\) ────"
    ^bw sync --session $session out+err> /dev/null

    let item = ({
        type: 1,
        name: $ITEM_NAME,
        login: { username: "demo", password: $SECRET_VAL }
    } | to json)
    let encoded = ($item | ^bw encode)

    # Check if item already exists.
    let existing = (^bw list items --search $ITEM_NAME --session $session | complete)
    if $existing.exit_code != 0 {
        print --stderr $"  ✗ bw list failed: ($existing.stderr | str substring 0..200)"
        exit 1
    }
    let items = ($existing.stdout | from json | where {|i| ($i | get -o name) == $ITEM_NAME})
    if ($items | is-empty) {
        let create = (^bw create item $encoded --session $session | complete)
        if $create.exit_code != 0 {
            print --stderr $"  ✗ bw create failed: ($create.stderr | str substring 0..200)"
            exit 1
        }
        print $"  ✓ created  '($ITEM_NAME)'"
    } else {
        let id = ($items | first | get id)
        ^bw edit item $id $encoded --session $session out+err> /dev/null
        print $"  ✓ updated  '($ITEM_NAME)'  id=($id)"
    }
    ^bw sync --session $session out+err> /dev/null
}

def step5_fnox_config [] {
    print ""
    print "── 5/7 write tmp fnox.toml ───────────────────"
    let tmp = $"/tmp/fnox-orangevault-demo-(random chars --length 6)"
    ^mkdir -p $tmp
    let cfg = $"[providers.orangevault]
type = \"bitwarden\"
backend = \"bw\"

[secrets]
($FNOX_KEY) = { provider = \"orangevault\", value = \"($ITEM_NAME)\" }
"
    $cfg | save -f $"($tmp)/fnox.toml"
    print $"  ✓ wrote ($tmp)/fnox.toml"
    $tmp
}

def step6_assert_fnox_get [tmp: string, session: string] {
    print ""
    print "── 6/7 fnox get FNOX_DEMO_SECRET ─────────────"
    $env.BW_SESSION = $session
    cd $tmp
    let got = (^fnox get $FNOX_KEY | complete)
    if $got.exit_code != 0 {
        print --stderr $"  ✗ fnox get failed: ($got.stderr | str substring 0..400)"
        exit 1
    }
    let value = ($got.stdout | str trim)
    if $value != $SECRET_VAL {
        print --stderr $"  ✗ value mismatch:"
        print --stderr $"    expected: ($SECRET_VAL)"
        print --stderr $"    got     : ($value)"
        exit 1
    }
    print $"  ✓ fnox get ($FNOX_KEY) == \"($value)\""
}

def step7_cleanup [tmp: string] {
    print ""
    print "── 7/7 cleanup ───────────────────────────────"
    try { ^bw logout out+err> /dev/null }
    ^rm -rf $tmp
    print "  ✓ logged out + tmp config removed"
}
