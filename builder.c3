module yaml;

import std::collections::map, std::collections::list, std::collections::object;
import yaml::parser;

const String TAG_STR = "tag:yaml.org,2002:str";
const String TAG_NULL = "tag:yaml.org,2002:null";
const String TAG_BOOL = "tag:yaml.org,2002:bool";
const String TAG_INT = "tag:yaml.org,2002:int";
const String TAG_FLOAT = "tag:yaml.org,2002:float";

// Events -> Object for one document.
struct Builder
{
	Parser* p;
	Allocator a;
	sz alias_nodes;
	sz alias_bytes;
	sz key_text;
	int depth;
	HashMap {String, Object*} anchors;   // the anchored nodes (owned by the tree or by `dropped`)
	List {Object*} dropped;              // nodes taken out of the tree: replaced values and key nodes
}

fn Object*? build_document(Parser* p, Event root, Allocator a)
{
	Builder b = { .p = p, .a = a };
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
			if (catch anchored) return self.p.error(e.start, "undefined alias", UNDEFINED_ALIAS)~;
			Object*? copy = self.clone(anchored, self.a, self.depth);
			if (catch copy) return self.p.error(e.start, "alias expansion exceeds a size or nesting limit", parser::LIMIT_EXCEEDED)~;
			return copy;
		case SCALAR:
			o = self.scalar(e)!;
		case SEQUENCE_START:
			if (++self.depth > parser::MAX_DEPTH) return self.p.error(e.start, "nesting depth limit exceeded", parser::LIMIT_EXCEEDED)~;
			o = object::new_array(self.a);
			while (true)
			{
				Event n = self.p.next()!;
				if (n.type == SEQUENCE_END) break;
				o.push_object(self.node(n)!);
			}
			self.depth--;
		case MAPPING_START:
			if (++self.depth > parser::MAX_DEPTH) return self.p.error(e.start, "nesting depth limit exceeded", parser::LIMIT_EXCEEDED)~;
			o = object::new_obj(self.a);
			while (true)
			{
				Event k = self.p.next()!;
				if (k.type == MAPPING_END) break;
				String key = self.key(k)!;
				Object* value = self.node(self.p.next()!)!;
				if (o.has_key(key))   // duplicate keys: last wins; keep the old value for aliases
				{
					self.dropped.push(o.get(key)!!);
					o.map.remove(key);
				}
				o.set(key, value);
			}
			self.depth--;
		default:
			return self.p.error(e.start, "unexpected event", parser::SYNTAX_ERROR)~;
	}
	if (e.anchor.len) self.anchors.set(e.anchor, o);
	return o;
}

// A scalar key is its text (a null key is ""); a collection key is its compact JSON text.
fn String? Builder.key(&self, Event e)
{
	bool plain_key = e.type == SCALAR && !e.tag.len && !e.anchor.len;
	if (plain_key) return e.style == PLAIN && is_null_text(e.value) ? "" : e.value;
	Object* k = self.node(e)!;
	self.dropped.push(k);   // not freed yet: an alias may refer to it
	if (k.is_null()) return "";
	if (e.type == SCALAR) return e.value;
	if (k.is_string()) return k.s;
	// a nested collection key is escaped again at every level: the text can double per level
	String text = string::tformat("%s", (Json){ k });
	self.key_text += text.len;
	if (self.key_text > parser::MAX_KEY_TEXT) return self.p.error(e.start, "collection keys are too long", parser::LIMIT_EXCEEDED)~;
	return text;
}

// Deep copy for an alias (sharing an Object* would make Object.free free it twice). Every
// created node counts against MAX_ALIAS_NODES, every copied string and key against
// MAX_ALIAS_BYTES; `depth` is the depth of the alias.
fn Object*? Builder.clone(&self, Object* o, Allocator a, int depth)
{
	if (++self.alias_nodes > parser::MAX_ALIAS_NODES) return parser::LIMIT_EXCEEDED~;
	switch
	{
		case o.is_null(): return object::new_null();
		case o.is_bool(): return object::new_bool(o.b);
		case o.is_int(): return object::new_int(a, o.i);
		case o.is_float(): return object::new_float(a, o.f);
		case o.is_string():
			if ((self.alias_bytes += o.s.len) > parser::MAX_ALIAS_BYTES) return parser::LIMIT_EXCEEDED~;
			return object::new_string(a, o.s);
	}
	if (depth + 1 > parser::MAX_DEPTH) return parser::LIMIT_EXCEEDED~;
	if (o.is_array())
	{
		Object* arr = object::new_array(a);
		defer catch arr.free();
		for (sz i = 0; i < o.get_len(); i++) arr.push_object(self.clone(o.get_at(i), a, depth + 1)!);
		return arr;
	}
	Object* map = object::new_obj(a);
	defer catch map.free();
	o.@each_entry(; String key, Object* value)
	{
		if ((self.alias_bytes += key.len) > parser::MAX_ALIAS_BYTES) return parser::LIMIT_EXCEEDED~;
		map.set(key, self.clone(value, a, depth + 1)!);
	};
	return map;
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
		if (try i) return object::new_int(self.a, i);
		overflow = @catch(i) != NOT_FOUND;
	}
	if (core || overflow || e.tag == TAG_FLOAT)
	{
		double? d = float_of(v);
		if (try d) return object::new_float(self.a, d);
	}
	switch (e.tag)
	{
		case TAG_NULL:
		case TAG_BOOL:
		case TAG_INT:
		case TAG_FLOAT: return self.p.error(e.start, "the value does not match its tag", INVALID_INPUT_FORMAT)~;
		default: return object::new_string(self.a, v);
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
