// v2 contract. Card (b) owns this file. The types and the primitives below are FROZEN (cards
// (c), (d) and the test fixtures build hand-made trees with them); (b) may add to the file.
// The structs are public so that test modules can see them; users never touch them.
module yaml2;

import yaml2::parser;

enum NodeKind : char { STREAM, MAP, SEQ, SCALAR }   // an alias is a flag, not a kind
enum Schema : char { NULL, BOOL, INT, FLOAT, STR }  // scalars: core schema type, resolved by the builder

const char F_KEY = 0x01;       // the node is a map entry: `key` is set
const char F_KEY_NODE = 0x02;  // the key is a node: key.off = its id (a detached collection, or an alias target)
const char F_ALIAS = 0x04;     // alias: a scalar copies the target's text/style/schema; a collection has first = target id
const char F_SHADOWED = 0x08;  // a later entry of the same map has this key: skipped by every reader
const char F_EXPLICIT = 0x10;  // a flow collection ("[]" / "{}"), or a document with "---"

const uint NO_NODE = 0;        // node 0 is the stream root; it is never exposed, so 0 also means "missing"

// 36 bytes. Node 0 = STREAM; its children are the documents' root nodes (an empty document is a
// null scalar). Children are linked first/next; the order is the source order.
struct NodeData
{
	NodeKind kind;
	ScalarStyle style;
	Schema schema;
	char flags;
	uint parent;        // of a node reached through an alias: the TARGET's parent
	uint first;         // first child; alias to a collection: the target
	uint next;          // next sibling
	Span key;           // scalar key text; a null key (~, empty) is canonicalised to the EMPTY span
	Span val;           // SCALAR: text. MAP/SEQ: val.len = number of live (not shadowed) children
	uint props;         // 0, or index into Tree.props
}

// Anchors and tags, for the nodes that have them. 56 bytes.
struct Props
{
	Span anchor, key_anchor;
	Span tag, key_tag;               // suffix
	Span tag_prefix, key_tag_prefix; // prefix; tag text = prefix + suffix, never concatenated
	uint height;                     // depth of the subtree below, aliases followed (MAX_DEPTH check)
	uint weight;                     // 0, or index into Tree.weights (anchored nodes only)
}

// What an anchored node expands to when aliased (saturating); drives the alias budgets.
struct Weight
{
	ulong nodes;
	ulong bytes;
}

struct Budget
{
	sz alias_nodes;
	sz alias_bytes;
}

// Lives on the heap: Yaml and Node stay valid when copied or returned by value.
struct Tree
{
	Allocator allocator;
	char[] input;       // the text plain spans refer to (Parser.input()); input.ptr is the start of the allocation
	bool owns_input;    // free `input` with `allocator`
	Arena arena;        // spilled text
	NodeData* nodes;
	uint len, cap;
	Props* props;
	uint props_len, props_cap;
	Weight* weights;
	uint weights_len, weights_cap;
	uint ndocs;
	Budget budget;
	ulong hops;         // sibling links followed by navigation: lets tests prove O(n) iteration
}

// A new tree with only the stream root. `input` (may be empty) is the text plain spans refer to;
// the tree owns it iff `owns_input`. Out of memory panics, as in std.
fn Tree* new_tree(Allocator allocator, char[] input = {}, bool owns_input = false)
{
	Tree* t = alloc::new(allocator, Tree);
	*t = { .allocator = allocator, .input = input, .owns_input = owns_input };
	t.arena.init(allocator);
	t.new_node(STREAM);   // id 0
	return t;
}

// Frees everything including the tree itself.
fn void Tree.free(&self)
{
	Allocator a = self.allocator;
	if (self.nodes) alloc::free(a, self.nodes);
	if (self.props) alloc::free(a, self.props);
	if (self.weights) alloc::free(a, self.weights);
	if (self.owns_input && self.input.len) alloc::free(a, self.input.ptr);
	self.arena.free();
	alloc::free(a, self);
}

fn String Tree.text(&self, Span s) @inline => parser::resolve(self.input, &self.arena, s);

// Copies `s` into the arena and returns its span (for hand-made trees and for builders).
fn Span Tree.put(&self, String s) => self.arena.put(s)!!;

fn NodeData* Tree.node(&self, uint id) @inline => &self.nodes[id];

// A detached node (not linked anywhere); returns its id. Ids grow monotonically.
fn uint Tree.new_node(&self, NodeKind kind, ScalarStyle style = PLAIN, Schema schema = STR, char flags = 0, Span key = {}, Span val = {})
{
	if (self.len == self.cap)
	{
		self.cap = self.cap ? self.cap * 2 : 64;
		self.nodes = alloc::realloc_array(self.allocator, self.nodes, NodeData, self.cap).ptr;
	}
	self.nodes[self.len] = { .kind = kind, .style = style, .schema = schema, .flags = flags, .key = key, .val = val };
	return self.len++;
}

// Links `child` after `prev` (0: as the first child) under `parent`: O(1). Sets child.parent and
// counts the child in parent.val.len (MAP/SEQ) or ndocs (STREAM). The caller keeps `prev`.
fn void Tree.append_after(&self, uint parent, uint prev, uint child)
{
	self.nodes[child].parent = parent;
	if (prev)
	{
		self.nodes[prev].next = child;
	}
	else
	{
		self.nodes[parent].first = child;
	}
	if (parent == 0)
	{
		self.ndocs++;
	}
	else
	{
		self.nodes[parent].val.len++;
	}
}

// Links `child` as the last child of `parent`: O(children), for hand-made trees.
fn void Tree.append(&self, uint parent, uint child)
{
	uint last = self.nodes[parent].first;
	while (last && self.nodes[last].next) last = self.nodes[last].next;
	self.append_after(parent, last, child);
}

// Hand-made tree helpers: a scalar / collection added as the last child of `parent`, with the text
// copied into the arena. `key` is "" for a sequence item or a document root.
fn uint Tree.add_scalar(&self, uint parent, String key, String text, Schema schema = STR, ScalarStyle style = PLAIN)
{
	uint id = self.new_node(SCALAR, style, schema, self.entry_flags(parent), self.key_span(parent, key), self.put(text));
	self.append(parent, id);
	return id;
}

fn uint Tree.add_collection(&self, uint parent, String key, NodeKind kind)
{
	uint id = self.new_node(kind, flags: self.entry_flags(parent), key: self.key_span(parent, key));
	self.append(parent, id);
	return id;
}

fn char Tree.entry_flags(&self, uint parent) => self.nodes[parent].kind == MAP ? F_KEY : 0;
fn Span Tree.key_span(&self, uint parent, String key) => self.nodes[parent].kind == MAP ? self.put(key) : (Span){};

// The Props of node `id`, created on first use.
fn Props* Tree.props_of(&self, uint id)
{
	if (!self.nodes[id].props)
	{
		if (self.props_len + 1 > self.props_cap)   // index 0 = none, so the first Props is at 1
		{
			self.props_cap = self.props_cap ? self.props_cap * 2 : 16;
			self.props = alloc::realloc_array(self.allocator, self.props, Props, self.props_cap).ptr;
		}
		if (!self.props_len) self.props_len = 1;
		self.props[self.props_len] = {};
		self.nodes[id].props = self.props_len++;
	}
	return &self.props[self.nodes[id].props];
}

// Marks entry `id` as overridden by a later one with the same key: readers skip it, the parent's
// live count drops. The node stays (aliases may point to it).
fn void Tree.shadow(&self, uint id)
{
	self.nodes[id].flags |= F_SHADOWED;
	self.nodes[self.nodes[id].parent].val.len--;
}
