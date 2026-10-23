module Nokizaru
  # The Mozilla Public Suffix List (MPL-2.0), embedded at compile time so the
  # single binary carries it with no runtime fetch. The matcher that walks it
  # arrives in a later phase; this module is the embed and its integrity pin.
  #
  # The list is refreshed only by the maintainer, via tools/refresh_psl.cr; it is
  # never fetched at build or scan time. spec/psl_pin_spec.cr fails the gate if
  # the embedded bytes drift from SHA256 (the known-good pin), so a tampered or
  # stale list cannot slip in unreviewed.
  module PSL
    # The list bytes, verbatim from https://publicsuffix.org/list/public_suffix_list.dat
    DATA = {{ read_file("#{__DIR__}/../../data/public_suffix_list.dat") }}

    # SHA-256 of DATA. Known-good baseline pinned 2026-10 (PSL commit 52b71b3c).
    SHA256 = "3e6ca639b7ef33f86ec0e6fe9a475857cf2585f28fdf485f38f14d5f00c1c2a4"
  end
end
