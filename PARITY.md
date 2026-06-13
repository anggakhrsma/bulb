# Parity Ledger

`parity/ledger.tsv` records every tracked file in the frozen Pi snapshot.
It is generated from the upstream checkout and enriched with
`parity/status.tsv`.

## Status Values

- `pending`: not ported yet.
- `in_progress`: actively being translated.
- `implemented`: represented by native Zig or Bulb-native assets.
- `translated`: intentionally represented in another Bulb form.
- `blocked`: cannot be ported yet; the notes column must explain why.
- `not_applicable`: intentionally excluded; the notes column must explain why.

## Test Strategy

Production feature parity is the active priority. For each feature slice, port
the smallest upstream-derived tests needed to lock critical behavior and keep
`zig build test` passing. Full upstream test parity remains a later hardening
pass, and deferred test groups must stay visible in `parity/status.tsv` notes.

Update `parity/status.tsv`, then regenerate the ledger:

```sh
./tools/generate-parity-ledger.sh ../pi
```

The generated ledger is committed so progress can be reviewed without an
upstream checkout.
