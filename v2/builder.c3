// v2 tree builder. Card (b) owns this file.
module yaml2;

import std::math;
import std::io;
import yaml2::parser;

struct NodeResult @private
{
	uint id;
	uint height;
	ulong nodes;
	ulong bytes;
}

fn ulong sat_add(ulong a, ulong b) @inline @private => (ulong::max - a < b) ? ulong::max : a + b;

fn ulong sat_add_sz(ulong a, ulong b) @inline @private
{
	ulong max_val = (ulong)sz::max;
	if (max_val - a < b) return max_val;
	return a + b;
}

fn ulong hash_string(String s, ulong seed) @private
{
	ulong h = seed ^ 14695981039346656037UL;
	foreach (c : s)
	{
		h = (h ^ (ulong)c) * 1099511628211UL;
	}
	return h;
}

struct AnchorSlot @private
{
	String name;
	uint node_id;
}

struct AnchorTable @private
{
	AnchorSlot* slots;
	uint cap;
	uint count;
	uint* active;
	uint active_count;
	uint active_cap;
	ulong seed;
	Allocator allocator;
}

fn void AnchorTable.init(&self, Allocator a, ulong seed)
{
	*self = { .allocator = a, .seed = seed };
}

fn void AnchorTable.free(&self)
{
	if (self.slots) alloc::free(self.allocator, self.slots);
	if (self.active) alloc::free(self.allocator, self.active);
	*self = {};
}

fn void AnchorTable.clear(&self)
{
	for (uint i = 0; i < self.active_count; i++)
	{
		self.slots[self.active[i]] = {};
	}
	self.active_count = 0;
	self.count = 0;
}

fn void? AnchorTable.grow(&self)
{
	uint old_cap = self.cap;
	AnchorSlot* old_slots = self.slots;
	uint new_cap = old_cap ? old_cap * 2 : 64;
	AnchorSlot* new_slots = alloc::alloc_array(self.allocator, AnchorSlot, new_cap).ptr;
	mem::clear((char*)new_slots, AnchorSlot::size * new_cap);

	self.slots = new_slots;
	self.cap = new_cap;
	self.count = 0;
	self.active_count = 0;

	for (uint i = 0; i < old_cap; i++)
	{
		if (old_slots[i].name.len)
		{
			self.insert(old_slots[i].name, old_slots[i].node_id)!;
		}
	}
	if (old_slots) alloc::free(self.allocator, old_slots);
}

fn void? AnchorTable.insert(&self, String name, uint node_id)
{
	if (self.count * 2 >= self.cap) self.grow()!;
	ulong mask = (ulong)self.cap - 1;
	ulong idx = hash_string(name, self.seed) & mask;
	while (self.slots[idx].name.len)
	{
		if (self.slots[idx].name == name)
		{
			self.slots[idx].node_id = node_id;
			return;
		}
		idx = (idx + 1) & mask;
	}
	self.slots[idx] = { .name = name, .node_id = node_id };
	self.count++;
	if (self.active_count == self.active_cap)
	{
		self.active_cap = self.active_cap ? self.active_cap * 2 : 64;
		self.active = alloc::realloc_array(self.allocator, self.active, uint, self.active_cap).ptr;
	}
	self.active[self.active_count++] = (uint)idx;
}

fn uint? AnchorTable.get(&self, String name)
{
	if (!self.count) return NOT_FOUND~;
	ulong mask = (ulong)self.cap - 1;
	ulong idx = hash_string(name, self.seed) & mask;
	while (self.slots[idx].name.len)
	{
		if (self.slots[idx].name == name) return self.slots[idx].node_id;
		idx = (idx + 1) & mask;
	}
	return NOT_FOUND~;
}

struct DupSlot @private
{
	Span key;
	uint node_id;
	ulong hash;
}

struct DupTable @private
{
	DupSlot* slots;
	uint cap;
	uint count;
	uint* active;
	uint active_count;
	uint active_cap;
	ulong seed;
	Allocator allocator;
}

