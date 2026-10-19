# Run build tools on the host architecture to avoid amd64 emulation failures.
FROM --platform=$BUILDPLATFORM registry.access.redhat.com/ubi9/nodejs-24 AS builder

USER 0

RUN dnf install -y --disablerepo='*' --enablerepo='ubi-*' patch unzip && \
    dnf clean all && \
    npm install -g pnpm@12.0.0

# Pin the source so the standalone runtime and web client use the same protocol.
ENV ORCA_VERSION=1.4.219
WORKDIR /src/orca
RUN curl -fsSL "https://github.com/stablyai/orca/archive/refs/tags/v${ORCA_VERSION}.tar.gz" \
      | tar -xz --strip-components=1

# Wire in the web root and initialize the standalone terminal graph.
COPY web-client.patch /tmp/web-client.patch
RUN patch -p1 < /tmp/web-client.patch

# Keep snapshot refs valid across orcad's browser commands.
COPY orcad-browser-refs.patch /tmp/orcad-browser-refs.patch
RUN patch -p1 < /tmp/orcad-browser-refs.patch

# Stream orcad's Chromium pages to the web client's browser pane.
COPY orcad-browser-screencast.patch /tmp/orcad-browser-screencast.patch
RUN patch -p1 < /tmp/orcad-browser-screencast.patch

# Build the standalone runtime without downloading or rebuilding Electron.
RUN NODE_ENV=development pnpm install --frozen-lockfile --ignore-scripts && \
    pnpm rebuild esbuild

# orcad drives an external Chromium through the agent-browser binary that its build ships next to
# orcad.js and hashes into its version. Orca pins 0.27, which reports clicks on elements below the
# fold as done without scrolling to them, so swap in a newer binary before the build.
ARG AGENT_BROWSER_VERSION=0.39.1
ARG TARGETARCH
RUN case "$TARGETARCH" in \
      amd64) ORCAD_ARCH=x64 ;; \
      arm64) ORCAD_ARCH=arm64 ;; \
      *) echo "Unsupported Orca architecture: $TARGETARCH" >&2; exit 1 ;; \
    esac && \
    curl -fsSL -o /tmp/agent-browser.tgz \
      "https://registry.npmjs.org/agent-browser/-/agent-browser-${AGENT_BROWSER_VERSION}.tgz" && \
    echo "9efb4de1a5406f1b32dfcca2890e272053caace3369b6294d47240384e0a4732  /tmp/agent-browser.tgz" | sha256sum -c - && \
    tar -xzf /tmp/agent-browser.tgz -C /tmp "package/bin/agent-browser-linux-${ORCAD_ARCH}" && \
    install -m 755 "/tmp/package/bin/agent-browser-linux-${ORCAD_ARCH}" \
      "$(readlink -f node_modules/agent-browser)/bin/agent-browser-linux-${ORCAD_ARCH}" && \
    rm -rf /tmp/agent-browser.tgz /tmp/package

# Run scripts directly so pnpm does not reinstall skipped Electron dependencies.
RUN case "$TARGETARCH" in \
      amd64) ORCAD_ARCH=x64 ;; \
      arm64) ORCAD_ARCH=arm64 ;; \
      *) echo "Unsupported Orca architecture: $TARGETARCH" >&2; exit 1 ;; \
    esac && \
    node config/scripts/build-orcad-bun.mjs --target "linux-${ORCAD_ARCH}-glibc" && \
    node --run build:web

# Package the CLI with the runtime dependencies upstream ships beside its desktop CLI,
# so orcad's Bun runtime can run it.
RUN case "$TARGETARCH" in \
      amd64) ORCAD_ARCH=x64 ;; \
      arm64) ORCAD_ARCH=arm64 ;; \
    esac && \
    node node_modules/typescript/bin/tsc -p config/tsconfig.cli.json --outDir out --composite false --incremental false && \
    node config/scripts/verify-cli-bin.mjs --fix-executable --fix-package-json && \
    mkdir -p /opt/orca-cli && \
    cp -r out/cli out/main out/shared out/package.json /opt/orca-cli/ && \
    node -e ' \
      const { cpSync } = require("node:fs"); \
      const { join } = require("node:path"); \
      const runtime = require("./config/packaged-runtime-node-modules.cjs"); \
      for (const { from, to } of runtime.createPackagedRuntimeNodeModuleResources("linux")) \
        cpSync(from, join("/opt/orca-cli", to), { recursive: true, dereference: true }); \
      runtime.prunePackagedRuntimeNodeModules("/opt/orca-cli", "linux", process.argv[1]); \
    ' "$ORCAD_ARCH"

