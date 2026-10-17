#!/usr/bin/env python3
"""Download the agent skills of an Orca release and check them against its manifest.

Usage: fetch-skills.py <current-manifest.json> <version> <destination>

The release build lists its skills, with a SHA-256 for every file, in
resources/skills/current-manifest.json but does not ship the files. They are
small stubs that load the guide for the installed Orca version from the CLI.
This fetches each file from the release tag, which is what `orca skills install`
installs with npx from GitHub at run time.
"""

import hashlib
import json
import os
import sys
import urllib.request

manifest_path, version, destination = sys.argv[1:]

with open(manifest_path, encoding="utf-8") as manifest:
    skills = json.load(manifest)["skills"]

for skill in skills:
    for entry in skill["files"]:
        url = (
            f"https://raw.githubusercontent.com/stablyai/orca/v{version}/"
            f"{skill['sourcePath']}/{entry['path']}"
        )
        with urllib.request.urlopen(url, timeout=60) as response:
            data = response.read()
        digest = hashlib.sha256(data).hexdigest()
        if digest != entry["exactSha256"]:
            sys.exit(f"Checksum mismatch for {url}: expected {entry['exactSha256']}, got {digest}")
        path = os.path.join(destination, skill["name"], entry["path"])
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as output:
            output.write(data)
        if entry.get("executable"):
            os.chmod(path, 0o755)
    print(f"Fetched skill {skill['name']}")
