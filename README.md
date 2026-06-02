# Bulb

Bulb is an in-progress native Zig port of
[Pi](https://github.com/earendil-works/pi). The target is full feature parity
without a Node, Bun, npm, or TypeScript runtime dependency.

The first implementation chunk establishes:

- Zig `0.16.0` build metadata and CI checks.
- Public modules: `bulb_ai`, `bulb_agent`, `bulb_tui`,
  `bulb_coding_agent`, and `bulb_extension_sdk`.
- Native executables: `bulb`, `bulb-ai`, and `bulb-web`.
- A generated one-to-one parity ledger for the frozen Pi snapshot.
- The first native AI data types, agent lifecycle state, ANSI-width helper,
  extension ABI contract, and Bulb configuration constants.

Bulb is not feature complete yet. The ledger in `parity/ledger.tsv` is the
source of truth for port progress.

## Build

```sh
zig build
zig build test
zig build fmt-check
```

The default development service base URL is `http://127.0.0.1:8080`. Override
it at build time with:

```sh
zig build -Dservice-base-url=https://example.invalid
```

At runtime, `BULB_SERVICE_BASE_URL` takes precedence.

## Upstream Ledger

The ledger generator requires the frozen Pi checkout next to Bulb:

```sh
./tools/generate-parity-ledger.sh ../pi
```

See `UPSTREAM.md` and `PARITY.md` for the snapshot and status conventions.