fn void DupTable.init(&self, Allocator a, ulong seed)
{
	*self = { .allocator = a, .seed = seed };
}

fn void DupTable.free(&self)
{
	if (self.slots) alloc::free(self.allocator, self.slots);
	if (self.active) alloc::free(self.allocator, self.active);
	*self = {};
}

fn void DupTable.clear(&self)
{
	for (uint i = 0; i < self.active_count; i++)
	{
		self.slots[self.active[i]] = {};
	}
	self.active_count = 0;
	self.count = 0;
}

fn void? DupTable.grow(&self)
{
	uint old_cap = self.cap;
	DupSlot* old_slots = self.slots;
	uint new_cap = old_cap ? old_cap * 2 : 64;
	DupSlot* new_slots = alloc::alloc_array(self.allocator, DupSlot, new_cap).ptr;
	mem::clear((char*)new_slots, DupSlot::size * new_cap);

	self.slots = new_slots;
	self.cap = new_cap;
	self.active_count = 0;
	ulong mask = (ulong)new_cap - 1;

	for (uint i = 0; i < old_cap; i++)
	{
		if (old_slots[i].node_id)
		{
			ulong idx = old_slots[i].hash & mask;
			while (self.slots[idx].node_id != 0)
			{
				idx = (idx + 1) & mask;
			}
			self.slots[idx] = old_slots[i];
			if (self.active_count == self.active_cap)
			{
				self.active_cap = self.active_cap ? self.active_cap * 2 : 64;
				self.active = alloc::realloc_array(self.allocator, self.active, uint, self.active_cap).ptr;
			}
			self.active[self.active_count++] = (uint)idx;
		}
	}
	if (old_slots) alloc::free(self.allocator, old_slots);
}

fn void? DupTable.insert(&self, Parser* parser, Span key, uint node_id, uint* earlier)
{
	if (self.count * 2 >= self.cap) self.grow()!;
	String key_text = parser.text(key);
	ulong h = hash_string(key_text, self.seed);
	ulong mask = (ulong)self.cap - 1;
	ulong idx = h & mask;
	while (self.slots[idx].node_id != 0)
	{
		if (self.slots[idx].hash == h && parser.text(self.slots[idx].key) == key_text)
		{
			if (earlier) *earlier = self.slots[idx].node_id;
			self.slots[idx].node_id = node_id;
			return;
		}
		idx = (idx + 1) & mask;
	}
	self.slots[idx] = { .key = key, .node_id = node_id, .hash = h };
	self.count++;
	if (self.active_count == self.active_cap)
	{
		self.active_cap = self.active_cap ? self.active_cap * 2 : 64;
		self.active = alloc::realloc_array(self.allocator, self.active, uint, self.active_cap).ptr;
	}
	self.active[self.active_count++] = (uint)idx;
	if (earlier) *earlier = 0;
}

struct Builder
{
	Tree* tree;
	Parser* parser;
	Allocator allocator;
	bool verbose;
	int depth;
	AnchorTable anchors;
	DupTable* dup_tables;
	uint dup_cap;
	ulong seed;
}

fn void Builder.init(&self, Tree* tree, Parser* parser, Allocator a, bool verbose)
{
	ulong seed = ((ulong)(uptr)tree) ^ 0x9e3779b97f4a7c15UL;
	*self = {
		.tree = tree,
		.parser = parser,
		.allocator = a,
		.verbose = verbose,
		.seed = seed,
	};
	self.anchors.init(a, seed);
}

fn void Builder.free(&self)
{
	self.anchors.free();
	if (self.dup_tables)
	{
		for (uint i = 0; i < self.dup_cap; i++)
		{
			self.dup_tables[i].free();
		}
		alloc::free(self.allocator, self.dup_tables);
	}
	*self = {};
}

