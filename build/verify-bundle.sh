#!/bin/bash
# Check that the bundle runs on a minimal UBI image that has none of its dependencies.
set -euo pipefail

root="$1"

for program in "$root/app/orca-ide" "$root/app/chrome_crashpad_handler" \
  "$root/runtime/bin/Xvfb" "$root/runtime/bin/xkbcomp"; do
  if ldd "$program" | grep 'not found'; then
    echo "$program has unresolved libraries" >&2
    exit 1
  fi
done

# Start Orca the way entrypoint.sh does, so it launches the bundled Xvfb itself. ldd cannot
# see libraries that Chromium loads with dlopen(); opening a browser tab loads them all.
mkdir -p /tmp/.X11-unix
chmod 1777 /tmp/.X11-unix
home="$(mktemp -d)"
export HOME="$home" PATH="$root/bin:$PATH"
"$root/app/orca-ide" --no-sandbox serve --port 0 --no-pairing --json \
  > "$home/ready.jsonl" 2> "$home/serve.log" &
orca=$!
trap 'kill "$orca" 2>/dev/null || true' EXIT

fail() {
  echo "$1" >&2
  cat "$home/serve.log" >&2
  exit 1
}

for _ in $(seq 1 120); do
  grep -q '"orca_server_ready"' "$home/ready.jsonl" && break
  kill -0 "$orca" 2>/dev/null || fail "Orca exited during startup:"
  sleep 0.5
done
grep -q '"orca_server_ready"' "$home/ready.jsonl" || fail "Orca did not become ready:"

orca tab create --url about:blank --json > "$home/tab.json" 2>&1 || true
grep -q '"ok": true' "$home/tab.json" || fail "Orca could not open a browser tab: $(cat "$home/tab.json")"
echo "Orca opened a browser tab on the bundled Xvfb"
