#!/usr/bin/env nu
# Two-way sync demo: fnox keychain ⇄ orangevault server.
#
# Uses a DUMMY secret (FNOX_OV_DEMO) so nothing real is touched.
# Hits orangevault's HTTP API directly (skips bw CLI, which can't register
# accounts). Uses placeholder crypto values — same trick orangevault's own
# integration tests use.
#
# Target server:
#   - default: https://localhost:8787 (requires mise run ov:dev)
#   - override: set OV_SERVER env var (e.g. mise run demo:sync:remote)

const DEFAULT_SERVER = "https://localhost:8787"
const EMAIL          = "demo@orangevault.local"
const PWHASH         = "dGVzdA=="                # placeholder masterPasswordHash
const FNOX_KEY       = "FNOX_OV_DEMO"
const ITEM_NAME      = "2.fnox-sync-demo"        # "2." = Bitwarden CipherString prefix

def main [] {
    let server = ($env.OV_SERVER? | default $DEFAULT_SERVER)
    print "═══ Two-Way Sync: fnox keychain ⇄ orangevault ═══"
    print $"  target: ($server)"
    print ""

    verify_server $server
    register_if_needed $server
    let token = (login $server)
    print ""

    sync_fnox_to_ov $server $token
    sync_ov_to_fnox $server $token

    print ""
    print "✓ demo complete — both sides hold the same value"
}

def verify_server [server: string] {
    let code = (^curl -k -s -o /dev/null -w "%{http_code}" $"($server)/alive" | str trim)
    if $code != "200" {
        print --stderr $"✗ orangevault not responding at ($server)"
        exit 1
    }
    print $"✓ orangevault live at ($server)"
}

def register_if_needed [server: string] {
    let body = ({
        name: "Sync Demo",
        email: $EMAIL,
        masterPasswordHash: $PWHASH,
        key: "2.demo-key-placeholder",
        kdf: 0,
        kdfIterations: 600000,
        keys: {
            publicKey: "demo-public-key-placeholder",
            encryptedPrivateKey: "2.demo-private-key-placeholder",
        },
    } | to json)
    let res = (^curl -k -s -o /dev/null -w "%{http_code}" -X POST $"($server)/identity/accounts/register" -H "Content-Type: application/json" -d $body | str trim)
    if $res == "200" {
        print $"✓ registered new user ($EMAIL)"
    } else {
        print $"✓ ($EMAIL) already registered \(register HTTP=($res)\)"
    }
}

def login [server: string] {
    let body = $"grant_type=password&username=($EMAIL)&password=($PWHASH)&scope=api+offline_access&client_id=web&deviceType=10&deviceIdentifier=demo-device-id&deviceName=Demo"
    let res = (^curl -k -s -X POST $"($server)/identity/connect/token" -H "Content-Type: application/x-www-form-urlencoded" -d $body)
    let parsed = ($res | from json)
    let err = ($parsed | get -o error)
    if $err != null {
        print --stderr $"✗ login failed: ($parsed | to json)"
        exit 1
    }
    let token = ($parsed | get access_token)
    let preview = ($token | str substring 0..30)
    print $"✓ logged in \(access_token: ($preview)…\)"
    $token
}

def find_item [server: string, token: string] {
    let sync = (^curl -k -s $"($server)/api/sync" -H $"Authorization: Bearer ($token)" | from json)
    let ciphers = ($sync | get -o Ciphers | default [])
    let matches = ($ciphers | where {|c| ($c | get -o Name) == $ITEM_NAME})
    if ($matches | is-empty) { null } else { $matches | first }
}

def upsert_item [server: string, token: string, value: string] {
    let existing = (find_item $server $token)
    let body = ({
        type: 2,
        name: $ITEM_NAME,
        notes: $value,
        secureNote: { type: 0 },
    } | to json)
    if $existing == null {
        ^curl -k -s -o /dev/null -X POST $"($server)/api/ciphers" -H $"Authorization: Bearer ($token)" -H "Content-Type: application/json" -d $body
    } else {
        let id = ($existing | get Id)
        ^curl -k -s -o /dev/null -X PUT $"($server)/api/ciphers/($id)" -H $"Authorization: Bearer ($token)" -H "Content-Type: application/json" -d $body
    }
}

def sync_fnox_to_ov [server: string, token: string] {
    print "── fnox → orangevault ─────────────────────────"
    let value = $"hello-from-fnox-(random chars --length 8)"
    $value | ^fnox set --global -p keychain $FNOX_KEY
    print $"  fnox        [($FNOX_KEY)] = ($value)"

    upsert_item $server $token $value
    print $"  orangevault [($ITEM_NAME)] ← ($value)  \(pushed\)"

    let readback = (find_item $server $token | get -o Notes | default "(missing)")
    if $readback == $value {
        print "  ✓ verified: ov.Notes == fnox value"
    } else {
        print --stderr $"  ✗ mismatch: ov=($readback) fnox=($value)"
        exit 1
    }
}

def sync_ov_to_fnox [server: string, token: string] {
    print ""
    print "── orangevault → fnox ─────────────────────────"
    let new_value = $"changed-on-ov-(random chars --length 8)"
    upsert_item $server $token $new_value
    print $"  orangevault [($ITEM_NAME)] = ($new_value)  \(mutated server-side\)"

    let pulled = (find_item $server $token | get -o Notes | default "(missing)")
    $pulled | ^fnox set --global -p keychain $FNOX_KEY
    print $"  fnox        [($FNOX_KEY)] ← ($pulled)  \(pulled\)"

    let fnox_value = (^fnox get $FNOX_KEY | str trim)
    if $fnox_value == $new_value {
        print "  ✓ verified: fnox value == ov.Notes"
    } else {
        print --stderr $"  ✗ mismatch: fnox=($fnox_value) ov=($new_value)"
        exit 1
    }
}
