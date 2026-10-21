# Changelog

## [Unreleased]

### Security

- Rebuild and validate the generated PEM bundle against current macOS Keychain
  root trust, certificate validity, CA constraints, self-signatures, duplicate
  certificates, and the local exclusion policy before publication.
- Add an SPKI-based CA exclusion policy for the incident-affected emSign G3 TLS,
  code-signing, and cross-signing trust anchors.
- Make the PEM checker explain every removal and require confirmation when run
  directly, while allowing the bundle builder to clean its candidate safely.

### Changed

- Validate PEM files referenced by existing shell trust variables instead of
  skipping them, and report each unique referenced PEM only once.
- Accept an existing non-Homebrew Alpaca installation, verify its listener and
  launchd registration, and skip unsupported Homebrew service management.
- Display static HTTP/HTTPS proxy endpoints with their ports and PAC settings
  clearly for each macOS network service.

### Fixed

- Correctly unset uppercase and lowercase proxy variables and force direct curl
  probes to bypass environment and curl-config proxies.
- Remove the unused audio playback call and sound-related traps from the main
  script.
- Restore the `--proxy_uninstall` command-line switch and correct proxy-variable
  setup and retry handling.


## [1.7.5] - 2026-03-14

### Chore/Other
- ci: grant contents:write for release



## [1.7.4] - 2026-03-14

### Chore/Other
- chore: update



## [1.7.3] - 2026-03-14

### Chore/Other
- chore: update



## [1.7.2] - 2026-03-14

### Chore/Other
- chore: update



## [1.7.1] - 2026-03-14

### Chore/Other
- chore: update
- chore: add release automation
- chore: update
- chore: update
- chore: update
- chore: update
- chore: update
- chore: update
- chore: update
- chore: update
- chore: update
- chore: update
- chore: update
- chore: update
- chore: update
- chore: update
- chore: update
- chore: update
- chore: update
- chore: update
- chore: update
- chore: update
- chore: latest feature updates
- chore: latest feature updates
- chore: latest feature updates
- chore: latest feature updates
- chore: latest feature updates
- chore: update
- chore: update
- chore: update
- chore: update
- chore: update
- chore: update
- chore: update
- chore: update
- chore: update
- chore: update
- chore: update
- chore: update
- chore: update
- chore: update
- chore: update
- chore: update
- chore: update
- chore: update
- chore: update
- chore: update
- chore: update
- chore: update
- chore: update
- chore: update
- chore: Syntax & Logging improvement +  addition of Intermediate CAs scanning
- chore: Syntax & Logging improvement +  addition of Intermediate CAs scanning
- chore: update
- chore: update
- chore: update
- chore: update
- chore: update
- chore: update
- chore: update
- chore: update
- chore: Update
- chore: first commit
- chore: Add .gitignore file
- chore: Add files via upload


All notable changes to this project will be documented in this file.

## [1.7.0] - 2025-03-30

### Chore/Other
- chore: initial formalized version and changelog
