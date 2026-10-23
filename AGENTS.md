# AGENTS.md

Docker image for an AmneziaWG VPN, built on the LinuxServer.io Alpine base with s6-overlay. Two modes:

- **Server:** `PEERS` is set. The container generates keys, `wg0.conf`, peer configs and QR codes.
- **Client:** `PEERS` is unset. It brings up every `.conf` in `/config/wg_confs/`.

## Commands

```bash
bash tests/ipv6-lib.test.sh                          # unit tests for root/app/ipv6-lib.sh, no Docker needed
docker build -t test-image . && bash tests/smoke.sh  # the smoke test CI runs on PRs
shellcheck -x -S warning root/etc/s6-overlay/s6-rc.d/*/run root/app/*.sh tests/*.sh
```

To try a server by hand:

```bash
docker run -d --name awg-test --cap-add NET_ADMIN --device /dev/net/tun \
  -e PEERS=2 -e SERVERURL=test.example.com -v /tmp/awg-test:/config test-image
docker logs awg-test; docker exec awg-test /app/show-peer 1
docker rm -f awg-test && rm -rf /tmp/awg-test
```

Without `--device /dev/net/tun` the tunnel fails to start. That's expected when you're only checking config generation.

## Layout

- `Dockerfile`: three stages. They build `amneziawg-go`, build `awg` and `awg-quick`, and assemble the runtime. Upstream versions are pinned as `ARG` defaults at the top.
- `root/etc/s6-overlay/s6-rc.d/`: services, in this order:
  - `init-amneziawg-module`: kernel module or userspace fallback
  - `init-amneziawg-confs`: all config generation
  - `svc-amneziawg`: oneshot that brings the tunnels up
  - `svc-dnsmasq`: longrun DNS for peers
- `root/defaults/server.conf`, `peer.conf`: eval+heredoc templates, copied to `/config/templates/` for users to edit.
- `root/app/ipv6-lib.sh`: all IPv6 logic, unit-tested by `tests/ipv6-lib.test.sh`.
- `tests/smoke.sh`: image checks. It's a file because GitHub rejects a `run:` step over 21,000 characters.

Details:

- [docs/architecture.md](docs/architecture.md): services, `/config` layout, CI/CD, troubleshooting.
- [docs/development.md](docs/development.md): script patterns, AWG parameter rules, gotchas.
- [docs/awg-obfuscation.md](docs/awg-obfuscation.md): parameter constraints, tags, MTU.

## Rules that have broken before

Each has its full reasoning in [docs/development.md](docs/development.md). Read it before changing the area.

- **Loading saved values:** never `source` `/config/server/awg_params`, because it overrides Docker env vars. Read it with `grep`/`cut` and `${VAR:-fallback}`.
- **Empty env vars:** s6 drops them from the container environment, so `X=` arrives as *unset*. Don't give an empty value a meaning such as "clear this".
- **`AWG_VERSION`:** defaulted inside `generate_awg_params()`, not at the top of the script. Never compare it to string literals; use `awg_has_3x_params` / `awg_has_2x_features`.
- **`RandomTrailers` on:** `S1 == S2 == S3 == S4` must hold, or upload collapses to ~2 Mbit/s. Switch normalization runs before the S values are drawn.
- **I1–I5:**
  - They go in `[Interface]` of peer confs, not `[Peer]`.
  - Parse them with `cut -d= -f2-`.
  - Don't add a size check on `<r N>`.
- **IPv6 is opt-in:** an unset `IP6_SUBNET` must render byte-identical pre-IPv6 output, and nothing IPv6-related may fail `PostUp`.
- **Firewall policy:** it never goes into `root/defaults/*.conf` literally. Expand `${IP6_POSTUP}`/`${IP6_POSTDOWN}` instead.
- **Ports:** the container always listens on 51820, so a custom `SERVERPORT` is mapped as `SERVERPORT:51820/udp`.
- **`SYS_MODULE`:** nothing calls `modprobe`, so this capability doesn't enable the kernel datapath.

## Conventions

- **Shell scripts:**
  - s6 scripts start with `#!/usr/bin/with-contenv bash` and `# shellcheck shell=bash`, and must be executable.
  - `local` works only inside functions.
  - Use `lsiown` for ownership.
- **s6 wiring:** dependencies and registrations are empty files in `dependencies.d/` and `user/contents.d/`.
- **Indentation:** 4 spaces for shell and s6 files, 2 for the Dockerfile and YAML (`.editorconfig`).
- **New env var:** use the `add-env-var` skill. Every user-facing variable goes in `README.md` and `docker-compose.yml`.
- **Commits:** conventional commits (`feat:`, `fix:`, `docs:`, `chore:`; `!` for breaking). Branches are `feature/<name>`. Add user-visible changes to `CHANGELOG.md` under Unreleased.
- **Pull requests:** fill in `.github/pull_request_template.md`, and state what was tested on a real host and what wasn't.

## Security

- Peer private keys and preshared keys live in `/config`. Never print them in logs, docs or PR text beyond the existing QR/peer-conf output.
- dnsmasq runs as the `dnsmasq` user with only `CAP_NET_BIND_SERVICE`. In server mode it listens on wg0 only. Keep it that way.

## Skills

Skills live in `.agents/skills/` (Agent Skills format). `.claude/skills` and `.agent/skills` are symlinks to it.

- `add-env-var`: add or change an environment variable.
- `amneziawg-config`: generate or validate AWG configs and parameters.
- `deploy-amneziawg`: deploy the container to a Linux host.
