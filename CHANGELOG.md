# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.3] - 2026-01-06

### Fixed

- Fixed broken templating.

## [0.1.2] - 2025-12-29

### Added

- Add support for Kamaji.

## [0.1.1] - 2024-04-10

### Changed

- Ownership in Chart.yaml

### Fixed

- Build with ABS.

## [0.1.0] - 2024-03-26

### Added

- Add `allowEgressToDNS` policy disabled by default.
- Add `allowEgressToProxy` policy disabled by default.

### Removed

- Remove coredns `CiliumClusterwideNetworkPolicy`.

## [0.0.4] - 2024-02-13

- Changed: Disable coredns `CiliumClusterwideNetworkPolicy` by default.

## [0.0.3] - 2023-11-21

- Fixed: Minor fixes.

## [0.0.2] - 2023-11-21

- added: `CiliumClusterwideNetworkPolicy` for coredns

## [0.0.1] - 2023-11-02

- changed: `app.giantswarm.io` label group was changed to `application.giantswarm.io`

[Unreleased]: https://github.com/giantswarm/network-policies-app/compare/v0.1.3...HEAD
[0.1.3]: https://github.com/giantswarm/network-policies-app/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/giantswarm/network-policies-app/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/giantswarm/network-policies-app/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/giantswarm/network-policies-app/compare/v0.0.4...v0.1.0
[0.0.4]: https://github.com/giantswarm/network-policies-app/compare/v0.0.3...v0.0.4
[0.0.3]: https://github.com/giantswarm/network-policies-app/compare/v0.0.2...v0.0.3
[0.0.2]: https://github.com/giantswarm/network-policies-app/compare/v0.0.1...v0.0.2
[0.0.1]: https://github.com/giantswarm/network-policies-app/releases/tag/v0.0.1
