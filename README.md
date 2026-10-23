# Orca for Eclipse Che

[![Container Repository on Quay](https://quay.io/repository/che-incubator/che-orca/status "Container Repository on Quay")](https://quay.io/repository/che-incubator/che-orca)

Run [Orca](https://github.com/stablyai/orca) as an editor in an Eclipse Che workspace, together with the Orca CLI. Orca provides a browser environment for coding agents and parallel Git worktrees.

This repository contains the container recipe, devfile, and scripts that build an image and create a workspace in your user namespace.

For a fresh local cluster, follow the [CRC setup and end-to-end test walkthrough](docs/CRC.md).

This is an experiment. A direct OpenShift Route works around Che gateway routing limitations, and upstream Orca changes can break the integration. It is a community project with no production support commitment.

| | |
| --- | --- |
| Upstream | [stablyai/orca](https://github.com/stablyai/orca) v1.4.219 |
| CLI | `orca` |
| Port | 6768 |
| Authentication | Browser pairing URL |
| Client | Browser |

## How it works

The devfile adds two components to the workspace:

- **`orca-injector`** runs as a `preStart` init container. It copies the Orca standalone runtime, prebuilt web client, and Orca CLI out of the image and onto the shared `orca` volume mounted at `/orca`.
- **`orca-runtime`** is a container contribution to the standard [universal developer image](https://quay.io/devfile/universal-developer-image). A `postStart` command launches `/orca/entrypoint.sh`, which starts `orcad` on port 6768 and serves the web client from `/orca/web`.

Keeping the runtime on a volume means your workspace keeps the full universal developer image toolchain; Orca is injected alongside it rather than replacing it.

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
| `ORCA_PLATFORM` | no | Image platform, default `linux/amd64`; use `linux/arm64` for CRC on Apple silicon |
| `ORCA_AGENT_NAMESPACE_TEMPLATE` | no | Enables [agent environments](#agent-environments), e.g. `<username>-agent-devspaces` |
| `ORCA_AGENT_RUNTIME_CLASS` | no | RuntimeClass for agent DevWorkspaces, e.g. `kata` |

`config.env` is a local, gitignored Bash file.

## Deploy

```bash
./deploy.sh
```

The script builds and pushes an image (`linux/amd64` unless `ORCA_PLATFORM` is set), creates the direct Service and Route, renders the devfile into a `DevWorkspaceTemplate`, creates the `orca-workspace` DevWorkspace, waits for the pod, and then prints the pairing URL:

```
=== Orca is ready ===

URL:      https://<route-host>/#<pairing-fragment>
Shell:    oc exec -it <pod> -c orca-runtime -n <namespace> -- bash
```

Keep that output private. The URL is a credential.

The workspace starts with no source repository. Clone your code under `/projects` after connecting. Resource names are fixed, so rerunning the script updates the same workspace, template, Service, and Route.

If the script times out waiting for the pairing URL, check the startup log:

```bash
oc exec "$POD" -c orca-runtime -n "$NAMESPACE" -- cat /orca/entrypoint-logs.txt
```

## Agent environments

Optionally, each new Orca workspace gets its own DevWorkspace in a separate agent namespace, for example `alice-agent-devspaces`. The main Orca workspace stays the controller, and the browser connects to each child runtime directly. Agents in the same Orca workspace share its DevWorkspace, because they share its worktree.

Add these settings to `config.env`, then run `./deploy.sh`:

```env
ORCA_AGENT_NAMESPACE_TEMPLATE='<username>-agent-devspaces'
# Optional, when the cluster already provides this RuntimeClass:
# ORCA_AGENT_RUNTIME_CLASS=kata
```

These settings mirror a proposed `devAgentEnvironments` section in the CheCluster, and `deploy.sh` does what che-operator would do with it:

- Resolves `<username>` with `oc whoami` and checks that the agent namespace exists. Creating it on first use needs the operator; until then, create it with `oc new-project` or ask an administrator.
- Applies `orca-agent-editor` to the agent namespace, rendered from the same `devfile.yaml`.
- Binds the `orca-workspace-provisioner` Role in the agent namespace to the ServiceAccounts of your user namespace. It allows managing DevWorkspaces, Services, and Routes, reading the editor template and pods, and pod exec for Orca's private readiness file. It does not allow reading Secrets, changing RBAC, or creating namespaces.
- Creates the `orca-agent-environment` ConfigMap in your user namespace. The DevWorkspace Operator mounts it as environment variables into your workspaces, so the editor template carries no per-user settings and also works when registered on the dashboard.

In the new-workspace composer, **Che DevWorkspace** is selected by default for Git projects. It creates a DevWorkspace with its own storage, clones the project's Git origin into `/projects/source`, starts Orca there behind its own TLS Route, and connects it to the browser. Uncommitted changes and unpublished branches in the controller are not copied. Configure Git and coding-agent credentials in the agent namespace; credentials embedded in HTTPS Git URLs are rejected. Agent pods run with `ORCA_AGENT_RUNTIME_CLASS` when it is set. Their ServiceAccount has no RBAC in the agent namespace, so the token the DevWorkspace Operator mounts only grants basic authenticated access.

Orca's sleep, wake, and cleanup controls stop, restart, and delete the child DevWorkspace. Failed or cancelled provisioning removes what it created; failed cleanup stays recorded for retry. Pairing credentials for child runtimes are stored by the controller and kept only in browser memory.

Agent runtimes have separate collapsible sections in the workspace sidebar and
are grouped under **Agent environments** in server settings. Successfully cleaned
environments are hidden from the lifecycle list; suspended environments and failed
cleanups remain available so they can be resumed or retried.
Once an agent environment has a named worktree, its primary checkout is hidden
from the sidebar. The checkout remains on disk as the backing repository; the
controller's primary checkout stays visible.

Folder projects are not supported, and local workspaces in the controller remain available.

`./teardown.sh` removes the ConfigMap, the controller's child DevWorkspaces, Services, and Routes, the provisioner RBAC, and the agent editor template. It keeps the agent namespace.

## Access and credentials

The direct Route bypasses the Che gateway and terminates TLS, redirecting HTTP to HTTPS. Orca's browser pairing controls access to that Route.

Orca writes a readiness JSON stream to `/projects/.che-orca/ready.jsonl` with mode `600`, inside a directory with mode `700`. To retrieve the pairing URL later:

```bash
source ./config.env
POD=$(oc get pods -n "$NAMESPACE" \
  -l controller.devfile.io/devworkspace_name=orca-workspace \
  --no-headers | awk '$3 != "Completed" && $1 !~ /cleanup/ {print $1; exit}')
oc exec "$POD" -c orca-runtime -n "$NAMESPACE" -- \
  cat /projects/.che-orca/ready.jsonl
```

Use the full `pairing.webClientUrl` from the `orca_server_ready` record, **including the URL fragment**. Keep pairing URLs and logs out of issues and pull requests.

## Orca CLI

OpenCode 2.1.4 is bundled as a standalone binary. The injector copies it to
`/orca/bin/opencode`, on the runtime and interactive shell PATH, in both the main
workspace and child DevWorkspaces. Startup checks `opencode --version` before
starting Orca. No download or installation is needed at workspace startup.
Run `opencode` in a workspace terminal and select a free model to get started
without credentials. After updating the image with `./deploy.sh`, restart existing
workspaces to refresh their injected binaries.

The image includes the Orca CLI from the same release as the runtime. It runs on the Bun runtime that ships with `orcad`, so it does not depend on the workspace's Node.js version. `/orca/bashrc.sh` adds `/orca/bin` to `PATH`, so it works in any interactive shell:

```bash
orca --help
```

The CLI finds the running server through `ORCA_USER_DATA_PATH`, which defaults to `/projects/.che-orca/orca-home`.

### Persistent state

Everything that should survive a workspace restart lives under `/projects/.che-orca`:

| Path | Contents |
| --- | --- |
| `orca-home/` | Orca user data, set by `ORCA_USER_DATA` |
| `ready.jsonl` | Readiness stream, including the pairing URL |

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

Remove it with `make unregister`. Manual registration also needs `ORCA_PAIRING_ADDRESS` set to a reachable `wss://` endpoint. The deployment script calculates that address automatically. Restore your user namespace in `config.env` before deploying or tearing down a workspace.

## Versions and limitations

The Containerfile pins Orca, including its CLI, to v1.4.219. Update that version declaration when testing a newer release. Base images and the universal developer image tag still follow moving releases, so builds are not fully reproducible.

Orca v1.4.219 needs [`web-client.patch`](web-client.patch) to serve its web client (`webClientRoot`) and to initialize the terminal graph, which a standalone server has no renderer to publish.

The published image targets `linux/amd64` and `linux/arm64`; `make build` builds `linux/amd64` only. The builder stage runs on the host architecture (`--platform=$BUILDPLATFORM`) and cross-compiles the `orcad` runtime, because esbuild fails under amd64 emulation on ARM machines.

`s390x` and `ppc64le` are not supported. The `orcad` runtime is a Bun-compiled binary and Bun publishes x64 and arm64 builds only, so the architecture cannot be built from this source regardless of base image availability.

The entrypoint restarts the server after two seconds if it exits. Exit code 78 is treated as a configuration error and is not retried.

## Repository layout

```
Containerfile                   multi-stage build: Orca runtime, web client, CLI
devfile.yaml                    injector and runtime components, preStart/postStart events
deploy.sh                       build, push, Route, template, workspace, pairing URL
teardown.sh                     remove workspace, template, Service, Route
entrypoint-init-container.sh    copies the runtime and CLI onto the /orca volume
entrypoint.sh                   persistent state, starts orcad on 6768
orca.sh                         Orca CLI launcher, installed as /orca/bin/orca
web-client.patch                upstream patch applied during the build
agent-workspaces.patch          upstream patch that wires in the agent environment provider
integration/                    new upstream source files: DevWorkspace provider and browser API
shared/                         deploy helpers, devfile renderer, runtime setup
config.env.example              documented local configuration
Makefile                        build, push, and admin registration targets
```

Changes to the editor components, commands, and events belong in `devfile.yaml`. Deployment and admin registration use the same renderer, which substitutes configuration values and preserves runtime variables such as `$PATH`.

For local changes, check Bash syntax and run ShellCheck before testing a deployment. Keep credentials and rendered devfiles out of commits.

## License

The integration code is licensed under [MIT](LICENSE). [Orca](https://github.com/stablyai/orca) keeps its own license. This integration applies a small patch to Orca and includes its [upstream license](https://github.com/stablyai/orca/blob/v1.4.219/LICENSE) in the runtime image. Preserve upstream license files and notices when redistributing images.
