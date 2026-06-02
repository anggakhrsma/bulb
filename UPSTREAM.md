# Upstream Snapshot

Bulb ports Pi from a frozen upstream snapshot:

- Repository: <https://github.com/earendil-works/pi>
- Commit: `e56521e3234131a2c1639a74e2f15fff643acf30`
- Commit date: `2026-06-01T18:31:44+02:00`
- Commit subject: `Add extension mode context`

The first Bulb parity milestone is scoped to this exact commit. Later Pi
changes must be brought in as explicit sync batches so the ledger remains
auditable.

Run `./tools/generate-parity-ledger.sh ../pi` to rebuild the inventory. The
script refuses to generate a ledger from a different Pi commit.

