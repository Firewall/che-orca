#!/bin/bash
# Orca CLI launcher. Linux names it orca-ide so it never shadows the GNOME Orca
# screen reader at /usr/bin/orca.

# The CLI finds the running orcad through the same data root the entrypoint sets.
export ORCA_USER_DATA_PATH="${ORCA_USER_DATA_PATH:-${ORCA_USER_DATA:-${PROJECTS_ROOT:-/projects}/.che-orca/orca-home}}"

export ORCA_NODE_OPTIONS="${NODE_OPTIONS-}"
export ORCA_NODE_REPL_EXTERNAL_MODULE="${NODE_REPL_EXTERNAL_MODULE-}"
unset NODE_OPTIONS NODE_REPL_EXTERNAL_MODULE

exec /orca/runtime/bun-runtime /orca/cli/cli/index.js "$@"
