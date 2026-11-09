## YAML parser for C3

A [YAML 1.2](https://yaml.org/spec/1.2.2/) parser for the [C3 programming
language](http://c3-lang.org).

* Parses the full YAML 1.2 syntax: block and flow collections, all scalar styles,
  anchors and aliases, tags, `%YAML` and `%TAG` directives, multiple documents.
* Builds `Object` trees (`std::collections::object`) using the YAML 1.2 core schema (null,
  bool, int, float, string), or decodes a document straight into a struct.
* Passes all 402 cases of the [yaml-test-suite](https://github.com/yaml/yaml-test-suite)
  (events and errors), and all 279 JSON comparisons.
* Limits alias expansion, collection keys and nesting depth, so "billion laughs" inputs fail
  fast.
* Includes a command-line tool `yamlv` to validate YAML, print the event stream, or convert
  to JSON.

Requires [c3c](https://github.com/c3lang/c3c) v0.8.5 or newer.

### Usage

YAML can be parsed from a `String`, an `InStream` (e.g. `File`), or directly from a file
path.

The input must be UTF-8 and contain only printable characters (YAML 1.2.2 §5.1). A byte
order mark is skipped at the start of the stream and at the start of a line outside a flow
collection or scalar (YAML allows one before each document). Anything else, such as a NUL
byte, fails with `parser::INVALID_CHARACTER`.

```
Yaml data = yaml::parse(s)!;                 // a String, char[], DString or InStream (&file)
Yaml data = yaml::tparse(s)!;                // the same with tmem: no free() needed
Yaml data = yaml::from_string(s)!;           // the typed forms: from_string, from_stream, from_file
Yaml data = yaml::from_stream(&file)!;
Yaml data = yaml::from_file("config.yaml")!;
```

All of them accept a memory allocator (default `mem`; `tparse` always uses `tmem`) and a flag
for error verbosity. Release the data with `data.free()`.

A YAML stream can hold several documents. `data.len()` is the number of documents, and each
document is one `Object*`. An empty document is `null`. To declare an `Object*` variable, add
`import std::collections::object;`.

To access a value, use `Yaml.get` (or the `[]` operator) with a dotted path. Mapping keys
and sequence indexes are separated by `.`:

```yaml
database:
  ports: [8000, 8001, 8002]
```
`data.get("database.ports.0")` or `data["database.ports.0"]` returns the `Object*` for
`8000`. Both read the first document. Use `data.get_in(doc, path)` for the others. A missing
path returns the fault `NOT_FOUND`, and so does a path with an empty segment (`a.`, `a..b`) or
an index with a leading zero (`ports.01`). The empty path `""` is the whole document. Keys
that are empty or contain a `.` cannot be reached by a path; iterate over the `Object*`
instead.

Untagged plain scalars are resolved with the core schema:
* `~`, `null`, `Null`, `NULL` and the empty value give null;
* `true`/`false` (also `True`, `TRUE`, `False`, `FALSE`) give bool;
* `12`, `0o17`, `0x1F` give int;
* `1.5`, `1e3`, `.inf`, `-.Inf`, `.nan` give float.

Quoted and block scalars are strings. The tags `!!str`, `!!int`, `!!float`, `!!bool` and
`!!null` force a type; a value that does not fit the tag fails with
`yaml::INVALID_INPUT_FORMAT`. Any other tag is kept in the event stream, and a scalar with
such a tag is a string (`!foo 12` is `"12"`).

Aliases are deep copies of the anchored node. Duplicate keys keep the last value. A null key
(`~: x`, `: x` or `{? : x}`) and the empty string key (`"": x`) are the same key `""`, so
`{"": 1, ~: 2}` has a single entry. A collection used as a key (`[a, b]: c`) becomes its
compact JSON text (`["a","b"]`).

### Decoding into a struct

`yaml::decode{T}(data)` decodes the first document into a `T` (`yaml::decode_in{T}(data, doc)`
another one):

```c3
enum Mode { DEV, PROD }
struct Database { String host; int[2] ports; Mode mode; }
struct Config { String title; double ratio; Database database; String[] tags; }

Yaml data = yaml::tparse(s)!;
Config cfg = yaml::decode{Config}(data, tmem)!;
```

See `example/yaml-decode.c3`. Supported members: structs (nested), all integer types
(range-checked), `float`/`double` (an int is accepted), `bool`, `String`, enums (by name),
fixed arrays (a shorter sequence leaves the rest zero) and slices of any of these. A missing or
null key leaves the member zeroed and unknown keys are ignored. A wrong type, an out-of-range
integer, an unknown enum name or a sequence that is too long fails with `yaml::DECODE_ERROR`
and, with `verbose`, prints the path (`database.ports.1: expected int, got string`). A missing
document fails with `NOT_FOUND`.

Memory: every `String` and slice of the result is allocated with the given allocator (default
`mem`). Use `tmem` or an arena to free it all at once, or free each one yourself. The result
does not refer to `data`, and after an error nothing stays allocated.

### Error handling

When a parsing error occurs, the line, column (in bytes), message, the source line (at most
60 bytes on each side of the error, control characters shown as `?`) and a caret are printed
to `stderr`, and the function returns a fault (for example `parser::INVALID_ESCAPE`):

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
* `parser::MAX_DEPTH` (256): nesting depth. The event parser (`Parser.next`, `yamlv -e`)
  checks flow collections; building a document checks the whole tree, including the parts
  that come from aliases.

The other limits are budgets for one `yaml::from_*` call, shared by all documents of the
stream (the result keeps every document):
* `parser::MAX_ALIAS_NODES` (1,000,000): nodes created by alias expansion.
* `parser::MAX_ALIAS_BYTES` (64 MiB): string and key bytes copied by alias expansion.
* `parser::MAX_KEY_TEXT` (4 MiB) plus `parser::KEY_TEXT_PER_BYTE` (4) bytes per input byte:
  the JSON text of all collection keys (`[a, b]: c`). A nested collection key is escaped
  again at every level, so its text can double per level.

### Command-line tool

```sh
c3c build yamlv
```

* `build/yamlv < file.yaml`: validates the input. It prints `YAML is valid.` to `stderr`, or
  the error, and exits with code 0 or 1.
* `build/yamlv -e < file.yaml`: prints the event stream in yaml-test-suite format. On a
  syntax error, the events before it are printed too. The input is checked for invalid
  characters first, so such an error prints no events.
* `build/yamlv -j < file.yaml`: prints every document as one line of JSON.

On Windows use `cmd` or Git Bash: PowerShell has no `<` and re-encodes piped text. `yamlv` reads
stdin and writes stdout in binary mode, so the output has `\n` line ends.

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

With [c3l](https://github.com/konimarti/c3l):

```sh
c3l add https://github.com/konimarti/yaml.c3l
```

This installs the library into `lib/` and records it in `project.json` and `c3l.lock`. After
cloning your project, run `c3l sync` to restore it.

Or as a git submodule. The directory must be named `yaml.c3l` and lie inside a dependency
search path:

```sh
git submodule add https://github.com/konimarti/yaml.c3l lib/yaml.c3l
```

and in your `project.json`:

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
case. The JSON comparison needs Python 3 (`python3` or `python`); without it `-j` exits with 2.

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

	Yaml cfg = yaml::from_string(s, tmem)!!;

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
