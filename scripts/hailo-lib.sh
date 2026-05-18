#!/usr/bin/env bash
# Shared helpers for install.sh and restore.sh.
# Sourced at runtime, not executed directly.

# hailo_init_script_lookup
#
# Locate any registered TrueNAS init script related to this fork (matches
# "hailo-preinit", "hailo-postinit", or ".config/hailo" in the command/script
# field). Used by install.sh for --check probing and registration updates,
# and by restore.sh for deregistration.
#
# Prints:
#   <id>|<when>|<enabled>  if found (when=PREINIT/POSTINIT/...; enabled=True/False)
#   (empty)                if no matching script is registered
#   error                  if midclt is unreachable / response unparseable
#
# Always exits 0; callers branch on the printed token.
hailo_init_script_lookup() {
    local result
    # Use %-formatting (not f-strings): the surrounding bash uses single
    # quotes for the python source so we can't put `'` inside the python
    # body, and an f-string with `"` keys would need `\"` escapes that
    # don't parse inside f-string `{}` blocks.
    result=$(midclt call initshutdownscript.query 2>/dev/null \
        | python3 -c '
import sys, json
try:
    scripts = json.load(sys.stdin)
    for s in scripts:
        cmd = s.get("command", "") or s.get("script", "")
        if "hailo-preinit" in cmd or "hailo-postinit" in cmd or ".config/hailo" in cmd:
            print("%s|%s|%s" % (s["id"], s.get("when", ""), s.get("enabled", False)), end="")
            sys.exit(0)
except Exception:
    print("error", end="")
' 2>/dev/null) || result=error
    printf '%s' "$result"
}