# patchelf is not packaged in UBI.
FROM registry.access.redhat.com/ubi9/ubi:latest AS patchelf

USER 0

RUN dnf install -y --disablerepo='*' --enablerepo='ubi-9-*' gcc-c++ make && \
    dnf clean all && \
    curl -fsSL -o /tmp/patchelf.tar.gz \
      https://github.com/NixOS/patchelf/releases/download/0.19.2/patchelf-0.19.2.tar.gz && \
    echo "78cb26bda2b89fababfe189c2f6507240340f1aa45dec2eb49a39473a50ceea1  /tmp/patchelf.tar.gz" | sha256sum -c - && \
    tar -xzf /tmp/patchelf.tar.gz -C /tmp && \
    cd /tmp/patchelf-0.19.2 && ./configure --prefix=/usr/local && make -j"$(nproc)" && make install

# Chrome's headless shell for orcad's browser, with the UBI libraries it loads. It needs no
# X server. Chrome for Testing publishes it for x86_64 Linux only.
FROM registry.access.redhat.com/ubi9/ubi:latest AS chromium

USER 0

RUN dnf install -y --disablerepo='*' --enablerepo='ubi-9-*' --setopt=install_weak_deps=False \
      unzip nss nspr atk at-spi2-atk at-spi2-core libXcomposite libXdamage libXfixes libXrandr \
      mesa-libgbm libxkbcommon alsa-lib && \
    dnf clean all

ARG CHROME_VERSION=155.0.8059.84
ARG TARGETARCH
RUN [ "$TARGETARCH" = amd64 ] || { echo "No headless Chrome build for $TARGETARCH" >&2; exit 1; } && \
    curl -fsSL -o /tmp/chrome.zip \
      "https://storage.googleapis.com/chrome-for-testing-public/${CHROME_VERSION}/linux64/chrome-headless-shell-linux64.zip" && \
    echo "a5d71b91aa996fef00517cd212b2dfb816b43055edefbe727e6fd562d4ae1f9c  /tmp/chrome.zip" | sha256sum -c - && \
    unzip -q /tmp/chrome.zip -d /tmp && \
    mkdir -p /orca/chromium && mv /tmp/chrome-headless-shell-linux64 /orca/chromium/app && \
    rm /tmp/chrome.zip

COPY --from=patchelf /usr/local/bin/patchelf /usr/local/bin/patchelf
COPY build/bundle-libraries.sh build/set-rpath.sh /tmp/build/

# NSS loads its crypto module and p11-kit's trust module with dlopen(), so name them explicitly.
RUN /tmp/build/bundle-libraries.sh /orca/chromium/lib /orca/chromium/licenses /orca/chromium/app \
      /usr/lib64/libsoftokn3.so /usr/lib64/libfreeblpriv3.so /usr/lib64/libnssckbi.so && \
    /tmp/build/set-rpath.sh /orca/chromium/lib /orca/chromium/app/chrome-headless-shell

FROM registry.access.redhat.com/ubi9/nodejs-22

USER 0

RUN dnf upgrade -y --disablerepo='*' --enablerepo='ubi-*' && \
    dnf install -y --disablerepo='*' --enablerepo='ubi-*' git && \
    dnf clean all

COPY --from=builder /src/orca/out/orcad /opt/orca/runtime
COPY --from=builder /src/orca/out/web /opt/orca/web
COPY --from=builder /src/orca/LICENSE /opt/orca/LICENSE
COPY --from=builder /opt/orca-cli /opt/orca/cli
COPY --from=builder /src/orca/skills /opt/orca/skills
COPY orca.sh /opt/orca/bin/orca
COPY --from=chromium /orca/chromium /opt/orca/chromium
COPY chromium.sh /opt/orca/chromium/chromium
COPY shared/runtime.sh /usr/local/bin/shared-runtime.sh
COPY shared/bashrc.sh /usr/local/bin/shared-bashrc.sh
COPY entrypoint.sh /usr/local/bin/orca-entrypoint.sh
COPY pairing-page.js /usr/local/bin/orca-pairing-page.js
COPY entrypoint-init-container.sh /entrypoint-init-container.sh

# Orca's skills tell agents to run orca-ide outside Orca's terminals. orcad does not
# install that name, so point it at the same launcher.
RUN ln -s orca /opt/orca/bin/orca-ide && \
    chgrp -R 0 /opt/app-root /opt/orca && \
    chmod -R g=u /opt/app-root /opt/orca && \
    chmod g=u /etc/passwd

USER 1001

# Idle like the universal developer image. When orca-runtime runs as its own
# container, the postStart command starts /orca/entrypoint.sh.
CMD ["tail", "-f", "/dev/null"]
