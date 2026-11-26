# Vendored upstream code

## StreamProtocol

- Source: the upstream project's `Sources/StreamProtocol/` directory.
- Tag: `v0.6.2`
- Commit: `4e00c805c25645f694c44be4886cdc39d6154542`
- License: Apache-2.0 (see `LICENSE-upstream.txt` in this directory;
  upstream NOTICE, if any, is preserved with the source).

The initial import commit is byte-identical to the tag. All Linux
modifications are in later commits (the patch series) and each modified
file carries a modification notice under its header, per Apache-2.0
section 4(b).

To update to a newer tag:

1. Replace this directory with the new tag's `Sources/StreamProtocol/`,
   byte-identical, as one commit; update the tag/commit above.
2. Re-apply the Linux patch series (`git apply -3` or cherry-pick).
3. The CI check (planned) fails if the tree differs from
   pristine + patches, or if an upstream file is unaccounted for
   (new, renamed or deleted).

`RemoteTLS.swift` is vendored for reference and diffing only; the
Linux build excludes it (see `Package.swift`) and replaces it with a
SwiftNIO + NIOSSL module.
