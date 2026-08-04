# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
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
