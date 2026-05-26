#!/usr/bin/env nu
# Clone an upstream repo into the vault repo root if not already present.
# Idempotent: skips clone if target dir exists.
#
# Usage: nu scripts/setup.nu <url> <branch> <dir-name>

def main [url: string, branch: string, dir_name: string] {
    let target = ($env.PWD | path join $dir_name)
    if ($target | path exists) {
        print $"  ✓ ($dir_name) already cloned at ($target)"
        return
    }
    print $"  → cloning ($url) [($branch)] → ($target)"
    ^git clone -b $branch $url $target
}
