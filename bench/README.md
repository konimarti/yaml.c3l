# Benchmark

Measures parse time, allocations and peak memory of the library on a generated corpus.

```sh
python3 bench/gen.py           # corpus into bench/data/ (gitignored), ~10 MB files, fixed seed
bench/run.sh -n 5              # build with -O2, run every file in its own process,
                               # print a markdown table, write bench/out.csv
```

One run by hand: `c3c build bench -O2 && build/bench <mode> <file> [iterations]`
prints one CSV line.

## Modes

- `tree`: `yaml::from_string` on an input already in memory (no I/O), then `free`.
- `tree2`: `yaml2::from_string` (v2 tree) on an input in memory, then `free`.
- `from_buffer`: `yaml2::from_buffer` in-place parsing of a mutable buffer, then `free`.
- `events`: `yaml::parser::Parser.next()` loop only, no tree.
- `events2`: `yaml2::parser::Parser.next()` zero-allocation in-place event parser, no tree.
- `decode`: `yaml::decode{Config}` of a tree built beforehand (only `servers.yaml`).
- `decode2`: `yaml2::decode{Config}` of a v2 tree built beforehand (only `servers.yaml`).
- `json`: `string::tformat("%s", tree)` JSON output on the old tree.
- `json2`: `string::tformat("%s", tree)` streaming JSON output on the v2 tree.
- `find`: look up 1,000 keys (`map_100k.k_%d`) on the old tree.
- `find2`: look up 1,000 keys (`map_100k.k_%d`) on the v2 tree (using lazy map index).
- `foreach`: recursive traversal counting all nodes on the old tree.
- `foreach2`: recursive traversal counting all nodes on the v2 tree.
- `free`: `yaml::Yaml.free` on an existing tree.
- `free2`: `yaml2::Yaml.free` on an existing v2 tree.

The library calls are in `run_tree`, `run_events`, `load_tree` and `run_decode` in `bench.c3`;
that is all to change when the API changes.

## Columns

| column | meaning |
|---|---|
| min ms, median ms | wall time of one parse over N runs (the free is not timed), plain heap allocator |
| MiB/s | input size / min time |
| allocs, alloc MiB | number and total size of allocations made through the library allocator in one run (a `TrackingAllocator`, a separate untimed run) |
| peak live MiB | the most the library allocator had live at once |
| RSS base MiB | `VmHWM` after loading the input, before any parse |
| RSS peak MiB | `VmHWM` after the timed runs. It includes the input and the base; Linux only (`n/a` elsewhere) |

## Caveats

- The temporary allocator (`tmem`: scanner/parser working memory, scalar buffers) is not counted
  in allocs/bytes: it cannot be wrapped from outside. Its use shows only in RSS, so `events`
  reports 0 allocations. For `events` and a rewrite that uses `tmem`, compare RSS.
- RSS is a high-water mark of the process: freed memory the allocator keeps is included. `decode`
  RSS includes the tree it decodes from.
- Run on an idle machine; times are of one process, no warm-up beyond the N repetitions (use the
  min). `bench/data` depends on `gen.py` only; `suite.yaml` needs `test-suite/`.
- Files: `config` (nested maps/sequences/scalars), `small-docs` (many tiny documents), `long-strings`
  (quoted, folded and block scalars with escapes), `deep` (200 levels, limit 256), `flow`
  (JSON-like, one document per line), `servers` (fits the decode struct), `suite` (all valid
  yaml-test-suite inputs, tiny).
