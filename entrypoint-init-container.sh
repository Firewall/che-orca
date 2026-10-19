#!/bin/bash
set -e

# The volume outlives the container, and cp -r into an existing directory nests the copy
# instead of replacing it, so clear the previous injection first.
find /orca -mindepth 1 -delete

cp /usr/local/bin/orca-entrypoint.sh /orca/entrypoint.sh
cp /usr/local/bin/orca-pairing-page.js /orca/pairing-page.js
cp /usr/local/bin/shared-runtime.sh /orca/runtime.sh
cp /usr/local/bin/shared-bashrc.sh /orca/bashrc.sh
cp -r /opt/orca/runtime /orca/runtime
cp -r /opt/orca/web /orca/web
cp -r /opt/orca/cli /orca/cli
cp -r /opt/orca/bin /orca/bin
cp -r /opt/orca/skills /orca/skills
cp /opt/orca/LICENSE /orca/LICENSE

echo "Orca injector complete"
