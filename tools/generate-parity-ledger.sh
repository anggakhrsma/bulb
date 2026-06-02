#!/bin/sh
set -eu

upstream="${1:-../pi}"
output="${2:-parity/ledger.tsv}"
status_file="${3:-parity/status.tsv}"
expected_commit="e56521e3234131a2c1639a74e2f15fff643acf30"

actual_commit="$(git -C "$upstream" rev-parse HEAD)"
if [ "$actual_commit" != "$expected_commit" ]; then
    printf 'expected Pi commit %s, found %s\n' "$expected_commit" "$actual_commit" >&2
    exit 1
fi

mkdir -p "$(dirname "$output")"
tmp="${output}.tmp.$$"
trap 'rm -f "$tmp"' EXIT HUP INT TERM

{
    printf '# upstream_commit\t%s\n' "$actual_commit"
    printf 'upstream_path\tarea\tkind\tstatus\tbulb_path\tnotes\n'
    git -C "$upstream" ls-files |
        awk -F '\t' '
            BEGIN { OFS = "\t" }
            NR == FNR {
                if (FNR == 1) next
                status[$1] = $2
                bulb_path[$1] = $3
                notes[$1] = $4
                next
            }
            function area(path) {
                if (path ~ /^packages\/ai\//) return "bulb_ai"
                if (path ~ /^packages\/agent\//) return "bulb_agent"
                if (path ~ /^packages\/tui\//) return "bulb_tui"
                if (path ~ /^packages\/coding-agent\//) return "bulb_coding_agent"
                if (path ~ /^\.github\//) return "ci"
                if (path ~ /^scripts\//) return "tooling"
                return "root"
            }
            function kind(path) {
                if (path ~ /(^|\/)fixtures?\//) return "fixture"
                if (path ~ /(^|\/)tests?\// || path ~ /\.test\.ts$/) return "test"
                if (path ~ /(^|\/)examples?\//) return "example"
                if (path ~ /^docs\// || path ~ /\.md$/) return "doc"
                if (path ~ /^\.github\//) return "ci"
                if (path ~ /^scripts\//) return "tooling"
                return "source"
            }
            {
                current_status = ($0 in status) ? status[$0] : "pending"
                current_path = ($0 in bulb_path) ? bulb_path[$0] : ""
                current_notes = ($0 in notes) ? notes[$0] : ""
                print $0, area($0), kind($0), current_status, current_path, current_notes
            }
        ' "$status_file" -
} > "$tmp"

mv "$tmp" "$output"
trap - EXIT HUP INT TERM

