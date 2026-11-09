module yaml @private;

import std::collections::map, std::collections::list, std::collections::object;
import yaml::parser;

const String TAG_STR = "tag:yaml.org,2002:str";
const String TAG_NULL = "tag:yaml.org,2002:null";
const String TAG_BOOL = "tag:yaml.org,2002:bool";
const String TAG_INT = "tag:yaml.org,2002:int";
const String TAG_FLOAT = "tag:yaml.org,2002:float";

// What alias expansion and collection keys have cost in one from_* call, over all its
// documents: YamlData keeps every document, so the limits apply to the whole stream.
struct Budget
{
	sz alias_nodes;   // nodes created by alias expansion (MAX_ALIAS_NODES)
	sz alias_bytes;   // string and key bytes copied by alias expansion (MAX_ALIAS_BYTES)
	sz key_text;      // bytes of JSON text made for collection keys (MAX_KEY_TEXT)
}

// Events -> Object for one document.
struct Builder
{
	Parser* parser;
	Allocator allocator;
	Budget* budget;
	int depth;        // nesting depth of the current node (MAX_DEPTH)
	HashMap {String, Object*} anchors;   // the anchored nodes (owned by the tree or by `dropped`)
	List {Object*} dropped;              // nodes taken out of the tree: replaced values and key nodes
}

fn Object*? build_document(Parser* parser, Event root, Allocator allocator, Budget* budget)
{
	Builder b = { .parser = parser, .allocator = allocator, .budget = budget };
	b.anchors.tinit();
	b.dropped.tinit();
	defer foreach (o : b.dropped) o.free();   // anchors may point into them until the end
	return b.node(root);
}

fn Object*? Builder.node(&self, Event e)
{
	Object* o = null;
	defer catch if (o) o.free();
	switch (e.type)
	{
		case ALIAS:
			Object*? anchored = self.anchors.get(e.anchor);
			if (catch anchored) return self.parser.error(e.start, "undefined alias", UNDEFINED_ALIAS)~;
			Object*? copy = self.clone(anchored, self.depth);
			if (catch copy) return self.parser.error(e.start, "alias expansion exceeds a size or nesting limit", parser::LIMIT_EXCEEDED)~;
			return copy;
		case SCALAR:
			o = self.scalar(e)!;
		case SEQUENCE_START:
			if (++self.depth > parser::MAX_DEPTH) return self.parser.error(e.start, "nesting depth limit exceeded", parser::LIMIT_EXCEEDED)~;
			o = object::new_array(self.allocator);
			while (true)
			{
				Event item = self.parser.next()!;
				if (item.type == SEQUENCE_END) break;
				o.push_object(self.node(item)!);
			}
			self.depth--;
		case MAPPING_START:
			if (++self.depth > parser::MAX_DEPTH) return self.parser.error(e.start, "nesting depth limit exceeded", parser::LIMIT_EXCEEDED)~;
			o = object::new_obj(self.allocator);
			while (true)
			{
				Event key_event = self.parser.next()!;
				if (key_event.type == MAPPING_END) break;
				String key = self.key(key_event)!;
				Object* value = self.node(self.parser.next()!)!;
				if (o.has_key(key))   // duplicate keys: last wins; keep the old value for aliases
				{
					self.dropped.push(o.get(key)!!);
					o.map.remove(key);
				}
				o.set(key, value);
			}
			self.depth--;
		default:
			return self.parser.error(e.start, "unexpected event", parser::SYNTAX_ERROR)~;
	}
	if (e.anchor.len) self.anchors.set(e.anchor, o);
	return o;
}

// A scalar key is its text (a null key is ""); a collection key is its compact JSON text.
fn String? Builder.key(&self, Event e)
{
	bool plain_key = e.type == SCALAR && !e.tag.len && !e.anchor.len;
	if (plain_key) return e.style == PLAIN && is_null_text(e.value) ? "" : e.value;
	Object* key_node = self.node(e)!;
	self.dropped.push(key_node);   // not freed yet: an alias may refer to it
	if (key_node.is_null()) return "";
	if (e.type == SCALAR) return e.value;
	if (key_node.is_string()) return key_node.s;
	// a nested collection key is escaped again at every level: the text can double per level
	String text = string::tformat("%s", (Json){ key_node });
	self.budget.key_text += text.len;
	if (self.budget.key_text > parser::MAX_KEY_TEXT) return self.parser.error(e.start, "collection keys are too long", parser::LIMIT_EXCEEDED)~;
	return text;
}