fn DupTable* Builder.get_dup_table(&self, uint map_depth)
{
	if (map_depth >= self.dup_cap)
	{
		uint new_cap = self.dup_cap ? self.dup_cap * 2 : 8;
		while (new_cap <= map_depth) new_cap *= 2;
		self.dup_tables = alloc::realloc_array(self.allocator, self.dup_tables, DupTable, new_cap).ptr;
		for (uint i = self.dup_cap; i < new_cap; i++)
		{
			self.dup_tables[i] = {};
			self.dup_tables[i].init(self.allocator, self.seed);
		}
		self.dup_cap = new_cap;
	}
	return &self.dup_tables[map_depth];
}

fn void Builder.check_duplicate_key(&self, uint map_depth, uint map_id, uint new_entry_id, Span key_span, uint entry_count)
{
	if (entry_count <= 8)
	{
		String key = self.parser.text(key_span);
		uint child = self.tree.nodes[map_id].first;
		while (child != 0)
		{
			NodeData* nd = &self.tree.nodes[child];
			if ((nd.flags & F_SHADOWED) == 0 && (nd.flags & F_KEY_NODE) == 0)
			{
				String ktext = self.parser.text(nd.key);
				if (ktext == key)
				{
					self.tree.shadow(child);
					break;
				}
			}
			child = nd.next;
		}
	}
	else
	{
		DupTable* dt = self.get_dup_table(map_depth);
		if (dt.count == 0)
		{
			uint child = self.tree.nodes[map_id].first;
			while (child != 0)
			{
				NodeData* nd = &self.tree.nodes[child];
				if ((nd.flags & F_SHADOWED) == 0 && (nd.flags & F_KEY_NODE) == 0)
				{
					dt.insert(self.parser, nd.key, child, null)!!;
				}
				child = nd.next;
			}
		}
		uint earlier = 0;
		dt.insert(self.parser, key_span, new_entry_id, &earlier)!!;
		if (earlier)
		{
			self.tree.shadow(earlier);
		}
	}
}

