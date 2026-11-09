#!/usr/bin/env bash
# Builds the benchmark and runs it once per (mode, file) in its own process, so the peak RSS
# of one run does not leak into the next. Prints a markdown table, writes a CSV next to it.
# usage: bench/run.sh [-n iterations] [-o out-prefix]     (default: 5 iterations, bench/out)
cd "$(dirname "$0")/.." || exit 2
n=5; out=bench/out
while getopts n:o: o; do
	case $o in n) n=$OPTARG ;; o) out=$OPTARG ;; *) exit 2 ;; esac
done
[ -f bench/data/config.yaml ] || python3 bench/gen.py || exit 2
c3c build bench -O2 >/dev/null || { echo "build failed" >&2; exit 2; }
csv=$out.csv
echo "mode,file,bytes,iters,min_ms,median_ms,mb_per_s,allocs,alloc_bytes,peak_live_bytes,rss_base_kb,rss_peak_kb" > "$csv"
for f in bench/data/*.yaml; do
	modes="tree events"
	[ "$(basename "$f")" = servers.yaml ] && modes="tree events decode"
	for m in $modes; do ./build/bench "$m" "$f" "$n" >> "$csv" || echo "failed: $m $f" >&2; done
done
echo "| mode | file | MiB | min ms | median ms | MiB/s | allocs | alloc MiB | peak live MiB | RSS base MiB | RSS peak MiB |"
echo "|---|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|"
tail -n +2 "$csv" | awk -F, '
function mib(x) { return x == "n/a" ? "n/a" : sprintf("%.1f", x / 1048576) }
{ sub(".*/", "", $2)
  printf "| %s | %s | %.2f | %.1f | %.1f | %.1f | %d | %s | %s | %s | %s |\n", $1, $2, $3 / 1048576, $5, $6, $7, $8, mib($9), mib($10),
    $11 == "n/a" ? "n/a" : sprintf("%.1f", $11 / 1024), $12 == "n/a" ? "n/a" : sprintf("%.1f", $12 / 1024) }'
