#!/bin/bash

# shellcheck source=shared/runtime.sh
source /orca/runtime.sh
setup_runtime /orca/bashrc.sh || exit 1

# Che's AI tool injectors put claude and opencode in /injected-tools/bin, which only
# shell profiles add to PATH, so add it here for agent setup and Orca's terminals.
export PATH="/orca/bin:/injected-tools/bin:${PATH}"
export SHELL=/bin/bash

PERSIST="${PROJECTS_ROOT:-/projects}/.che-orca"
mkdir -p "$PERSIST/orca-home" || exit 1
chmod 700 "$PERSIST" || exit 1
touch "$PERSIST/ready.jsonl" || exit 1
chmod 600 "$PERSIST/ready.jsonl" || exit 1

# Orca keeps workspaces, the browser profile, and the CLI's runtime pointer in its profile.
mkdir -p "$HOME/.config" || exit 1
ln -sfn "$PERSIST/orca-home" "$HOME/.config/orca" || exit 1

# Orca's skills tell agents about the CLI, its browser, and Orca's other features. The image
# ships them for this Orca version. Claude Code reads ~/.claude/skills; OpenCode and Codex read
# ~/.agents/skills. Leave a skill the user installed there alone.
for skills_dir in "$HOME/.claude/skills" "$HOME/.agents/skills"; do
  for skill in /orca/skills/*/; do
    link="$skills_dir/$(basename "$skill")"
    if [ -L "$link" ] || [ ! -e "$link" ]; then
      { mkdir -p "$skills_dir" && ln -sfn "${skill%/}" "$link"; } ||
        echo "Could not link Orca skill $link"
    fi
  done
done

cd "${PROJECTS_ROOT:-/projects}" || exit 1

# Orca starts the bundled Xvfb from PATH for its browser pages when DISPLAY is unset. X servers refuse to create the
# shared socket directory without root, so create it the way hosts do at boot.
mkdir -p /tmp/.X11-unix && chmod 1777 /tmp/.X11-unix

# OpenShift's restricted security context blocks setuid helpers and user
# namespaces, so neither Chromium sandbox can start.
ARGS=(--no-sandbox serve --port 6768 --json)
if [ -n "$ORCA_PAIRING_ADDRESS" ]; then
  ARGS+=(--pairing-address "$ORCA_PAIRING_ADDRESS")
fi

# Register the Git repositories Che cloned under /projects. Orca prints its
# readiness line only after the CLI socket and orca-runtime.json are in place.
# Orca returns the existing entry for a known path, so this is safe on every start.
register_projects() {
  local dir
  for dir in "${PROJECTS_ROOT:-/projects}"/*/; do
    [ -d "${dir}.git" ] || continue
    if orca repo add --path "${dir%/}" >/dev/null; then
      echo "Registered ${dir%/} in Orca"
    else
      echo "Could not register ${dir%/} in Orca"
    fi
  done
}

# Install Orca's status hooks for Claude and Codex. They live in the home directory,
# which Che recreates with the container, so a marker in /tmp skips the work when
# only Orca restarts. mkdir claims it atomically, and a failure releases it so the
# next Orca start retries. OpenCode gets its plugin from Orca's terminals instead.
configure_agent_hooks() {
  local marker=/tmp/che-orca-agents-configured
  command -v claude >/dev/null || command -v codex >/dev/null || return
  mkdir "$marker" 2>/dev/null || return
  # Orca writes hook files only when the setting changes, and it defaults to on.
  if orca agent hooks off >/dev/null && orca agent hooks on >/dev/null; then
    echo "Installed Orca agent status hooks"
  else
    echo "Could not install Orca agent status hooks"
    rmdir "$marker"
  fi
}

setup_orca() {
  register_projects
  if [ -n "${DEVWORKSPACE_NAME:-}" ]; then
    orca host name --name "$DEVWORKSPACE_NAME" >/dev/null ||
      echo "Could not set the Orca host name"
  fi
  configure_agent_hooks
}

# Wait for the readiness line, then set up Orca in the background while this
# keeps draining output, so Orca never blocks on or writes to a closed pipe.
register_when_ready() {
  local line
  while IFS= read -r line; do
    case "$line" in
      *'"type":"orca_server_ready"'*)
        setup_orca &
        break
        ;;
    esac
  done
  cat >/dev/null
}

# Capture the readiness JSON, including the browser pairing URL, for deploy.sh.
while true; do
  # Che can set DISPLAY=:0 with no X server behind it, which stops Orca from starting Xvfb.
  env -u DISPLAY /orca/app/orca-ide "${ARGS[@]}" \
    > >(tee "$PERSIST/ready.jsonl" | register_when_ready) &
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
