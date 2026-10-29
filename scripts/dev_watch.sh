#!/bin/bash
# Development loop: builds NX Hub each time .dev/request changes (written after each code change), and writes the result to
# .dev/build.log and .dev/status ("ok <request>" or "fail <request>"). With "run" in the request it also opens the new app.
# Leave it running in a Terminal tab: scripts/dev_watch.sh   (Ctrl-C stops it)
cd "$(dirname "$0")/.."
mkdir -p .dev
last="$(cat .dev/request 2>/dev/null)"
echo "Waiting for build requests in $(pwd)/.dev/request (Ctrl-C to stop)"
while true; do
    req="$(cat .dev/request 2>/dev/null)"
    if [ -n "$req" ] && [ "$req" != "$last" ]; then
        last="$req"
        echo "[$(date +%H:%M:%S)] building: $req"
        echo "building $req" > .dev/status
        if scripts/build_app.sh > .dev/build.log 2>&1; then
            echo "ok $req" > .dev/status
            echo "[$(date +%H:%M:%S)] ok"
            case "$req" in *run*)
                if pgrep -f build_ipa_from_nsp.py >/dev/null; then echo "  (a game is building: NX Hub is not restarted; reopen it when the build ends)"
                else pkill -x NXHub 2>/dev/null; sleep 1; open "NX Hub.app"; fi ;;
            esac
        else
            echo "fail $req" > .dev/status
            echo "[$(date +%H:%M:%S)] failed: see .dev/build.log"
        fi
    fi
    sleep 2
done
