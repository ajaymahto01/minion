# Testbed: an SSH-able all-in-one test container

An Ubuntu 24.04 image that behaves like a small VM: it starts `sshd`, you log in
as `minion` (password `minion`, passwordless sudo), and the usual testing tools are already there.
Nothing is downloaded at runtime, so it works in an air-gapped network.

## 1. Build (on a machine with internet access)

```bash
docker build -t minion:1.0 -t minion:latest .
```

Useful build args:

| Arg | Default | Purpose |
|---|---|---|
| `BASE_IMAGE` | `ubuntu:24.04` | Point at your internal registry mirror |
| `USERNAME` / `USER_UID` | `minion` / `1000` | Login user |
| `KUBECTL_VERSION`, `HELM_VERSION`, `YQ_VERSION`, `GRPCURL_VERSION` | see Dockerfile | Match your cluster/tooling versions |
| `GO_VERSION` / `GO_SHA256` | `1.27.4` / empty | Go toolchain version; set the checksum from go.dev/dl to verify the download |

For a different CPU architecture than the build machine, add e.g. `--platform linux/amd64`.

## 2. Carry it into the air-gap

```bash
# connected side
docker save minion:1.0 | gzip > minion-1.0.tar.gz
sha256sum minion-1.0.tar.gz > minion-1.0.tar.gz.sha256

# air-gapped side
sha256sum -c minion-1.0.tar.gz.sha256
docker load < minion-1.0.tar.gz
# optional: push to the internal registry
docker tag minion:1.0 registry.internal/platform/minion:1.0
docker push registry.internal/platform/minion:1.0
```

## 3. Run

```bash
docker run -d --name testbed --hostname testbed \
  -p 2222:22 \
  --cap-add NET_ADMIN --cap-add NET_RAW --cap-add SYS_PTRACE \
  -v testbed-hostkeys:/etc/ssh/hostkeys \
  -v testbed-home:/home/minion \
  minion:1.0

ssh -p 2222 minion@<docker-host>      # password: minion
```

Or edit `compose.yaml` and run `docker compose up -d` (it also works with
`docker compose up -d --no-build` once the image is loaded).

### Login options

| You provide | Result |
|---|---|
| Nothing | Password login as `minion` / `minion` |
| `-e SSH_PASSWORD=<other>` | Password login with your own password |
| `SSH_AUTHORIZED_KEYS` env or a file mounted at `/authorized_keys` | Key login, in addition to the password |
| A key plus `-e SSH_PASSWORD=""` | Key-only login |
| `-e SSH_PASSWORD=""` and no key | A random password is generated; read it with `docker logs testbed` |

Root login over SSH is disabled; use `sudo`.

## What's inside

| Area | Tools |
|---|---|
| Network | curl, wget, openssl, dig/nslookup, ping, traceroute, mtr, nc, socat, telnet, tcpdump, ngrep, nmap, iperf3, ip/ss, ethtool, iptables, conntrack |
| System | htop, sysstat (iostat, sar, pidstat), iotop, strace, ltrace, lsof, tmux, screen |
| Load / stress | ab, wrk, stress-ng, fio |
| Clients | psql, mariadb/mysql, redis-cli, kcat (Kafka), grpcurl |
| Kubernetes | kubectl, helm |
| Scripting | bash, python3 (+ pip, venv, requests, yaml), jq, yq, git, make |
| Go | go, gofmt (in `/usr/local/go`), gcc for cgo |

## Go in the air-gap

The toolchain works offline, but `go build` cannot fetch modules from the internet.
Pick one:

- **Internal module proxy** (Artifactory, Nexus, Athens):
  `go env -w GOPROXY=https://<your-proxy> GOSUMDB=off` (or point `GOSUMDB` at your own).
- **Vendored code**: run `go mod vendor` on the connected side and copy the repo in;
  Go uses `vendor/` automatically.
- **Pre-filled module cache**: run `go mod download` on the connected side, copy
  `~/go/pkg/mod` into the container, then `go env -w GOPROXY=off GOFLAGS=-mod=mod`.

`GOTOOLCHAIN=local` is set in `/usr/local/go/go.env`, so a `go.mod` asking for a
newer Go fails with a clear error instead of trying to download a toolchain.
`go env -w` settings live in the home volume and survive container recreation.

## Notes

- **Not a real VM.** There is no systemd, so `systemctl` does not work, and the
  kernel is the host's. Start extra daemons directly or run them as separate containers.
- **Docker env vars are not visible in SSH sessions.** sshd starts a clean login
  environment. Put variables in `~/.bashrc` or `/etc/environment`.
- **Persistence.** Only the two volumes survive `docker rm`. Packages installed
  by hand are lost on recreation; add them to the Dockerfile and rebuild instead.
- **Capabilities.** Drop the `--cap-add` flags if you only need application-level
  testing. Without them, tcpdump, `tc`, iptables and strace will not work.
- **Adding tools.** Extend the `apt-get install` list, or add a download to the
  `tools` stage, then rebuild and re-export. If you have an internal apt mirror,
  you can also rebuild inside the air-gap by pointing `BASE_IMAGE` and the apt
  sources at it and removing the `tools` stage.
