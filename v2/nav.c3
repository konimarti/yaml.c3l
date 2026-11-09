// v2 contract. Card (c) owns this file: Node, navigation, typed reads, Yaml.get/get_in/doc/len.
// Rules: `[]` / `find` never fail (they give a missing node); `get` is the checked form (NOT_FOUND).
// Aliases are followed by every reader; shadowed (overridden duplicate) entries are skipped.
// A missing node: exists() is false, kind() is MISSING, is_null() is false, as_* fault NOT_FOUND.
module yaml2;

import std::io;
import yaml2::parser;

enum Kind : char { MISSING, NULL, BOOL, INT, FLOAT, STRING, SEQUENCE, MAPPING }

// A cursor: tree + node id. 16 bytes, a value type. id 0 = missing.
struct Node (Printable)
{
	Tree* tree;
	uint id;
}

struct Entry
{
	String key;        // the key text; "" for a null key and for a collection key
	Node key_node;     // the key: its own scalar node, the detached collection, or the alias target
	Node value;
}

// foreach (item : node.items()) / foreach (i, item : node.items()); the cursor makes a full pass O(n).
struct Seq
{
	Node node;
	uint index;
	uint cursor;
}

struct Map
{
	Node node;
	uint index;
	uint cursor;
}

fn sz? Node.to_format(&self, Formatter* f) @dynamic => write_node_json(f, *self);

fn sz Seq.len(&self) @operator(len) => unreachable("card (c)");
fn Node Seq.get_at(&self, sz i) @operator([]) => unreachable("card (c)");
fn sz Map.len(&self) @operator(len) => unreachable("card (c)");
fn Entry Map.get_at(&self, sz i) @operator([]) => unreachable("card (c)");

// ---- the document list ----
fn sz Yaml.len(&self) @operator(len) => unreachable("card (c)");         // documents
fn Node Yaml.doc(&self, sz i) => unreachable("card (c)");                // missing node if i >= len
fn Node Yaml.find(&self, String path) @operator([]) => unreachable("card (c)");   // document 0
fn Node? Yaml.get(&self, String path) => unreachable("card (c)");        // NOT_FOUND
fn Node? Yaml.get_in(&self, sz doc, String path) => unreachable("card (c)");

// ---- navigation ----
// "a.b.0": map keys and sequence indexes separated by '.' (the old rules: an empty segment or an
// index with a leading zero is not found; "" is the node itself; keys that are empty or contain
// '.' and collection keys are not reachable by a path; of duplicate keys the last one wins).
fn Node Node.find(self, String path) @operator([]) => unreachable("card (c)");
fn Node? Node.get(self, String path) => unreachable("card (c)");   // NOT_FOUND
fn Node Node.at(self, sz index) => unreachable("card (c)");        // SEQUENCE item; missing for anything else
fn bool Node.exists(self) => self.id != 0;
fn sz Node.len(self) @operator(len) => unreachable("card (c)");    // children, O(1)
fn Node Node.parent(self) => unreachable("card (c)");              // through an alias: the target's parent
fn Seq Node.items(self) => unreachable("card (c)");
fn Map Node.entries(self) => unreachable("card (c)");
fn String Node.key(self) => unreachable("card (c)");               // of a map entry ("" else)

// ---- kinds and typed reads ----
fn Kind Node.kind(self) => unreachable("card (c)");
fn bool Node.is_null(self) => self.kind() == NULL;
fn bool Node.is_bool(self) => self.kind() == BOOL;
fn bool Node.is_int(self) => self.kind() == INT;
fn bool Node.is_float(self) => self.kind() == FLOAT;
fn bool Node.is_string(self) => self.kind() == STRING;
fn bool Node.is_seq(self) => self.kind() == SEQUENCE;
fn bool Node.is_map(self) => self.kind() == MAPPING;
fn bool Node.is_scalar(self) => self.kind() >= NULL && self.kind() <= STRING;
fn bool Node.is_alias(self) => unreachable("card (c)");

// Faults: NOT_FOUND (missing node), WRONG_KIND, OUT_OF_RANGE.
fn bool? Node.as_bool(self) => unreachable("card (c)");
fn long? Node.as_int(self) => unreachable("card (c)");          // beyond +-2^63: OUT_OF_RANGE
fn int128? Node.as_int128(self) => unreachable("card (c)");     // what decode needs
fn double? Node.as_float(self) => unreachable("card (c)");      // an int is accepted
fn String? Node.as_string(self) => unreachable("card (c)");     // string-kind scalars; a view valid while the Yaml lives
// The default replaces only a MISSING or null node; a wrong kind still faults, so
// `cfg["port"].as_int_or(80)` does not hide `port: "abc"` (unlike `as_int() ?? 80`, which does).
fn long? Node.as_int_or(self, long dflt) => unreachable("card (c)");
fn bool? Node.as_bool_or(self, bool dflt) => unreachable("card (c)");
fn double? Node.as_float_or(self, double dflt) => unreachable("card (c)");
fn String? Node.as_string_or(self, String dflt) => unreachable("card (c)");
fn String Node.text(self) => unreachable("card (c)");           // the raw text of any scalar, "" otherwise

// ---- properties ----
fn String Node.anchor(self) => unreachable("card (c)");
fn String Node.tag_prefix(self) => unreachable("card (c)");
fn String Node.tag(self) => unreachable("card (c)");            // the suffix; the tag is tag_prefix + tag
fn bool Node.is_tag(self, String full) => unreachable("card (c)");
