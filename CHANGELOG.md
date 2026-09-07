# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- `docker-build.yml` now gates the multi-arch build and release behind a `changes` job that diffs the push: only `Dockerfile`, `root/**`, `.dockerignore` and the workflow itself are image content, so docs/skills/compose-only merges to master no longer rebuild and republish `:latest`. Tag pushes, `workflow_dispatch` and diffs with no reachable base always build. Implemented as an explicit `git diff` gate rather than an `on.push.paths` filter, which shares the push block with the `v*` tag trigger and is ambiguous for tag pushes
- `docs/awg-performance.md`: measured throughput and latency cost of every obfuscation parameter, traced to upstream kernel-module and `amneziawg-go` source, with reproduction steps
- `README.md` "Speed and latency" section, and data-path cost notes in `CONTEXT.md` and both skill references
- `scripts/gen-awg-params.sh` (deploy skill) now enforces the performance constraints as well as the protocol ones: `S1 == S2 == S3 == S4` when `RandomTrailers` is on with AWG 2.0+ H ranges, `S4 <= 20` so the default 1420 MTU does not fragment, and `AWG_CONTENT_PADDING=0` unless `--content-padding on` is passed. It refuses `--content-padding on` together with `--random-trailers on`
- AWG 3.1 interface switches: `AWG_RANDOM_TRAILERS` and `AWG_DISABLE_COOKIES` (`on`/`off`), written into the `[Interface]` block of the server conf and every peer conf. Both are independent of each other and work with any `AWG_VERSION`
- `AWG_VERSION=3.1`, a preset for the 3.0 parameter set plus `RandomTrailers = on`. `DisableCookies` remains opt-in, since it gives up DoS mitigation and does not need to match between ends
- Startup warning when the 3.1 switches are requested against a pre-3.1 host kernel module, read from `/sys/module/amneziawg/version`, instead of failing later with `Unable to modify interface: Invalid argument`
- AWG 3.0 protocol support (`AWG_VERSION=3.0`): HeaderProtectionKey, ContentPaddingAddition and randomized protocol timers (RekeyAfterTime, RekeyTimeout, RejectAfterTime, KeepaliveTimeout, MaxHandshakeAttempts), auto-generated with env overrides
- Initial Docker container for AmneziaWG
- Multi-stage Docker build with Go compilation
- Pre-compiled AmneziaWG tools integration
- Docker Compose configuration
- Graceful shutdown handling
- Example configuration files
- Comprehensive documentation
- GitHub Actions CI/CD pipeline
- Multi-architecture support (amd64, arm64)

### Changed
- amneziawg-tools updated to v3.0.20260730, the first release with AWG 3.0 config parsing
- Updated to use GitHub Packages for pre-built images

### Fixed
- Documentation no longer tells you to check the module version string for the random-trailer fix. `docs/awg-performance.md`, `README.md`, `CONTEXT.md`, `CLAUDE.md` and both skill references said to run "module v3.1.20260906 or newer", but upstream did not bump `version.h` in `4569c4c6` — a patched module still reports `3.1.20260812`, so that check can never pass and would have sent readers chasing an upgrade they already have. They now identify the fix by package version (`…+4569c4c…`) or the `bool trailer` parameter in `socket.c`, with a new section on confirming the loaded module matches the built one via `srcversion`. `check_awg31_kernel_support()` is unaffected: it only reads the `3.1` major/minor, which upstream does maintain
- Generated peer configs are loadable by `awg-quick` again. `append_awg_signatures_to_interface()` wrote `I2`-`I5` as empty placeholders (`I2 =`) for AWG 2.0+, on the theory that their presence signalled the protocol version to the Amnezia app. `awg` rejects an empty value outright — ``Line unrecognized: `I2='`` — so every peer conf failed to load under `awg-quick`, `awg setconf`, and this image in client mode; only GUI clients with a more forgiving parser worked. Empty values are now skipped, matching the server-side `append_awg_signatures()`. App version detection is unaffected: it keys off the H1-H4 range format, which is emitted independently
- `AWG_VERSION=3.1` configs are no longer slow. `generate_awg_params()` drew `AWG_S1`-`AWG_S4` independently while defaulting `AWG_RANDOM_TRAILERS=on`, and `RandomTrailers` relaxes the receiver's packet-type check to a length lower bound — so unequal `S` values had roughly 3.5% of transport packets misclassified as handshakes and dropped. Measured upload fell from ~100 to ~2 Mbit/s while download barely moved. One value is now drawn for all four when trailers resolve to `on` under AWG 2.0+, and an explicitly pinned unequal set produces a startup warning
- `AWG_CONTENT_PADDING` now defaults to `0` when `RandomTrailers` is on, instead of always generating a range. Content padding takes precedence on the send path and suppresses the trailers, while the receive path still relaxes its matching — the risk of trailers with none of the obfuscation, plus roughly 22% of download throughput lost to defeated `UDP_GRO` batching. Pinning both now warns
- `AWG_S4` is generated in 4-20 (2.0) / 12-20 (3.x) rather than up to 27. Per-packet overhead is `60 + S4`, and `awg-quick` derives a 1420 tunnel MTU without accounting for `S4`, so values above 20 fragmented every full-size packet on a 1500-byte path
- Existing installs are unaffected by all three: `load_awg_params` runs before `generate_awg_params`, so saved parameters still win and no peer config is invalidated. Deployments created before this release keep their old values — check `/config/server/awg_params` if you run 3.1
- `amneziawg-config` skill, from code review: `awg-genconf.sh` now requires `--endpoint HOST:PORT` and rejects a bare host or unbracketed IPv6 (a bare IPv6 previously yielded `ListenPort = 1` from its last hextet), bounds `--peers` at the 253 a `/24` holds, rejects `--content-padding` on non-3.x instead of silently dropping it, reports a missing flag value as an error rather than an unbound-variable crash, and emits NAT/forwarding rules via `--nat-iface` (commented, with a warning, when not given) so a full-tunnel config does not blackhole after handshaking. `awg-lint.py` now treats a shared key present in one config and absent from another as a mismatch — previously a peer that had lost its obfuscation block entirely passed clean — and no longer claims a config fragments when it does not
- `AWG_VERSION` is now restored from `/config/server/awg_params` when the environment variable is absent. It was defaulted to `2.0` before the saved value was read, so recreating a container from a compose file that no longer set it silently regenerated every peer config as 2.0 and broke already-distributed peers
- `/config/server/awg_params` was never written on a fresh install (the directory did not exist yet), so every container restart regenerated all AWG obfuscation parameters and invalidated previously distributed peer configs

### Security
- Implemented security best practices in container design
- Added security policy and guidelines

## [1.0.0] - 2025-08-13

### Added
- First stable release
- Complete Docker containerization of AmneziaWG
- Support for latest AmneziaWG-go implementation
- Integration with AmneziaWG tools v1.0.20250706
- Multi-architecture Docker images
- Comprehensive documentation and examples

---

## Release Notes Format

### Added
- New features

### Changed
- Changes in existing functionality

### Deprecated
- Soon-to-be removed features

### Removed
- Now removed features

### Fixed
- Bug fixes

### Security
- Security improvements
