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
- `from_buffer`: `yaml::from_buffer` in-place parsing of a writable buffer (re-copied before every
  timed run, outside the clock), then `free`.
- `events`: the `Parser.next()` loop on a writable buffer, no tree (zero allocation).
- `decode`: `yaml::decode{Config}` of a tree built beforehand (only `servers.yaml`).
- `json`: `string::tformat("%s", tree)`, JSON output of a tree built beforehand.
- `find`: 1,000 key lookups (`map_100k.k_%d`) on a tree built beforehand (lazy map index).
- `foreach`: recursive traversal counting all nodes of a tree built beforehand.
- `free`: `Yaml.free` on an existing tree.

The library calls are in the `run_*` functions and `load_tree` of `bench.c3`; that is all to change
when the API changes. `baseline.md` holds the numbers of the old `Object` tree against this
library, measured before the old one was removed (its `tree`, `events`, ... rows are the old
library, the rows with a `2` suffix are the current modes).

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

- The temporary allocator (`tmem`) is not counted in allocs/bytes: it cannot be wrapped from
  outside. The parser does not use it; for `events` the proof is 0 allocations and an RSS peak of
  about the input.
- RSS is a high-water mark of the process: freed memory the allocator keeps is included. `decode`
  RSS includes the tree it decodes from.
- Run on an idle machine; times are of one process, no warm-up beyond the N repetitions (use the
  min). `bench/data` depends on `gen.py` only; `suite.yaml` needs `test-suite/`.
- Files: `config` (nested maps/sequences/scalars), `small-docs` (many tiny documents), `long-strings`
  (quoted, folded and block scalars with escapes), `deep` (200 levels, limit 256), `flow`
  (JSON-like, one document per line), `servers` (fits the decode struct), `suite` (all valid
  yaml-test-suite inputs, tiny), and the edge inputs of `gen.py` (wide sequence, 100 k-entry map,
  alias-heavy, escapes with `\L`/`\P`, depth 256/257, `%TAG`, flow keys of 2040/2041 tokens, block
  scalar at EOF). Lines stay below 65,535 columns, the scanner's limit.
