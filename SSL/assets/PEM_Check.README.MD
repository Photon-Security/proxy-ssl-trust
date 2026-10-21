# PEM_Check.sh

## Description

`PEM_Check.sh` validates a PEM root CA bundle and identifies certificates that
should not remain trusted. It checks certificate parsing, validity dates, root
and signing-CA constraints, self-signatures, duplicates, macOS trust, and the
repository's explicit CA exclusion policy.

Every retained certificate must be trusted as a root CA by the current macOS
Keychain settings and must not match the explicit exclusion policy. A missing
or unreadable exclusion policy causes validation to fail closed.

When run directly, the script lists each certificate and its removal reason,
then requires confirmation before changing the file. When sourced by the bundle
builder, remediation is automatic. The original file is not changed when its
PEM boundaries are malformed or when cleanup would leave an empty trust store.

## Requirements

- macOS with Zsh
- OpenSSL
- The bundled logging helpers in `lib/`

## Usage

```zsh
./SSL/PEM_Check.sh [OPTIONS] [PEM_FILE]

Options:
  --cafile, -c, -f PATH       PEM bundle to inspect
  --exclusions PATH           Alternative CA exclusion policy
  --audit                     Report issues without changing the file
  --verbose, -v               List retained certificate subjects
  --quiet, -q                 Suppress progress and success messages
  --help, -h                  Show help
```

Examples:

```zsh
# Inspect and offer to remove unsafe certificates
./SSL/PEM_Check.sh --cafile /path/to/cacert.pem

# CI/read-only inspection
./SSL/PEM_Check.sh --audit --cafile /path/to/cacert.pem

```

## Exclusion policy

The default policy is `SSL/ca_exclusions.conf`. Its pipe-delimited format is:

```text
match_type|SHA-256 value|display name|reason
```

Supported match types are `cert_sha256` and `spki_sha256`. SPKI hashes are
preferred because the same public key remains blocked if its certificate is
reissued or cross-signed.

Root trust anchors normally cannot be usefully checked through their own OCSP
or CRL fields. Revoked or incident-affected CA hierarchies therefore belong in
this explicit policy, while macOS trust evaluation supplies current host-level
trust and distrust decisions.

## Author

- Florian Bidabe (contact@photonsec.com.au)
- GitHub: https://github.com/Enelass