fn NodeResult? Builder.build_node(&self, Event e, uint parent, uint prev, Span key_span, char flags = 0)
{
	switch (e.type)
	{
		case SCALAR:
			String v = self.parser.text(e.value);
			String pfx = self.parser.text(e.tag_prefix);
			String sfx = self.parser.text(e.tag);
			Schema? schema_res = resolve_scalar(v, e.style, pfx, sfx);
			if (catch schema_res)
			{
				return self.parser.error(e.start, "the value does not match its tag", INVALID_INPUT_FORMAT)~;
			}
			Schema schema = schema_res;

			uint id = self.tree.new_node(SCALAR, style: e.style, schema: schema, flags: flags, key: key_span, val: e.value);
			if (e.anchor.len || e.tag.len || e.tag_prefix.len)
			{
				Props* p = self.tree.props_of(id);
				p.anchor = e.anchor;
				p.tag = e.tag;
				p.tag_prefix = e.tag_prefix;
				p.height = 0;
				if (e.anchor.len)
				{
					p.weight = self.tree.new_weight(1, (ulong)e.value.len);
				}
			}
			if (e.anchor.len)
			{
				self.anchors.insert(self.parser.text(e.anchor), id)!;
			}
			return (NodeResult){ id, 0, 1, (ulong)e.value.len };

		case ALIAS:
			uint? target = self.anchors.get(self.parser.text(e.anchor));
			if (catch target) return self.parser.error(e.start, "undefined alias", UNDEFINED_ALIAS)~;

			uint tid = target;
			NodeData* td = &self.tree.nodes[tid];

			uint target_height = 0;
			Weight target_weight = { 1, 0 };
			if (td.props)
			{
				Props* tp = &self.tree.props[td.props];
				target_height = tp.height;
				if (tp.weight) target_weight = self.tree.weights[tp.weight];
			}
			if (self.depth + (int)target_height > parser::MAX_DEPTH) return parser::LIMIT_EXCEEDED~;

			ulong next_nodes = sat_add_sz((ulong)self.tree.budget.alias_nodes, target_weight.nodes);
			ulong next_bytes = sat_add_sz((ulong)self.tree.budget.alias_bytes, target_weight.bytes);
			self.tree.budget.alias_nodes = (sz)next_nodes;
			self.tree.budget.alias_bytes = (sz)next_bytes;
			if ((ulong)self.tree.budget.alias_nodes > (ulong)parser::MAX_ALIAS_NODES || (ulong)self.tree.budget.alias_bytes > (ulong)parser::MAX_ALIAS_BYTES)
			{
				return parser::LIMIT_EXCEEDED~;
			}

			if (td.kind == SCALAR)
			{
				uint id = self.tree.new_node(SCALAR, style: td.style, schema: td.schema, flags: flags | F_ALIAS, key: key_span, val: td.val);
				return (NodeResult){ id, 0, target_weight.nodes, target_weight.bytes };
			}
			else
			{
				uint id = self.tree.new_node(td.kind, style: td.style, schema: STR, flags: flags | F_ALIAS, key: key_span);
				self.tree.nodes[id].first = tid;
				self.tree.nodes[id].val.len = td.val.len;
				return (NodeResult){ id, target_height, target_weight.nodes, target_weight.bytes };
			}

		case SEQUENCE_START:
			if (++self.depth > parser::MAX_DEPTH) return parser::LIMIT_EXCEEDED~;
			uint id = self.tree.new_node(SEQ, flags: flags | (e.explicit ? F_EXPLICIT : 0), key: key_span);
			uint child_prev = 0;
			uint max_child_height = 0;
			ulong sum_nodes = 0;
			ulong sum_bytes = 0;

			while (true)
			{
				Event child_ev = self.parser.next()!;
				if (child_ev.type == SEQUENCE_END) break;
				NodeResult res = self.build_node(child_ev, id, child_prev, (Span){}, 0)!;
				self.tree.append_after(id, child_prev, res.id);
				child_prev = res.id;
				if (res.height > max_child_height) max_child_height = res.height;
				sum_nodes = sat_add(sum_nodes, res.nodes);
				sum_bytes = sat_add(sum_bytes, res.bytes);
			}
			self.depth--;

			uint seq_height = max_child_height + 1;
			ulong seq_nodes = sat_add(1, sum_nodes);
			ulong seq_bytes = sum_bytes;

			if (e.anchor.len || e.tag.len || e.tag_prefix.len)
			{
				Props* p = self.tree.props_of(id);
				p.anchor = e.anchor;
				p.tag = e.tag;
				p.tag_prefix = e.tag_prefix;
				p.height = seq_height;
				if (e.anchor.len)
				{
					p.weight = self.tree.new_weight(seq_nodes, seq_bytes);
				}
			}
			if (e.anchor.len)
			{
				self.anchors.insert(self.parser.text(e.anchor), id)!;
			}
			return (NodeResult){ id, seq_height, seq_nodes, seq_bytes };

		case MAPPING_START:
			if (++self.depth > parser::MAX_DEPTH) return parser::LIMIT_EXCEEDED~;
			uint map_depth = (uint)self.depth;
			defer
			{
				if (map_depth < self.dup_cap) self.dup_tables[map_depth].clear();
			}

			uint id = self.tree.new_node(MAP, flags: flags | (e.explicit ? F_EXPLICIT : 0), key: key_span);
			uint child_prev = 0;
			uint max_child_height = 0;
			ulong sum_nodes = 0;
			ulong sum_bytes = 0;
			uint entry_count = 0;

			while (true)
			{
				Event key_ev = self.parser.next()!;
				if (key_ev.type == MAPPING_END) break;

				if (key_ev.type == SCALAR)
				{
					String ktext = self.parser.text(key_ev.value);
					String kpfx = self.parser.text(key_ev.tag_prefix);
					String ksfx = self.parser.text(key_ev.tag);
					Schema? kschema_res = resolve_scalar(ktext, key_ev.style, kpfx, ksfx);
					if (catch kschema_res)
					{
						return self.parser.error(key_ev.start, "the value does not match its tag", INVALID_INPUT_FORMAT)~;
					}
					Schema kschema = kschema_res;
					Span kspan = (kschema == Schema.NULL) ? (Span){} : key_ev.value;

					if (key_ev.anchor.len)
					{
						uint knode = self.tree.new_node(SCALAR, style: key_ev.style, schema: kschema, flags: 0, val: key_ev.value);
						Props* kp = self.tree.props_of(knode);
						kp.anchor = key_ev.anchor;
						kp.tag = key_ev.tag;
						kp.tag_prefix = key_ev.tag_prefix;
						kp.weight = self.tree.new_weight(1, (ulong)key_ev.value.len);
						self.anchors.insert(self.parser.text(key_ev.anchor), knode)!;
					}

					Event val_ev = self.parser.next()!;
					NodeResult vres = self.build_node(val_ev, id, child_prev, kspan, F_KEY)!;
					uint val_id = vres.id;

					if (key_ev.anchor.len || key_ev.tag.len || key_ev.tag_prefix.len)
					{
						Props* p = self.tree.props_of(val_id);
						p.key_anchor = key_ev.anchor;
						p.key_tag = key_ev.tag;
						p.key_tag_prefix = key_ev.tag_prefix;
					}

					entry_count++;
					self.check_duplicate_key(map_depth, id, val_id, kspan, entry_count);

					self.tree.append_after(id, child_prev, val_id);
					child_prev = val_id;

					if (vres.height > max_child_height) max_child_height = vres.height;
					sum_nodes = sat_add(sum_nodes, vres.nodes);
					sum_bytes = sat_add(sum_bytes, sat_add((ulong)kspan.len, vres.bytes));
				}
				else if (key_ev.type == ALIAS)
				{
					uint? target = self.anchors.get(self.parser.text(key_ev.anchor));
					if (catch target) return self.parser.error(key_ev.start, "undefined alias", UNDEFINED_ALIAS)~;
					uint tid = target;
					NodeData* td = &self.tree.nodes[tid];

					uint target_height = 0;
					Weight target_weight = { 1, 0 };
					if (td.props)
					{
						Props* tp = &self.tree.props[td.props];
						target_height = tp.height;
						if (tp.weight) target_weight = self.tree.weights[tp.weight];
					}
					if (self.depth + (int)target_height > parser::MAX_DEPTH) return parser::LIMIT_EXCEEDED~;

					ulong next_nodes = sat_add_sz((ulong)self.tree.budget.alias_nodes, target_weight.nodes);
					ulong next_bytes = sat_add_sz((ulong)self.tree.budget.alias_bytes, target_weight.bytes);
					self.tree.budget.alias_nodes = (sz)next_nodes;
					self.tree.budget.alias_bytes = (sz)next_bytes;
					if ((ulong)self.tree.budget.alias_nodes > (ulong)parser::MAX_ALIAS_NODES || (ulong)self.tree.budget.alias_bytes > (ulong)parser::MAX_ALIAS_BYTES)
					{
						return parser::LIMIT_EXCEEDED~;
					}

					if (td.kind == SCALAR)
					{
						Span kspan = (td.schema == Schema.NULL) ? (Span){} : td.val;

						Event val_ev = self.parser.next()!;
						NodeResult vres = self.build_node(val_ev, id, child_prev, kspan, F_KEY)!;
						uint val_id = vres.id;

						entry_count++;
						self.check_duplicate_key(map_depth, id, val_id, kspan, entry_count);

						self.tree.append_after(id, child_prev, val_id);
						child_prev = val_id;

						if (vres.height > max_child_height) max_child_height = vres.height;
						sum_nodes = sat_add(sum_nodes, vres.nodes);
						sum_bytes = sat_add(sum_bytes, sat_add((ulong)kspan.len, vres.bytes));
					}
					else
					{
						Event val_ev = self.parser.next()!;
						Span kspan = { tid, 0 };
						NodeResult vres = self.build_node(val_ev, id, child_prev, kspan, F_KEY | F_KEY_NODE)!;
						uint val_id = vres.id;

						entry_count++;
						self.tree.append_after(id, child_prev, val_id);
						child_prev = val_id;

						uint combined_height = target_height > vres.height ? target_height : vres.height;
						if (combined_height > max_child_height) max_child_height = combined_height;
						sum_nodes = sat_add(sat_add(sum_nodes, target_weight.nodes), vres.nodes);
						sum_bytes = sat_add(sat_add(sum_bytes, target_weight.bytes), vres.bytes);
					}
				}
				else
				{
					// Complex collection key (SEQUENCE_START or MAPPING_START)
					NodeResult kres = self.build_node(key_ev, 0, 0, (Span){}, 0)!;
					uint key_node_id = kres.id;

					Event val_ev = self.parser.next()!;
					Span kspan = { key_node_id, 0 };
					NodeResult vres = self.build_node(val_ev, id, child_prev, kspan, F_KEY | F_KEY_NODE)!;
					uint val_id = vres.id;

					entry_count++;
					self.tree.append_after(id, child_prev, val_id);
					child_prev = val_id;

					uint combined_height = kres.height > vres.height ? kres.height : vres.height;
					if (combined_height > max_child_height) max_child_height = combined_height;
					sum_nodes = sat_add(sat_add(sum_nodes, kres.nodes), vres.nodes);
					sum_bytes = sat_add(sat_add(sum_bytes, kres.bytes), vres.bytes);
				}
			}
			self.depth--;

			uint map_height = max_child_height + 1;
			ulong map_nodes = sat_add(1, sum_nodes);
			ulong map_bytes = sum_bytes;

			if (e.anchor.len || e.tag.len || e.tag_prefix.len)
			{
				Props* p = self.tree.props_of(id);
				p.anchor = e.anchor;
				p.tag = e.tag;
				p.tag_prefix = e.tag_prefix;
				p.height = map_height;
				if (e.anchor.len)
				{
					p.weight = self.tree.new_weight(map_nodes, map_bytes);
				}
			}
			if (e.anchor.len)
			{
				self.anchors.insert(self.parser.text(e.anchor), id)!;
			}
			return (NodeResult){ id, map_height, map_nodes, map_bytes };

		default:
			return parser::SYNTAX_ERROR~;
	}
}

