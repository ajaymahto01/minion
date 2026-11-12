# All-in-one SSH-able testbed image.
# Build on a connected machine, then `docker save` and carry it into the air-gap.

ARG BASE_IMAGE=ubuntu:24.04

# ---------------------------------------------------------------------------
# Stage 1: fetch standalone binaries that are not in the Ubuntu repos.
# Versions are build args so you can bump them without editing the file.
# Delete this stage (and the COPY --from=tools line below) if you don't need them.
# ---------------------------------------------------------------------------
FROM ${BASE_IMAGE} AS tools

ARG KUBECTL_VERSION=1.31.4
ARG HELM_VERSION=3.16.4
ARG YQ_VERSION=4.44.6
ARG GRPCURL_VERSION=1.9.2
ARG GO_VERSION=1.27.4
# Optional: set to the checksum published on https://go.dev/dl/ to verify the Go tarball.
ARG GO_SHA256=""

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in amd64) garch=x86_64 ;; arm64) garch=arm64 ;; *) echo "unsupported arch: $arch"; exit 1 ;; esac; \
    mkdir -p /out /tmp/dl; \
    # kubectl (checksum verified)
    curl -fsSLo /out/kubectl "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/${arch}/kubectl"; \
    curl -fsSLo /tmp/dl/kubectl.sha256 "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/${arch}/kubectl.sha256"; \
    echo "$(cat /tmp/dl/kubectl.sha256)  /out/kubectl" | sha256sum -c -; \
    # helm
    curl -fsSL "https://get.helm.sh/helm-v${HELM_VERSION}-linux-${arch}.tar.gz" | tar -xz -C /tmp/dl; \
    mv "/tmp/dl/linux-${arch}/helm" /out/helm; \
    # yq
    curl -fsSLo /out/yq "https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_${arch}"; \
    # grpcurl
    curl -fsSL "https://github.com/fullstorydev/grpcurl/releases/download/v${GRPCURL_VERSION}/grpcurl_${GRPCURL_VERSION}_linux_${garch}.tar.gz" \
      | tar -xz -C /out grpcurl; \
    chmod 0755 /out/*; \
    # Go toolchain (kept outside /out; copied to /usr/local/go in the final stage)
    curl -fsSLo /tmp/dl/go.tgz "https://go.dev/dl/go${GO_VERSION}.linux-${arch}.tar.gz"; \
    if [ -n "${GO_SHA256}" ]; then echo "${GO_SHA256}  /tmp/dl/go.tgz" | sha256sum -c -; fi; \
    tar -xzf /tmp/dl/go.tgz -C /opt; \
    # Air-gap default: never try to download a newer toolchain from the internet
    sed -i 's/^GOTOOLCHAIN=.*/GOTOOLCHAIN=local/' /opt/go/go.env; \
    grep -q '^GOTOOLCHAIN=local$' /opt/go/go.env; \
    rm -rf /tmp/dl

# ---------------------------------------------------------------------------
# Stage 2: the testbed itself.
# ---------------------------------------------------------------------------
FROM ${BASE_IMAGE}

ARG USERNAME=minion
ARG USER_UID=1000

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    TZ=Asia/Kolkata \
    TESTBED_USER=${USERNAME}

# Default SSH password. Override with -e SSH_PASSWORD=..., or set it empty for key-only login.
ENV SSH_PASSWORD=minion

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      # --- base / VM feel ---
      openssh-server sudo tini ca-certificates tzdata bash-completion \
      vim nano less tmux screen file tree rsync zip unzip xz-utils \
      git make jq \
      # --- network ---
      curl wget openssl iproute2 iputils-ping dnsutils net-tools \
      netcat-openbsd socat telnet traceroute mtr-tiny tcpdump ngrep nmap \
      iperf3 ethtool iptables conntrack \
      # --- system / debugging ---
      procps psmisc htop sysstat iotop strace ltrace lsof \
      # --- load / stress ---
      apache2-utils wrk stress-ng fio \
      # --- data-store and messaging clients ---
      postgresql-client mariadb-client redis-tools kcat \
      # --- scripting ---
      python3 python3-pip python3-venv python3-requests python3-yaml \
      # --- C toolchain for cgo ---
      gcc libc6-dev \
 && ln -snf "/usr/share/zoneinfo/${TZ}" /etc/localtime && echo "${TZ}" > /etc/timezone \
 && rm -rf /var/lib/apt/lists/* \
 # host keys are generated on first start, never baked into the image
 && rm -f /etc/ssh/ssh_host_* \
 && mkdir -p /run/sshd /etc/ssh/hostkeys

COPY --from=tools /out/ /usr/local/bin/

# Go: symlinks make it work in non-interactive SSH commands too; profile.d adds ~/go/bin.
COPY --from=tools /opt/go /usr/local/go
RUN ln -s /usr/local/go/bin/go /usr/local/go/bin/gofmt /usr/local/bin/ \
 && echo 'export PATH="$PATH:/usr/local/go/bin:$HOME/go/bin"' > /etc/profile.d/go.sh

# Login user with passwordless sudo (ubuntu:24.04 ships a uid-1000 "ubuntu" user; replace it).
RUN (userdel -r ubuntu 2>/dev/null || true) \
 && useradd -m -s /bin/bash -u "${USER_UID}" "${USERNAME}" \
 && usermod -p '*' "${USERNAME}" \
 && echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/90-${USERNAME}" \
 && chmod 0440 "/etc/sudoers.d/90-${USERNAME}" \
 && install -d -m 0700 -o "${USERNAME}" -g "${USERNAME}" "/home/${USERNAME}/.ssh"

# Static sshd settings; auth mode is written by the entrypoint at start.
RUN printf '%s\n' \
      'Port 22' \
      'PermitRootLogin no' \
      'HostKey /etc/ssh/hostkeys/ssh_host_ed25519_key' \
      'HostKey /etc/ssh/hostkeys/ssh_host_rsa_key' \
      'X11Forwarding no' \
      'ClientAliveInterval 60' \
      'ClientAliveCountMax 5' \
      > /etc/ssh/sshd_config.d/00-testbed.conf

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh

EXPOSE 22
VOLUME ["/etc/ssh/hostkeys"]

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
CMD ["/usr/sbin/sshd", "-D", "-e"]