// Deep copy for an alias (sharing an Object* would make Object.free free it twice). Every
// created node counts against MAX_ALIAS_NODES, every copied string and key against
// MAX_ALIAS_BYTES; `depth` is the depth of the alias.
fn Object*? Builder.clone(&self, Object* o, int depth)
{
	if (++self.budget.alias_nodes > parser::MAX_ALIAS_NODES) return parser::LIMIT_EXCEEDED~;
	switch
	{
		case o.is_null(): return object::new_null();
		case o.is_bool(): return object::new_bool(o.b);
		case o.is_int(): return object::new_int(self.allocator, o.i);
		case o.is_float(): return object::new_float(self.allocator, o.f);
		case o.is_string():
			self.charge_alias_bytes(o.s.len)!;
			return object::new_string(self.allocator, o.s);
	}
	if (depth + 1 > parser::MAX_DEPTH) return parser::LIMIT_EXCEEDED~;
	if (o.is_array())
	{
		Object* arr = object::new_array(self.allocator);
		defer catch arr.free();
		for (sz i = 0; i < o.get_len(); i++) arr.push_object(self.clone(o.get_at(i), depth + 1)!);
		return arr;
	}
	Object* map = object::new_obj(self.allocator);
	defer catch map.free();
	o.@each_entry(; String key, Object* value)
	{
		self.charge_alias_bytes(key.len)!;
		map.set(key, self.clone(value, depth + 1)!);
	};
	return map;
}

fn void? Builder.charge_alias_bytes(&self, sz len)
{
	self.budget.alias_bytes += len;
	if (self.budget.alias_bytes > parser::MAX_ALIAS_BYTES) return parser::LIMIT_EXCEEDED~;
}

// ---- core schema ---------------------------------------------------------

// Untagged plain scalars are resolved by the core schema; the tags !!str !!null !!bool !!int
// !!float force their type; quoted, block and otherwise tagged scalars are strings.
fn Object*? Builder.scalar(&self, Event e)
{
	String v = e.value;
	bool core = !e.tag.len && e.style == PLAIN;
	if ((core || e.tag == TAG_NULL) && is_null_text(v)) return object::new_null();
	if ((core || e.tag == TAG_BOOL) && is_bool_text(v)) return object::new_bool(v[0] == 't' || v[0] == 'T');
	bool overflow;   // an int that does not fit: a decimal one becomes a float, 0x/0o a string
	if (core || e.tag == TAG_INT)
	{
		int128? i = int_of(v);
		if (try i) return object::new_int(self.allocator, i);
		overflow = @catch(i) != NOT_FOUND;
	}
	if (core || overflow || e.tag == TAG_FLOAT)
	{
		double? d = float_of(v);
		if (try d) return object::new_float(self.allocator, d);
	}
	switch (e.tag)
	{
		case TAG_NULL:
		case TAG_BOOL:
		case TAG_INT:
		case TAG_FLOAT: return self.parser.error(e.start, "the value does not match its tag", INVALID_INPUT_FORMAT)~;
		default: return object::new_string(self.allocator, v);
	}
}

fn bool is_null_text(String v) => v == "" || v == "~" || v == "null" || v == "Null" || v == "NULL";
fn bool is_bool_text(String v) => v == "true" || v == "True" || v == "TRUE" || v == "false" || v == "False" || v == "FALSE";

// Number of characters from `*i` on that are digits in `base`; advances `*i`.
fn sz digits(String v, sz* i, int base = 10)
{
	sz from = *i;
	while (*i < v.len && (base == 16 ? v[*i].is_xdigit() : v[*i] >= '0' && v[*i] < '0' + base)) (*i)++;
	return *i - from;
}

// [-+]?[0-9]+ | 0o[0-7]+ | 0x[0-9a-fA-F]+; NOT_FOUND if `v` does not match, a fault from
// to_int128 if it does not fit.
fn int128? int_of(String v)
{
	int base = v.starts_with("0o") ? 8 : v.starts_with("0x") ? 16 : 10;
	sz from = base == 10 ? 0 : 2;
	sz i = from;
	if (base == 10 && v.len && (v[0] == '-' || v[0] == '+')) i++;
	if (!digits(v, &i, base) || i != v.len) return NOT_FOUND~;
	return v[from..].to_int128(base);
}

// [-+]?(\.[0-9]+|[0-9]+(\.[0-9]*)?)([eE][-+]?[0-9]+)? | [-+]?\.(inf|Inf|INF) | \.(nan|NaN|NAN);
// NOT_FOUND if `v` does not match. Out of range is ±inf.
fn double? float_of(String v)
{
	bool minus = v.len && v[0] == '-';
	sz i = v.len && (minus || v[0] == '+') ? 1 : 0;
	String unsigned = v[i..];
	if (unsigned == ".inf" || unsigned == ".Inf" || unsigned == ".INF") return minus ? -double::inf : double::inf;
	if (v == ".nan" || v == ".NaN" || v == ".NAN") return double::nan;
	sz whole = digits(v, &i);
	if (i < v.len && v[i] == '.')
	{
		i++;
		if (!digits(v, &i) && !whole) return NOT_FOUND~;
	}
	else if (!whole)
	{
		return NOT_FOUND~;
	}
	if (i < v.len && (v[i] == 'e' || v[i] == 'E'))
	{
		i++;
		if (i < v.len && (v[i] == '-' || v[i] == '+')) i++;
		if (!digits(v, &i)) return NOT_FOUND~;
	}
	if (i != v.len) return NOT_FOUND~;
	double? d = v.to_double();
	if (catch d) return minus ? -double::inf : double::inf;   // only the range can fail here
	return d;
}