fn void? Builder.build_stream(&self)
{
	bool in_doc = false;
	bool doc_has_node = false;
	bool doc_explicit = false;
	uint doc_prev = 0;

	while (true)
	{
		Event e = self.parser.next()!;
		switch (e.type)
		{
			case STREAM_END:
				return;
			case DOCUMENT_START:
				in_doc = true;
				doc_has_node = false;
				doc_explicit = e.explicit;
				self.anchors.clear();
			case DOCUMENT_END:
				if (in_doc && !doc_has_node)
				{
					uint doc_id = self.tree.new_node(SCALAR, style: PLAIN, schema: NULL, flags: doc_explicit ? F_EXPLICIT : 0);
					self.tree.append_after(0, doc_prev, doc_id);
					doc_prev = doc_id;
				}
				in_doc = false;
				doc_explicit = false;
				self.anchors.clear();
			case SCALAR:
			case SEQUENCE_START:
			case MAPPING_START:
			case ALIAS:
				in_doc = true;
				doc_has_node = true;
				char doc_flags = doc_explicit ? F_EXPLICIT : 0;
				NodeResult res = self.build_node(e, 0, 0, (Span){}, doc_flags)!;
				self.tree.append_after(0, doc_prev, res.id);
				doc_prev = res.id;
			default:
				break;
		}
	}
}
