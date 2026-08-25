# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- AWG 3.1 interface switches: `AWG_RANDOM_TRAILERS` and `AWG_DISABLE_COOKIES` (`on`/`off`), written into the `[Interface]` block of the server conf and every peer conf. Both are independent of each other and work with any `AWG_VERSION`
- `AWG_VERSION=3.1`, a preset for the 3.0 parameter set plus `RandomTrailers = on`. `DisableCookies` remains opt-in, since it gives up DoS mitigation and does not need to match between ends
- Startup warning when the 3.1 switches are requested against a pre-3.1 host kernel module, read from `/sys/module/amneziawg/version`, instead of failing later with `Line unrecognized` from `awg setconf`
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
