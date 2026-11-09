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

const uint KEY_NODE_BIT = 0x8000_0000;

fn bool Node.is_key_proxy(self) @inline => (self.id & KEY_NODE_BIT) != 0;
fn uint Node.raw_id(self) @inline => self.id & ~KEY_NODE_BIT;

fn uint Node.resolve_id(self)
{
	if (!self.exists() || self.is_key_proxy()) return self.id;
	uint nid = self.id;
	while (nid < self.tree.len && (self.tree.nodes[nid].flags & F_ALIAS) != 0 && (self.tree.nodes[nid].kind == MAP || self.tree.nodes[nid].kind == SEQ))
	{
		nid = self.tree.nodes[nid].first;
	}
	return nid;
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

fn sz Seq.len(&self) @operator(len) => self.node.len();

fn Node Seq.get_at(&self, sz i) @operator([])
{
	if (!self.node.exists() || !self.node.is_seq()) return (Node){};
	uint target = self.node.resolve_id();
	uint first = self.node.tree.nodes[target].first;
	if (!first) return (Node){};

	if (self.cursor == 0 || i < (sz)self.index)
	{
		self.cursor = first;
		self.index = 0;
	}
	while ((sz)self.index < i && self.cursor != 0)
	{
		self.cursor = self.node.tree.nodes[self.cursor].next;
		$if env::TESTING: self.node.tree.hops++; $endif
		self.index++;
	}
	if (self.cursor == 0) return (Node){};
	return (Node){ self.node.tree, self.cursor };
}

fn sz Map.len(&self) @operator(len) => self.node.len();

fn Entry Map.get_at(&self, sz i) @operator([])
{
	if (!self.node.exists() || !self.node.is_map()) return (Entry){};
	uint target = self.node.resolve_id();
	uint first = self.node.tree.nodes[target].first;
	if (!first) return (Entry){};

	if (self.cursor == 0 || i < (sz)self.index)
	{
		self.cursor = first;
		while (self.cursor != 0 && (self.node.tree.nodes[self.cursor].flags & F_SHADOWED) != 0)
		{
			self.cursor = self.node.tree.nodes[self.cursor].next;
			$if env::TESTING: self.node.tree.hops++; $endif
		}
		self.index = 0;
	}
	while ((sz)self.index < i && self.cursor != 0)
	{
		self.cursor = self.node.tree.nodes[self.cursor].next;
		$if env::TESTING: self.node.tree.hops++; $endif
		while (self.cursor != 0 && (self.node.tree.nodes[self.cursor].flags & F_SHADOWED) != 0)
		{
			self.cursor = self.node.tree.nodes[self.cursor].next;
			$if env::TESTING: self.node.tree.hops++; $endif
		}
		self.index++;
	}
	if (self.cursor == 0) return (Entry){};
	uint cid = self.cursor;
	NodeData* nd = &self.node.tree.nodes[cid];
	Entry e;
	e.value = (Node){ self.node.tree, cid };
	if ((nd.flags & F_KEY_NODE) != 0)
	{
		e.key = "";
		e.key_node = (Node){ self.node.tree, nd.key.off };
	}
	else
	{
		e.key = self.node.tree.text(nd.key);
		e.key_node = (Node){ self.node.tree, KEY_NODE_BIT | cid };
	}
	return e;
}

// ---- the document list ----
struct Docs
{
	Tree* tree;
	uint index;
	uint cursor;
}

fn sz Docs.len(&self) @operator(len) => self.tree ? (sz)self.tree.ndocs : 0;

fn Node Docs.get_at(&self, sz i) @operator([])
{
	if (!self.tree || i >= (sz)self.tree.ndocs) return (Node){};
	uint first = self.tree.nodes[0].first;
	if (!first) return (Node){};

	if (self.cursor == 0 || i < (sz)self.index)
	{
		self.cursor = first;
		self.index = 0;
	}
	while ((sz)self.index < i && self.cursor != 0)
	{
		self.cursor = self.tree.nodes[self.cursor].next;
		$if env::TESTING: self.tree.hops++; $endif
		self.index++;
	}
	if (self.cursor == 0) return (Node){};
	return (Node){ self.tree, self.cursor };
}

fn Docs Yaml.docs(&self) => (Docs){ .tree = self.tree };

fn sz Yaml.len(&self) @operator(len) => self.tree ? (sz)self.tree.ndocs : 0;

fn Node Yaml.doc(&self, sz i)
{
	if (!self.tree || i >= (sz)self.tree.ndocs) return (Node){};
	uint child = self.tree.nodes[0].first;
	sz cur = 0;
	if (self.tree.last_doc_id != 0 && i >= (sz)self.tree.last_doc_idx)
	{
		child = self.tree.last_doc_id;
		cur = (sz)self.tree.last_doc_idx;
	}
	while (child != 0 && cur < i)
	{
		child = self.tree.nodes[child].next;
		$if env::TESTING: self.tree.hops++; $endif
		cur++;
	}
	if (child != 0)
	{
		self.tree.last_doc_idx = (uint)cur;
		self.tree.last_doc_id = child;
		return (Node){ self.tree, child };
	}
	return (Node){};
}

fn Node Yaml.find(&self, String path) @operator([]) => self.doc(0).find(path);
fn Node? Yaml.get(&self, String path) => self.get_in(0, path);

fn Node? Yaml.get_in(&self, sz doc, String path)
{
	Node d = self.doc(doc);
	if (!d.exists()) return NOT_FOUND~;
	return d.get(path);
}

// ---- navigation ----
fn Node Node.find(self, String path) @operator([])
{
	Node? res = self.get(path);
	if (catch res) return (Node){};
	return res;
}

fn Node? Node.get(self, String path)
{
	if (!self.exists()) return NOT_FOUND~;
	if (!path.len) return self;
	if (path.starts_with(".") || path.ends_with(".")) return NOT_FOUND~;

	Node curr = self;
	sz pos = 0;
	while (pos < path.len)
	{
		sz dot = pos;
		while (dot < path.len && path[dot] != '.') dot++;
		if (dot == pos) return NOT_FOUND~;
		String seg = path[pos..dot - 1];
		pos = dot + 1;

		if (!curr.exists()) return NOT_FOUND~;
		Kind k = curr.kind();
		if (k == SEQUENCE)
		{
			if (!seg.len) return NOT_FOUND~;
			if (seg.len > 1 && seg[0] == '0') return NOT_FOUND~;
			sz idx_len = 0;
			if (!digits(seg, &idx_len, 10) || idx_len != seg.len) return NOT_FOUND~;
			ulong? idx = seg.to_ulong();
			if (catch idx) return NOT_FOUND~;
			curr = curr.at((sz)idx);
			if (!curr.exists()) return NOT_FOUND~;
		}
		else if (k == MAPPING)
		{
			uint target = curr.resolve_id();
			uint child = curr.tree.nodes[target].first;
			uint found = 0;
			while (child != 0)
			{
				NodeData* nd = &curr.tree.nodes[child];
				if ((nd.flags & F_SHADOWED) == 0 && (nd.flags & F_KEY_NODE) == 0)
				{
					String ktext = curr.tree.text(nd.key);
					if (ktext == seg)
					{
						found = child;
						break;
					}
				}
				child = nd.next;
			}
			if (!found) return NOT_FOUND~;
			curr = (Node){ curr.tree, found };
		}
		else
		{
			return NOT_FOUND~;
		}
	}
	return curr;
}

fn Node Node.at(self, sz index)
{
	if (!self.exists() || !self.is_seq()) return (Node){};
	uint target = self.resolve_id();
	uint child = self.tree.nodes[target].first;
	sz cur = 0;
	while (child != 0)
	{
		if (cur == index) return (Node){ self.tree, child };
		$if env::TESTING: self.tree.hops++; $endif
		child = self.tree.nodes[child].next;
		cur++;
	}
	return (Node){};
}

fn bool Node.exists(self) => self.id != 0 && self.tree != null;

fn sz Node.len(self) @operator(len)
{
	if (!self.exists()) return 0;
	if (self.is_key_proxy()) return 0;
	uint nid = self.resolve_id();
	NodeData* nd = &self.tree.nodes[nid];
	switch (nd.kind)
	{
		case MAP:
		case SEQ:
			return (sz)nd.val.len;
		case STREAM:
			return (sz)self.tree.ndocs;
		default:
			return 0;
	}
}

fn Node Node.parent(self)
{
	if (!self.exists()) return (Node){};
	uint rid = self.raw_id();
	uint pid = self.tree.nodes[rid].parent;
	return (Node){ self.tree, pid };
}

fn Seq Node.items(self) => (Seq){ .node = self, .index = 0, .cursor = 0 };
fn Map Node.entries(self) => (Map){ .node = self, .index = 0, .cursor = 0 };

fn String Node.key(self)
{
	if (!self.exists()) return "";
	if (self.is_key_proxy())
	{
		return self.tree.text(self.tree.nodes[self.raw_id()].key);
	}
	uint rid = self.raw_id();
	NodeData* nd = &self.tree.nodes[rid];
	if ((nd.flags & F_KEY) != 0)
	{
		if ((nd.flags & F_KEY_NODE) != 0) return "";
		return self.tree.text(nd.key);
	}
	return "";
}

// ---- kinds and typed reads ----
fn Kind Node.kind(self)
{
	if (!self.exists()) return MISSING;
	if (self.is_key_proxy())
	{
		NodeData* nd = &self.tree.nodes[self.raw_id()];
		return nd.key.is_empty() ? NULL : STRING;
	}
	uint nid = self.resolve_id();
	NodeData* nd = &self.tree.nodes[nid];
	switch (nd.kind)
	{
		case MAP: return MAPPING;
		case SEQ: return SEQUENCE;
		case SCALAR:
			switch (nd.schema)
			{
				case NULL: return NULL;
				case BOOL: return BOOL;
				case INT: return INT;
				case FLOAT: return FLOAT;
				case STR: return STRING;
			}
		default: return MISSING;
	}
}

fn bool Node.is_null(self) => self.kind() == NULL;
fn bool Node.is_bool(self) => self.kind() == BOOL;
fn bool Node.is_int(self) => self.kind() == INT;
fn bool Node.is_float(self) => self.kind() == FLOAT;
fn bool Node.is_string(self) => self.kind() == STRING;
fn bool Node.is_seq(self) => self.kind() == SEQUENCE;
fn bool Node.is_map(self) => self.kind() == MAPPING;
fn bool Node.is_scalar(self) => self.kind() >= NULL && self.kind() <= STRING;

fn bool Node.is_alias(self)
{
	if (!self.exists() || self.is_key_proxy()) return false;
	return (self.tree.nodes[self.raw_id()].flags & F_ALIAS) != 0;
}

// Faults: NOT_FOUND (missing node), WRONG_KIND, OUT_OF_RANGE.
fn bool? Node.as_bool(self)
{
	if (!self.exists()) return NOT_FOUND~;
	if (!self.is_bool()) return WRONG_KIND~;
	String t = self.text();
	return t == "true" || t == "True" || t == "TRUE";
}

fn long? Node.as_int(self)
{
	int128? v = self.as_int128();
	if (catch err = v) return err~;
	if (v < (int128)long::min || v > (int128)long::max) return OUT_OF_RANGE~;
	return (long)v;
}

fn int128? Node.as_int128(self)
{
	if (!self.exists()) return NOT_FOUND~;
	if (!self.is_int()) return WRONG_KIND~;
	int128? val = int_of(self.text());
	if (catch val) return WRONG_KIND~;
	return val;
}

fn double? Node.as_float(self)
{
	if (!self.exists()) return NOT_FOUND~;
	Kind k = self.kind();
	if (k == INT)
	{
		int128? vi = int_of(self.text());
		if (catch vi) return WRONG_KIND~;
		return (double)vi;
	}
	if (k != FLOAT) return WRONG_KIND~;
	double? vf = float_of(self.text());
	if (catch vf) return WRONG_KIND~;
	return vf;
}

fn String? Node.as_string(self)
{
	if (!self.exists()) return NOT_FOUND~;
	if (!self.is_string()) return WRONG_KIND~;
	return self.text();
}

fn long? Node.as_int_or(self, long dflt)
{
	if (!self.exists() || self.is_null()) return dflt;
	return self.as_int();
}

fn bool? Node.as_bool_or(self, bool dflt)
{
	if (!self.exists() || self.is_null()) return dflt;
	return self.as_bool();
}

fn double? Node.as_float_or(self, double dflt)
{
	if (!self.exists() || self.is_null()) return dflt;
	return self.as_float();
}

fn String? Node.as_string_or(self, String dflt)
{
	if (!self.exists() || self.is_null()) return dflt;
	return self.as_string();
}

fn String Node.text(self)
{
	if (!self.exists()) return "";
	if (self.is_key_proxy())
	{
		return self.tree.text(self.tree.nodes[self.raw_id()].key);
	}
	if (!self.is_scalar()) return "";
	return self.tree.text(self.tree.nodes[self.raw_id()].val);
}

// ---- properties ----
fn String Node.anchor(self)
{
	if (!self.exists()) return "";
	uint rid = self.raw_id();
	uint pidx = self.tree.nodes[rid].props;
	if (!pidx) return "";
	if (self.is_key_proxy()) return self.tree.text(self.tree.props[pidx].key_anchor);
	return self.tree.text(self.tree.props[pidx].anchor);
}

fn String Node.tag_prefix(self)
{
	if (!self.exists()) return "";
	uint rid = self.raw_id();
	uint pidx = self.tree.nodes[rid].props;
	if (!pidx) return "";
	if (self.is_key_proxy()) return self.tree.text(self.tree.props[pidx].key_tag_prefix);
	return self.tree.text(self.tree.props[pidx].tag_prefix);
}

fn String Node.tag(self)
{
	if (!self.exists()) return "";
	uint rid = self.raw_id();
	uint pidx = self.tree.nodes[rid].props;
	if (!pidx) return "";
	if (self.is_key_proxy()) return self.tree.text(self.tree.props[pidx].key_tag);
	return self.tree.text(self.tree.props[pidx].tag);
}

fn bool Node.is_tag(self, String full)
{
	if (!self.exists()) return false;
	String pre = self.tag_prefix();
	String suf = self.tag();
	if (!pre.len && !suf.len) return false;
	if (full.len != pre.len + suf.len) return false;
	return full.starts_with(pre) && full[pre.len..] == suf;
}
