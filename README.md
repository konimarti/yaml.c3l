## YAML parser for C3

A [YAML 1.2](https://yaml.org/spec/1.2.2/) parser for the [C3 programming language](http://c3-lang.org), built like
[rapidyaml](https://github.com/biojppm/rapidyaml): the parser decodes in place and allocates nothing, and the tree is one
flat array of 36-byte nodes over the input.

* Full YAML 1.2 syntax: block and flow collections, all scalar styles, anchors and aliases, tags, `%YAML` and `%TAG`,
  multiple documents.
* A `Node` API (dotted-path lookup, `foreach`, core-schema typed reads, JSON output) or decode straight into a struct.
  Aliases are references; billion-laughs inputs fail fast.
* Passes all 402 cases of the [yaml-test-suite](https://github.com/yaml/yaml-test-suite) (events and errors) and all 279
  JSON comparisons.

Requires [c3c](https://github.com/c3lang/c3c) v0.8.5 or newer.

### Usage

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
timeout: "abc"
---
second: document`;

	Yaml cfg = yaml::tparse(s)!!;

	io::printfn("documents: %d", cfg.len());
	io::printfn("ports: %s", cfg["database.ports"]);
	io::printfn("first port: %d", cfg["database.ports.0"].as_int()!!);
	io::printfn("retries: %d", cfg["retries"].as_int() ?? 3);
	io::printfn("second: %s", cfg.doc(1)["second"]);
	foreach (i, port : cfg["database.ports"].items()) io::printfn("port %d = %d", i, port.as_int()!!);
}
// documents: 2
// ports: [8000,8001,8002]
// first port: 8000
// retries: 3
// second: "document"
// port 0 = 8000
// port 1 = 8001
// port 2 = 8002
```

**Parsing.** `yaml::parse(x)` takes a `String`, `char[]`, `DString` or an `InStream` (`&file`); `from_string`, `from_stream`
and `from_file(path)` are the typed forms, `tparse` uses `tmem` (no `free()`). All take an allocator (default `mem`) and
`verbose`, and **copy** the input once. Release with `data.free()`; copies of a `Yaml` are handles of one tree, so free
exactly one. `data.len()` is the number of documents (an empty one is `null`), `data.doc(i)` the root of document `i`, and `foreach (doc : data.docs())` iterates them;
`data[path]` and `data.find(path)` read document 0.

**Lookup.** A path is map keys and sequence indexes separated by `.`. `node[path]` (= `node.find(path)`) never fails: a
missing path gives a node with `exists()` `false`. `node.get(path)` fails with `NOT_FOUND` (`data.get_in(doc, path)` for
other documents), `node.at(i)` is the i-th item of a sequence, `node.len()` the number of children (lookups in maps of more than 64 entries use a hash index built on the first lookup). An empty segment
(`a..b`) or an index with a leading zero (`ports.01`) is not found, `""` is the node itself, keys that are empty or contain
`.` and collection keys cannot be reached by a path (use `entries()`), the last of duplicate keys wins, aliases are
followed. `items()` and `entries()` (`e.key`, `e.key_node`, `e.value`) work with `foreach (x : ...)` and `foreach (i, x :
...)`, O(1) per step.

**Types.** Untagged plain scalars follow the core schema: `~`, `null`, `Null`, `NULL` and the empty value are null;
`true`/`false` (also `True`, `TRUE`, `False`, `FALSE`) bool; `12`, `0o17`, `0x1F` int; `1.5`, `1e3`, `.inf`, `-.Inf`, `.nan`
float. Quoted and block scalars are strings. `!!str`, `!!int`, `!!float`, `!!bool` and `!!null` force a type (a value that
does not fit fails at parse time with `yaml::INVALID_INPUT_FORMAT`); any other tag is kept (`tag_prefix()` + `tag()`,
`is_tag(full)`) and the scalar is a string. `kind()` is one of `MISSING`, `NULL`, `BOOL`, `INT`, `FLOAT`, `STRING`,
`SEQUENCE`, `MAPPING`; `is_null()`, `is_bool()`, `is_int()`, `is_float()`, `is_string()`, `is_seq()`, `is_map()`,
`is_scalar()`, `is_alias()` test it. `as_bool()`, `as_int()` (`long`), `as_int128()`, `as_float()` (an int is accepted) and
`as_string()` fail with `NOT_FOUND` (missing), `WRONG_KIND` or `OUT_OF_RANGE`; `text()` is the raw text of any scalar,
`anchor()` its anchor.

`x.as_int() ?? 3` replaces *every* failure, so `timeout: "abc"` silently becomes the default. `as_int_or(3)` (also
`as_bool_or`, `as_float_or`, `as_string_or`) replaces only a missing or null value: `cfg["retries"].as_int_or(3)` is 3,
`cfg["timeout"].as_int_or(30)` fails with `yaml::WRONG_KIND`, `cfg["timeout"].as_int() ?? 30` is 30.

**Aliases, duplicate keys, collection keys; JSON.** Printing a `Yaml` (`%s`) writes every document as one line of compact
JSON, printing a `Node` writes that node. Keys keep the source order; a float keeps its type (`1.0`, `1000.0`); `.inf` and
`.nan` print as `null`; a null key is `""`; a collection key is printed as its compact JSON text. `data.to_json(allocator)` returns the text, `data.write_json(out)` writes it to an
`OutStream` (both fail with `LIMIT_EXCEEDED` when the key-text budget is exceeded).

```c3
Yaml y = yaml::tparse("base: &b {x: 1}\ncopy: *b\n? [a, b]\n: pair\nk: 1\nk: 2\n")!!;
io::printfn("%s", y);
io::printfn("copy.x = %d, alias: %s, k = %s", y["copy.x"].as_int()!!, y["copy"].is_alias(), y["k"]);
foreach (e : y.doc(0).entries()) io::printfn("key %s, a collection: %s", e.key_node, e.key_node.is_seq());
// {"base":{"x":1},"copy":{"x":1},"[\"a\",\"b\"]":"pair","k":2}
// copy.x = 1, alias: true, k = 2
// key "base", a collection: false
// key "copy", a collection: false
// key ["a","b"], a collection: true
// key "k", a collection: false
```

`node.to_object(allocator)` converts a node to a `std::collections::object` `Object*` (free it with `o.free()`; a collection
key becomes its JSON text): `Object* o = y.doc(0).to_object(tmem)!!;`

### Decoding into a struct

`yaml::decode{T}(data)` decodes the first document into a `T` (`decode_in{T}(data, doc)` another one, `data.decode(T)`, `node.decode(T)` any node):

```c3
enum Mode { DEV, PROD }
struct Database { String host; int[2] ports; Mode mode; }
struct Config { String title; double ratio; Database database; String[] tags; }

Yaml data = yaml::tparse(s)!!;
Config cfg = yaml::decode{Config}(data, tmem)!!;
Database db = data["database"].decode(Database, tmem)!!;
// cfg: YAML example localhost:5432 PROD [a, b]
```

See `example/yaml-decode.c3`. Members: structs, integer types (range-checked), `float`/`double` (an int is accepted),
`bool`, `String`, enums (by name), fixed arrays (a shorter sequence leaves the rest zero) and slices of these. A missing or
null key leaves the member zeroed, unknown keys are ignored; a wrong type, an out-of-range integer, an unknown enum name or
a too long sequence fails with `yaml::DECODE_ERROR` and, with `verbose`, prints the path (`database.ports.1: expected int,
got string`); a missing document fails with `NOT_FOUND`. Strings and slices of the result use the given allocator (`tmem`,
an arena, or free each one), do not refer to `data`, and nothing stays allocated after an error. `decode_borrowed{T}(node)`
(or `node.decode_borrowed(T)`) allocates no strings: they point into the tree, valid while `data` lives (slices are still
allocated).

### Memory model

* **Parsing allocates the tree only**: one growing array of 36-byte nodes (plus one for anchors and tags) and one copy of
  the input. Measured on a 10 MB nested file at `-O2`: 24 allocations and 44 MB peak RSS, against 1.6 million allocations
  and 125 MB for the previous `Object` tree. The event parser makes none.
* **Text is decoded in place.** Escapes, line folding and block scalar indentation only shrink the text, so scalars, keys,
  anchors and tags are spans of the one input buffer. Strings you read (`as_string()`, `text()`, `key`, `anchor()`) are
  views into the tree, valid until `free()`; copy them to keep them longer.
* **In place on your buffer.** `yaml::from_buffer(buf)` parses `buf` without copying it: it must be writable (a `String`
  literal converts to `char[]` and crashes at the first write), its content is destroyed (also after an error), and it must
  outlive the `Yaml`. Everything else copies.
* **Spill.** The only text that grows is `"\L"` and `"\P"` (U+2028, U+2029: 2 bytes become 3); the tree keeps such scalars
  in a side buffer. The event parser needs a spill allocator (`Parser.init_inplace(buf, verbose, allocator)`), else they
  fail with `parser::NO_SPACE`.
* **Events.** The texts of an `Event` are spans: `parser.text(span)`; `parser.view(e)` prints:

```c3
char[] buf = "k: [v, 'w']\n".tcopy();     // writable
Parser p;                                  // import yaml::parser;  (64 KB: not for tiny stacks)
p.init_inplace(buf);
for (Event e = p.next()!!; e.type != STREAM_END; e = p.next()!!) io::printn(p.view(e));
// +STR +DOC +MAP =VAL :k +SEQ [] =VAL :v =VAL 'w -SEQ -MAP -DOC  (one per line)
```

### Errors and limits

A parsing error prints the line, column (in bytes), message, the source line (at most 60 bytes on each side, control
characters shown as `?`) and a caret to `stderr`, and returns a fault; the first error stops parsing. `verbose = false`
silences the message.

```c3
Yaml? y = yaml::from_string("k: v\na: \"x\\q\"\n");
if (catch err = y) io::printfn("failed: %s", err);
// YAML ERROR -- Line 2, Col 6: invalid escape sequence
// a: xx\q"
//      ^
// failed: parser::INVALID_ESCAPE
```

The excerpt is taken from the buffer after in-place decoding, so text already decoded on the same line can look different
(`a: "x\q"` shows as `a: xx\q"`). The input must be UTF-8 with only printable characters (YAML 1.2.2 §5.1); a byte order
mark is skipped at the start and before a document, anything else, such as a NUL byte, fails with
`parser::INVALID_CHARACTER`.

Limits are constants in `yaml::parser`; exceeding one fails with `parser::LIMIT_EXCEEDED`: `MAX_DEPTH` (256: collection
nesting and block indentation levels, in every API), `MAX_INPUT` (1 GiB − 1), `QUEUE_SIZE` (2048: an implicit key, such as a
flow-mapping key, spans at most about 2040 tokens), `MAX_TAG_DIRECTIVES` (16 `%TAG` per document), `MAX_ALIAS_NODES`
(1,000,000) and `MAX_ALIAS_BYTES` (64 MiB) (what alias expansion would create, counted for the whole stream when the tree is
built; this bounds the cost of printing, decoding or walking it), and `MAX_KEY_TEXT` (4 MiB) plus `KEY_TEXT_PER_BYTE` (4)
per input byte (the JSON text of collection keys, in JSON output and `to_object` only). Also `LIMIT_EXCEEDED`: a token that starts
after column 65,535 (a line wider than 64 KiB, even inside a flow collection: break long flow collections over several lines).

### Command-line tool

`c3c build yamlv`, then `build/yamlv < file.yaml` validates (prints `YAML is valid.` to `stderr`, or the error; exit code 0
or 1), `-e` prints the event stream in yaml-test-suite format (on an error, the events before it too), `-j` prints every
document as one line of JSON. On Windows use `cmd` or Git Bash: PowerShell has no `<` and re-encodes piped text.

```sh
$ printf 'a: &x [1, 2.5]\nb: *x\n' | build/yamlv -e | tr '\n' ' '
+STR +DOC +MAP =VAL :a +SEQ [] &x =VAL :1 =VAL :2.5 -SEQ =VAL :b =ALI *x -MAP -DOC -STR
$ printf 'a: &x [1, 2.5]\nb: *x\n' | build/yamlv -j
{"a":[1,2.5],"b":[1,2.5]}
```

### Installation

With [c3l](https://github.com/konimarti/c3l):

```sh
c3l add https://github.com/konimarti/yaml.c3l
```

This installs the library into `lib/` and records it in `project.json` and `c3l.lock`; after cloning your project, run `c3l
sync`. Or as a git submodule, in a directory named `yaml.c3l` inside a dependency search path (`git submodule add
https://github.com/konimarti/yaml.c3l lib/yaml.c3l`), and in your `project.json`:

```json
{ "dependency-search-paths": [ "lib" ], "dependencies": [ "yaml" ] }
```

### Running tests

`c3c test` runs the unit tests. The [yaml-test-suite](https://github.com/yaml/yaml-test-suite) (its `data` branch) is
expected in `test-suite/`; `-v` lists failing cases, the JSON comparison needs Python 3. `bench/` measures time, allocations
and memory (`bench/README.md`; `bench/baseline.md` compares with the old `Object` tree).

```sh
git clone -b data https://github.com/yaml/yaml-test-suite test-suite
test/run-suite.sh -j       # valid 308/308, error 94/94, PASS 402 / FAIL 0, json 279/279
```

### Breaking changes in 0.2

* **`Object*` is gone from the API.** `Yaml.docs` and the `.i`, `.s`, `.f`, `.b` fields are replaced by `Node` and `as_*()`;
  `to_object()` converts. `as_int()` is a `long` (was `int128`): use `as_int128()`.
* **`data["a.b"]` and `find` never fail**; `cfg["x"]!!` no longer compiles. Use `get` for the old checked behaviour, or
  `exists()`. `get_in(doc, path)` still exists, `doc(i)` is new.
* **Collection keys are not addressable by their JSON text**: use `entries()` and `key_node`. **JSON keys are in source
  order** (were hash order).
* **Strings are views into the tree**, not owned copies (`decode` still copies). **`char[]` input is copied** like `String`;
  only `from_buffer` and `Parser.init_inplace` parse in place and destroy the buffer.
* **Event parser:** `Parser.init(String)` is now `init_inplace(char[])`; `Event` fields are spans (`parser.text(span)`), a
  tag is `tag_prefix` + `tag` (never concatenated), events print with `parser.view(e)`.
* **New limits:** a line wider than 65,535 columns, nesting depth for block collections in the event parser, an implicit key
  over about 2040 tokens, more than 16 `%TAG` directives per document and input over 1 GiB fail with `LIMIT_EXCEEDED`.
  `MAX_ALIAS_*` count the expanded size of aliases; `MAX_KEY_TEXT` applies to JSON output and `to_object` only. Error
  excerpts show text already decoded in place.
