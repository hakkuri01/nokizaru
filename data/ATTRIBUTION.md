# Bundled data provenance

Data files embedded into the Nokizaru binary at compile time.

## Public Suffix List (`public_suffix_list.dat`)

- Source: <https://publicsuffix.org/list/public_suffix_list.dat> (the only supported URL)
- Upstream commit: `52b71b3c4576ff77450cc7ebcfc7f34a916af3f9` (2026-10-17)
- SHA-256: `3e6ca639b7ef33f86ec0e6fe9a475857cf2585f28fdf485f38f14d5f00c1c2a4`
- License: Mozilla Public License 2.0 (MPL-2.0); see the header of the `.dat` file.
- Verified once on provisioning (provenance, cross-source corroboration against the
  GitHub mirror, structure, semantic canaries), pinned by `spec/psl_pin_spec.cr`, and
  refreshed only by the maintainer via `tools/refresh_psl.cr`.

The curated directory wordlists live at the repository root in `wordlists/` and are
embedded from there.
