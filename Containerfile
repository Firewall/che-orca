# Build a self-contained Orca bundle on UBI 9. The injector copies it onto the /orca volume,
# where it runs inside UBI 9 based workspace images such as the universal developer image.

# Orca's headless browser pages need an X display, and UBI ships no X server.
FROM registry.access.redhat.com/ubi9/ubi:latest AS xvfb

USER 0

RUN dnf install -y --disablerepo='*' --enablerepo='ubi-9-*' --setopt=install_weak_deps=False \
      gcc make meson ninja-build pkgconf-pkg-config diffutils xz \
      xorg-x11-proto-devel libX11-devel libXau-devel freetype-devel openssl-devel zlib-devel \
      xkeyboard-config && \
    dnf clean all

COPY build/build-xvfb.sh /tmp/build-xvfb.sh
RUN /tmp/build-xvfb.sh /orca/runtime

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

# Orca's official desktop build, which runs headless and hosts browser pages for agents, with
# the UBI libraries it loads.
FROM registry.access.redhat.com/ubi9/ubi:latest AS bundle

USER 0

RUN dnf install -y --disablerepo='*' --enablerepo='ubi-9-*' --setopt=install_weak_deps=False \
      cpio gtk3 nss alsa-lib mesa-libgbm libX11-xcb && \
    dnf clean all

ARG ORCA_VERSION=1.4.219
ARG TARGETARCH
RUN case "$TARGETARCH" in \
      amd64) ORCA_ARCH=x86_64; ORCA_SHA256=9c2875886075812a35c966915546719eef75ba375b9688ade4c1cf7ff6aea983 ;; \
      arm64) ORCA_ARCH=aarch64; ORCA_SHA256=d8e9a6d7cd766c2fb764a919bd19ee93923b0910532f859bdb8b555f27994f4a ;; \
      *) echo "Orca publishes no Linux build for architecture: $TARGETARCH" >&2; exit 1 ;; \
    esac && \
    curl -fsSL -o /tmp/orca-ide.rpm \
      "https://github.com/stablyai/orca/releases/download/v${ORCA_VERSION}/orca-ide-${ORCA_VERSION}.${ORCA_ARCH}.rpm" && \
    echo "${ORCA_SHA256}  /tmp/orca-ide.rpm" | sha256sum -c - && \
    mkdir -p /tmp/orca-rpm /orca && cd /tmp/orca-rpm && rpm2cpio /tmp/orca-ide.rpm | cpio -idm --quiet && \
    mv /tmp/orca-rpm/opt/Orca /orca/app && \
    rm -rf /tmp/orca-rpm /tmp/orca-ide.rpm && \
    curl -fsSL -o /orca/LICENSE "https://raw.githubusercontent.com/stablyai/orca/v${ORCA_VERSION}/LICENSE" && \
    echo "ff1b611f80580d49f4b97e93a97b24eb050b0671b26b8afe16341fab699112f3  /orca/LICENSE" | sha256sum -c -

# The release build lists Orca's agent skills, with checksums, but does not ship them. Fetch them
# from the release tag so agents get the skills without network access at run time.
COPY build/fetch-skills.py /tmp/build/fetch-skills.py
RUN python3 -I /tmp/build/fetch-skills.py /orca/app/resources/skills/current-manifest.json \
      "$ORCA_VERSION" /orca/skills

COPY --from=xvfb /orca/runtime /orca/runtime
COPY --from=patchelf /usr/local/bin/patchelf /usr/local/bin/patchelf
COPY build/bundle-libraries.sh build/set-rpath.sh /tmp/build/

# Chromium loads libX11-xcb with dlopen(), and NSS loads its crypto module and p11-kit's trust
# module the same way, so name them explicitly. Chromium's other dlopen() probes are optional.
RUN /tmp/build/bundle-libraries.sh /orca/runtime/lib /orca/runtime/share/licenses \
      /orca/app /orca/runtime/bin /orca/runtime/lib \
      /usr/lib64/libX11-xcb.so.1 /usr/lib64/libsoftokn3.so /usr/lib64/libfreeblpriv3.so \
      /usr/lib64/libnssckbi.so && \
    /tmp/build/set-rpath.sh /orca/runtime/lib /orca/app/orca-ide && \
    mkdir -p /orca/bin && \
    ln -s ../app/resources/bin/orca-ide /orca/bin/orca && \
    ln -s ../app/resources/bin/orca-ide /orca/bin/orca-ide && \
    ln -s ../runtime/bin/Xvfb /orca/bin/Xvfb

# Prove that the bundle needs nothing from the image it runs in.
FROM registry.access.redhat.com/ubi9/ubi-minimal:latest AS verify

COPY --from=bundle /orca /orca
COPY build/verify-bundle.sh /tmp/verify-bundle.sh
RUN /tmp/verify-bundle.sh /orca

FROM registry.access.redhat.com/ubi9/ubi-minimal:latest

COPY --from=verify /orca /opt/orca
COPY shared/runtime.sh /usr/local/bin/shared-runtime.sh
COPY shared/bashrc.sh /usr/local/bin/shared-bashrc.sh
COPY entrypoint.sh /usr/local/bin/orca-entrypoint.sh
COPY entrypoint-init-container.sh /entrypoint-init-container.sh

USER 1001

# Idle like the universal developer image. When orca-runtime runs as its own
# container, the postStart command starts /orca/entrypoint.sh.
CMD ["tail", "-f", "/dev/null"]
