# Orca for Eclipse Che

[![Container Repository on Quay](https://quay.io/repository/che-incubator/che-orca/status "Container Repository on Quay")](https://quay.io/repository/che-incubator/che-orca)

Run [Orca](https://github.com/stablyai/orca) as an editor in an Eclipse Che workspace, together with the Orca CLI and a browser that coding agents can drive and you can watch. Orca provides a browser environment for coding agents and parallel Git worktrees.

This repository contains the container recipe, devfile, and scripts that build an image and create a workspace in your user namespace.

This is an experiment. A direct OpenShift Route works around Che gateway routing limitations, and upstream Orca changes can break the integration. It is a community project with no production support commitment.

| | |
| --- | --- |
| Upstream | [stablyai/orca](https://github.com/stablyai/orca) v1.4.219 |
| CLI | `orca` |
| Browser | Chromium pages on the server, streamed into the Orca web client |
| Port | 6768 |
| Authentication | Browser pairing URL |
| Client | Browser |

## How it works

The devfile adds two components to the workspace:

- **`orca-injector`** runs as a `preStart` init container. It copies a self-contained Orca bundle out of the image and onto the shared `orca` volume mounted at `/orca`: Orca's official Linux desktop build, the UBI 9 libraries it loads, and an Xvfb virtual display.
- **`orca-runtime`** is a container contribution. Che merges it into the workspace's tool container, such as the standard [universal developer image](https://quay.io/devfile/universal-developer-image). A `postStart` command launches `/orca/entrypoint.sh`, which starts `orca-ide serve` on port 6768. In serve mode Orca's desktop build runs without a window, serves the web client, and hosts the browser pages on the bundled Xvfb, which it starts and stops itself.

When the workspace has no tool container, Che runs `orca-runtime` in the Orca image instead. Orca and its browser still start there, but the image has no fonts, Git, or coding agents, so pages render without text and there is little to work with. Use a workspace with a tool container.

Keeping the runtime on a volume means your workspace keeps the full universal developer image toolchain; Orca is injected alongside it rather than replacing it. Orca's executable and the bundled Xvfb find their libraries through a library search path (RPATH) set at build time, so nothing like `LD_LIBRARY_PATH` leaks into your terminals.

Orca advertises its own WebSocket address in the pairing URL it hands to the browser, so `deploy.sh` creates the direct Route *before* starting the workspace and passes the resulting `wss://` hostname in as `ORCA_PAIRING_ADDRESS`.

## Requirements

- An OpenShift cluster with Eclipse Che installed.
- Bash and `podman` on your machine. The deploy script uses Podman.
- Python 3 for devfile rendering.
- The `oc` CLI, logged in to the cluster.
- Permission to create DevWorkspaces, DevWorkspaceTemplates, Services, and Routes in your Che user workspace namespace.
- A registry you can push to and that workspace pods can pull from. A public image is convenient on shared clusters where you cannot configure pull credentials.

Cluster-wide editor registration additionally needs admin permissions.

## Configure

```bash
cp config.env.example config.env
${EDITOR:-vi} config.env
```

Set `NAMESPACE` to your Che user workspace namespace and `ORCA_IMAGE` to a registry you can push to:

```env
NAMESPACE=che-user-workspaces
ORCA_IMAGE=quay.io/my-org/che-orca:latest
```

Run `oc project -q` to check your current namespace. The scripts require an explicit `NAMESPACE`; the namespace hosting the Che operator is usually different from your user namespace.

| Variable | Required | Purpose |
| --- | --- | --- |
| `NAMESPACE` | yes | Che user workspace namespace to deploy into |
| `ORCA_IMAGE` | yes | Image to build and push |
| `ORCA_PAIRING_ADDRESS` | no | Only for manual registration; `deploy.sh` sets this itself |

`config.env` is a local, gitignored Bash file.

## Deploy

```bash
./deploy.sh
```

The script builds and pushes a `linux/amd64` image, creates the direct Service and Route, renders the devfile into a `DevWorkspaceTemplate`, creates the `orca-workspace` DevWorkspace, waits for the pod, and then prints the pairing URL:

```
=== Orca is ready ===

URL:      https://<route-host>/#<pairing-fragment>
Shell:    oc exec -it <pod> -c tools -n <namespace> -- bash
```

Keep that output private. The URL is a credential.

The workspace starts with no source repository. To start Orca on a repository, create the workspace from the Che dashboard instead (see [Cluster-wide registration](#cluster-wide-registration)), or clone under `/projects` after connecting. Resource names are fixed, so rerunning the script updates the same workspace, template, Service, and Route.

The workspace has a `tools` container from the universal developer image, which Orca's runtime joins, with Claude Code and OpenCode installed the way the Che dashboard installs its AI tools. The dashboard shows both as selected, and you can change the selection there. Each tool needs its API key, which you can set in the dashboard.

If the script times out waiting for the pairing URL, check the startup log:

```bash
oc exec "$POD" -c tools -n "$NAMESPACE" -- cat /orca/entrypoint-logs.txt
```

## Access and credentials

The direct Route bypasses the Che gateway and terminates TLS, redirecting HTTP to HTTPS. Orca's browser pairing controls access to that Route.

Orca writes a readiness JSON stream to `/projects/.che-orca/ready.jsonl` with mode `600`, inside a directory with mode `700`. To retrieve the pairing URL later:

```bash
source ./config.env
POD=$(oc get pods -n "$NAMESPACE" \
  -l controller.devfile.io/devworkspace_name=orca-workspace \
  --no-headers | awk '$3 != "Completed" && $1 !~ /cleanup/ {print $1; exit}')
oc exec "$POD" -c tools -n "$NAMESPACE" -- \
  cat /projects/.che-orca/ready.jsonl
```

Use the full `pairing.webClientUrl` from the `orca_server_ready` record, **including the URL fragment**. Keep pairing URLs and logs out of issues and pull requests.

## Orca CLI

The CLI comes from the same Orca release as the server. `/orca/bashrc.sh` adds `/orca/bin` to `PATH`, so it works in any interactive shell, and terminals that Orca opens have it too. It is also available as `orca-ide`, the name Orca's skills tell agents to use outside Orca's terminals, where `orca` could be the GNOME screen reader:

```bash
orca --help
```

The CLI finds the running server through Orca's profile, which the entrypoint links from `~/.config/orca` to `/projects/.che-orca/orca-home`.

### Projects

On every start, the entrypoint runs `orca repo add` for each Git repository directly under `/projects`, so repositories Che cloned when it created the workspace are already open in Orca. Repositories you clone later can be added from the Orca UI or with:

```bash
orca repo add --path /projects/my-repo
```

### Agents

The image ships Orca's agent skills for the pinned release, such as `orca-cli`, which tells agents about the CLI and its browser. Each skill is a short stub that loads the guide for the installed Orca version with `orca skills get`. On start, the entrypoint links them into `~/.claude/skills` for Claude Code and `~/.agents/skills` for OpenCode and Codex, and leaves skills you installed there under the same name alone. This needs no network access, unlike `orca skills install`, which fetches the skills with `npx` from GitHub.

The entrypoint also sets the Orca host name to the workspace name. When `claude` or `codex` is on `PATH`, it writes Orca's agent status hooks. OpenCode gets its status plugin from Orca's terminals instead. Skill links and hooks live in the home directory, so this runs again whenever the container restarts. Results appear in `/orca/entrypoint-logs.txt`.

### Persistent state

Everything that should survive a workspace restart lives under `/projects/.che-orca`:

| Path | Contents |
| --- | --- |
| `orca-home/` | Orca's profile, linked from `~/.config/orca`: workspaces, browser cookies and storage, CLI runtime pointer |
| `ready.jsonl` | Readiness stream, including the pairing URL |

## Browser

Agents drive the browser through the CLI:

```bash
orca tab create --url https://example.com
orca snapshot                 # accessibility tree with element refs such as @e4
orca click --element @e4
orca fill --element @e7 --value "hello"
orca goto --url http://localhost:3000
orca screenshot --format png
```

Run `orca --help` for the full list, including tabs, cookies, console, network, and `orca exec` for raw `agent-browser` commands.

Each tab belongs to a worktree and appears as a browser tab in the Orca web client. The pane streams the live page from the server, and you can click and type in it to take over from an agent.

## Remove a deployment

```bash
./teardown.sh
```

Teardown removes the workspace, editor template, direct Service, and Route in `NAMESPACE`. Storage retention follows your cluster's DevWorkspace policy, so back up anything you need from `/projects` first.

## Cluster-wide registration

`deploy.sh` creates a template in your own namespace. To add Orca to the dashboard editor picker for everyone, set `NAMESPACE` to the Che installation namespace and run:

```bash
make register
```

Users can then pick Orca on the dashboard's Create Workspace page and enter a repository under Import from Git. Che clones the repository into `/projects` and Orca registers it on start. The same choice works as a link:

```text
https://<che-host>/#https://github.com/my-org/my-repo?che-editor=stablyai/orca-editor/latest
```

Remove it with `make unregister`. Manual registration also needs `ORCA_PAIRING_ADDRESS` set to a reachable `wss://` endpoint. The deployment script calculates that address automatically. Restore your user namespace in `config.env` before deploying or tearing down a workspace.

## Versions and limitations

The Containerfile pins Orca to v1.4.219 and checks the release RPM and Orca's license file against SHA-256 checksums. Orca's agent skills come from the same release tag and are checked against the checksums listed in the release build. Update `ORCA_VERSION` and the checksums together when testing a newer release. Base images and the universal developer image tag still follow moving releases, so builds are not fully reproducible.

Orca's headless browser needs an X display, and neither UBI 9 nor UBI 10 ships an X server. [`build/build-xvfb.sh`](build/build-xvfb.sh) builds Xvfb on UBI 9 from pinned X.Org sources, whose release signatures were checked when the checksums were recorded, together with the few X libraries UBI lacks. Everything else in the bundle is copied from UBI 9 packages. A verification stage starts Orca in a bare `ubi9-minimal` image and opens a browser tab, so the build fails if the bundle depends on anything outside it. Xvfb, patchelf, and the Orca bundle build in separate stages, so changing one does not rebuild the others.

The bundle runs in UBI 9 based workspace images, glibc 2.34 or newer, such as the universal developer image. Pages render text with the workspace image's fontconfig and fonts.

Orca runs Chromium with `--no-sandbox`. OpenShift's restricted security context blocks the setuid helper and user namespaces that Chromium's sandboxes need. Upstream runs its container tests the same way.

Orca finds no keyring service in the workspace, so it stores secrets, such as integration tokens, unencrypted in its profile under `/projects/.che-orca/orca-home`. That directory is readable only by the workspace user.

`orca screenshot` of a tab that nobody is viewing can return a blank image ([stablyai/orca#26138](https://github.com/stablyai/orca/issues/26138), fix proposed in [#26139](https://github.com/stablyai/orca/pull/26139)). Snapshots, actions, `eval`, and the live view are not affected, and screenshots work while the tab is open in the web client.

The published image targets `linux/amd64` and `linux/arm64`; `make build` builds `linux/amd64` only. The builder compiles Xvfb for the target architecture, so building `linux/amd64` on an ARM machine runs under emulation and is slow. `s390x` and `ppc64le` are not supported because Orca publishes no Linux builds for them.

The entrypoint restarts the server after two seconds if it exits. Exit code 78 is treated as a configuration error and is not retried.

## Repository layout

```
Containerfile                   builds and verifies the Orca bundle on UBI 9, ubi9-minimal injector image
build/build-xvfb.sh             builds Xvfb and the X libraries UBI lacks
build/bundle-libraries.sh       copies the UBI libraries the bundle loads, with their licenses
build/set-rpath.sh              points Orca's executable at the bundled libraries
build/verify-bundle.sh          checks that the bundle runs on a bare ubi9-minimal image
build/fetch-skills.py           fetches Orca's agent skills and checks them against the release manifest
devfile.yaml                    injector and runtime components, preStart/postStart events
deploy.sh                       build, push, Route, template, workspace, pairing URL
teardown.sh                     remove workspace, template, Service, Route
entrypoint-init-container.sh    copies the bundle onto the /orca volume
entrypoint.sh                   persistent state, starts orca-ide serve on 6768
shared/                         deploy helpers, devfile renderer, runtime setup
config.env.example              documented local configuration
Makefile                        build, push, and admin registration targets
```

Changes to the editor components, commands, and events belong in `devfile.yaml`. Deployment and admin registration use the same renderer, which substitutes configuration values and preserves runtime variables such as `$PATH`.

For local changes, check Bash syntax and run ShellCheck before testing a deployment. Keep credentials and rendered devfiles out of commits.

## License

The integration code is licensed under [MIT](LICENSE). [Orca](https://github.com/stablyai/orca) keeps its own license. This integration bundles Orca's unmodified release build and includes its [upstream license](https://github.com/stablyai/orca/blob/v1.4.219/LICENSE) at `/orca/LICENSE`. The licenses of the bundled X.Org and UBI packages are under `/orca/runtime/share/licenses`. Preserve upstream license files and notices when redistributing images.
