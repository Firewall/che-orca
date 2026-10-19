#!/bin/bash
# OpenShift's restricted security context blocks setuid helpers and user namespaces, so
# neither Chromium sandbox can start. orcad passes no browser arguments of its own.
exec /orca/chromium/app/chrome-headless-shell --no-sandbox "$@"
