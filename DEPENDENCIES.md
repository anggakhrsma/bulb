# Dependency Review Policy

Bulb targets Zig `0.16.0` and starts with no third-party runtime dependencies.

## Allowed Dependencies

- Zig standard library.
- Reviewed Zig packages pinned in `build.zig.zon`.
- Reviewed operating-system libraries needed for native platform behavior.
- SQLite for the companion service once that implementation chunk lands.

## Disallowed Runtime Dependencies

- Node.js
- Bun
- npm
- TypeScript runtimes

Every new package or OS-library dependency must be documented here with its
version, purpose, license, and review notes before it is merged.

## Current Inventory

| Dependency | Version | Purpose | License | Review |
| --- | --- | --- | --- | --- |
| Zig standard library | 0.16.0 | Build and runtime foundation | MIT | Required toolchain |

