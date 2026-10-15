#!/bin/bash

# shellcheck source=shared/runtime.sh
source /orca/runtime.sh
setup_runtime /orca/bashrc.sh || exit 1

export PATH="/orca/bin:${PATH}"
export SHELL=/bin/bash

PERSIST="${PROJECTS_ROOT:-/projects}/.che-orca"
mkdir -p "$PERSIST/orca-home" || exit 1
chmod 700 "$PERSIST" || exit 1
touch "$PERSIST/ready.jsonl" || exit 1
chmod 600 "$PERSIST/ready.jsonl" || exit 1

export ORCA_USER_DATA="$PERSIST/orca-home"
export ORCA_USER_DATA_PATH="$ORCA_USER_DATA"
export ORCA_WEB_ROOT=/orca/web
export ORCA_VERSION=1.4.219

cd "${PROJECTS_ROOT:-/projects}" || exit 1

ARGS=(--bind 0.0.0.0 --port 6768 --json)
if [ -n "$ORCA_PAIRING_ADDRESS" ]; then
  ARGS+=(--pairing-address "$ORCA_PAIRING_ADDRESS")
fi

# Capture the readiness JSON, including the browser pairing URL, for deploy.sh.
while true; do
  /orca/runtime/bun-runtime /orca/runtime/orcad.js "${ARGS[@]}" > "$PERSIST/ready.jsonl" &
  ORCA_PID=$!
  wait "$ORCA_PID"
  STATUS=$?
  if [ "$STATUS" -eq 78 ]; then
    echo "Orca configuration error. Check the data directory and pairing address."
    exit "$STATUS"
  fi
  echo "Orca exited ($STATUS), restarting in 2s..."
  sleep 2
done
