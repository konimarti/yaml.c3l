## YAML parser for C3

A [YAML 1.2](https://yaml.org/spec/1.2.2/) parser for the [C3 programming
language](http://c3-lang.org).

* Parses the full YAML 1.2 syntax: block and flow collections, all scalar styles,
  anchors and aliases, tags, `%YAML` and `%TAG` directives, multiple documents.
* Builds `std::collections::Object` trees using the YAML 1.2 core schema (null, bool, int,
  float, string).
* Passes all 402 cases of the [yaml-test-suite](https://github.com/yaml/yaml-test-suite)
  (events and errors), and all 279 JSON comparisons.
* Limits alias expansion, collection keys and nesting depth, so "billion laughs" inputs fail
  fast.
* Includes a command-line tool `yamlv` to validate YAML, print the event stream, or convert
  to JSON.

Requires [c3c](https://github.com/c3lang/c3c) v0.8.6 or newer.

### Usage

YAML can be parsed from a `String`, an `InStream` (e.g. `File`), or directly from a file
path.

The input must be UTF-8 (a leading byte order mark is skipped) and contain only printable
characters (YAML 1.2.2 §5.1). Anything else, such as a NUL byte, fails with
`parser::INVALID_CHARACTER`.

Read data from `String s`:
```
YamlData data = yaml::from_string(s)!;
```

Read data from `InStream in`:
```
YamlData data = yaml::from_stream(in)!;
```

Read data directly from a file path:
```
YamlData data = yaml::from_file("config.yaml")!;
```

The `yaml::from_*` functions accept two additional arguments: a memory allocator and a flag
for error verbosity. The default allocator is `mem`. Release the data with `data.free()`.

A YAML stream can hold several documents. `data.len()` is the number of documents, and each
document is one `Object*`. An empty document is `null`.

To access a value, use `YamlData.get` (or the `[]` operator) with a dotted path. Mapping keys
and sequence indexes are separated by `.`:

```yaml
database:
  ports: [8000, 8001, 8002]
```
`data.get("database.ports.0")` or `data["database.ports.0"]` returns the `Object*` for
`8000`. Both read the first document. Use `data.get_in(doc, path)` for the others. A missing
path returns the fault `NOT_FOUND`.

Untagged plain scalars are resolved with the core schema:
* `~`, `null`, `Null`, `NULL` and the empty value give null;
* `true`/`false` (also `True`, `TRUE`, `False`, `FALSE`) give bool;
* `12`, `0o17`, `0x1F` give int;
* `1.5`, `1e3`, `.inf`, `-.Inf`, `.nan` give float.

Quoted and block scalars are strings. The tags `!!str`, `!!int`, `!!float`, `!!bool` and
`!!null` force a type; any other tag is kept in the event stream but does not change the
value.

Aliases are deep copies of the anchored node. Duplicate keys keep the last value.

### Error handling

When a parsing error occurs, the line, column (in bytes), message, the source line (at most
60 bytes on each side of the error) and a caret are printed to `stderr`, and the function returns a fault (for example
`parser::INVALID_ESCAPE`):

```sh
$ printf 'a: "x\\q"\n' | build/yamlv
YAML ERROR -- Line 1, Col 6: invalid escape sequence
a: "x\q"
     ^
```

Error messages can be silenced by setting the optional `verbose` to `false` in any of the
`yaml::from_*` functions. The first error stops parsing.

### Limits

The limits for untrusted input are constants in `yaml::parser`. Exceeding one fails with
`parser::LIMIT_EXCEEDED`:
* `parser::MAX_DEPTH` (512): nesting depth. The event parser (`Parser.next`, `yamlv -e`)
  checks flow collections; building a document checks the whole tree, including the parts
  that come from aliases.
* `parser::MAX_ALIAS_NODES` (1,000,000): nodes created by alias expansion in a single
  document.
* `parser::MAX_ALIAS_BYTES` (64 MiB): string and key bytes copied by alias expansion in a
  single document.
* `parser::MAX_KEY_TEXT` (4 MiB): the JSON text of all collection keys (`[a, b]: c`) in a
  single document.

### Command-line tool

```sh
c3c build yamlv
```

* `build/yamlv < file.yaml`: validates the input. It prints `YAML is valid.` to `stderr`, or
  the error, and exits with code 0 or 1.
* `build/yamlv -e < file.yaml`: prints the event stream in yaml-test-suite format (all events
  before an error too).
* `build/yamlv -j < file.yaml`: prints every document as one line of JSON.

```sh
$ printf 'a: &x [1, 2.5]\nb: *x\nc: !!str 3\n' | build/yamlv -e
+STR
+DOC
+MAP
=VAL :a
+SEQ [] &x
=VAL :1
=VAL :2.5
-SEQ
=VAL :b
=ALI *x
=VAL :c
=VAL <tag:yaml.org,2002:str> :3
-MAP
-DOC
-STR
$ printf 'a: &x [1, 2.5]\nb: *x\nc: !!str 3\n' | build/yamlv -j
{"b":[1,2.5],"c":"3","a":[1,2.5]}
```

JSON keys follow the internal hash map order. A float keeps its type: `1.0` and `1e3` are
printed as `1.0` and `1000.0`. `.inf` and `.nan` have no JSON form and are printed as `null`.

### Installation

Add the library as a submodule to your C3 project:

```
git submodule add http://github.com/konimarti/yaml.c3l lib
```

Then update your `project.json` to include:

```json
{
    "dependency-search-paths": [ "lib" ],
    "dependencies": [ "yaml" ]
}
```

### Running tests

Unit tests:
```sh
c3c test
```

The [yaml-test-suite](https://github.com/yaml/yaml-test-suite) (its `data` branch) is
expected in `test-suite/`:

```sh
git clone -b data https://github.com/yaml/yaml-test-suite test-suite
test/run-suite.sh -j
```

```
valid PASS 308/308  error PASS 94/94
PASS 402 / FAIL 0 / 402
json PASS 279/279
```

`-v` lists the failing cases, and `test/run-suite.sh test-suite/<ID>` shows the diff for one
case. The JSON comparison needs `python3`.

### Example

```c3
module app;

import std::io, yaml;

fn void main() => @pool()
{
	String s = `
title: YAML example
database:
  ports: [8000, 8001, 8002]
  enabled: true
---
second: document`;

	YamlData cfg = yaml::from_string(s, tmem)!!;

	io::printfn("documents: %d", cfg.len());
	io::printfn("title: %s", cfg.get("title")!!);
	io::printfn("ports: %s", cfg.get("database.ports")!!);
	io::printfn("first port: %d", cfg["database.ports.0"]!!.i);
	io::printfn("second: %s", cfg.get_in(1, "second")!!);
}
// Output:
// documents: 2
// title: "YAML example"
// ports: [8000,8001,8002]
// first port: 8000
// second: "document"
```
