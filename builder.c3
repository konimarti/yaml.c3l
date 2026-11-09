module yaml;

import std::io;
import std::collections::map, std::collections::object;
import yaml::parser;

const sz MAX_ALIAS_NODES = 1_000_000;   // nodes created by alias expansion per document
const int MAX_DEPTH = 512;              // nesting depth of the built tree

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
	int depth;
	HashMap {String, Object*} anchors;   // tmem copies of the anchored nodes
}

fn Object*? build_document(Parser* p, Event root, Allocator a)
{
	Builder b = { .p = p, .a = a };
	b.anchors.tinit();
	return b.node(root);
}

fn fault Builder.error(&self, Mark m, String msg, fault f) => self.p.scanner.error(m, msg, f);

fn Object*? Builder.node(&self, Event e)
{
	Object* o = null;
	defer catch if (o) o.free();
	switch (e.type)
	{
		case ALIAS:
			Object*? anchored = self.anchors.get(e.anchor);
			if (catch anchored) return self.error(e.start, "undefined alias", UNDEFINED_ALIAS)~;
			Object*? copy = self.clone(anchored, self.a, true, self.depth);
			if (catch copy) return self.error(e.start, "alias expansion or nesting limit exceeded", LIMIT_EXCEEDED)~;
			return copy;
		case SCALAR:
			o = self.scalar(e)!;
		case SEQUENCE_START:
			if (++self.depth > MAX_DEPTH) return self.error(e.start, "nesting depth limit exceeded", LIMIT_EXCEEDED)~;
			o = object::new_array(self.a);
			while (true)
			{
				Event n = self.p.next()!;
				if (n.type == SEQUENCE_END) break;
				o.push_object(self.node(n)!);
			}
			self.depth--;
		case MAPPING_START:
			if (++self.depth > MAX_DEPTH) return self.error(e.start, "nesting depth limit exceeded", LIMIT_EXCEEDED)~;
			o = object::new_obj(self.a);
			while (true)
			{
				Event k = self.p.next()!;
				if (k.type == MAPPING_END) break;
				String key = self.key(k)!;
				o.set(key, self.node(self.p.next()!)!);   // duplicate keys: last wins
			}
			self.depth--;
		default:
			return self.error(e.start, "unexpected event", parser::SYNTAX_ERROR)~;
	}
	if (e.anchor.len) self.anchors.set(e.anchor, self.clone(o, tmem, false, 0)!);
	return o;
}

// A scalar key is its text (a null key is ""); a collection key is its compact JSON text.
fn String? Builder.key(&self, Event e)
{
	Object* k = self.node(e)!;
	defer k.free();
	if (k.is_null()) return "";
	if (e.type == SCALAR) return e.value;
	if (k.is_string()) return k.s.tcopy();
	return string::tformat("%s", (Json){ k });
}

// Deep copy (aliases must not share an Object*: Object.free would free it twice).
// `count`: the copy is an alias expansion and counts against MAX_ALIAS_NODES.
fn Object*? Builder.clone(&self, Object* o, Allocator a, bool count, int depth)
{
	if (count && ++self.alias_nodes > MAX_ALIAS_NODES) return LIMIT_EXCEEDED~;
	switch
	{
		case o.is_null(): return object::new_null();
		case o.is_bool(): return object::new_bool(o.b);
		case o.is_int(): return object::new_int(a, o.i);
		case o.is_float(): return object::new_float(a, o.f);
		case o.is_string(): return object::new_string(a, o.s);
	}
	if (depth + 1 > MAX_DEPTH) return LIMIT_EXCEEDED~;
	if (o.is_array())
	{
		Object* arr = object::new_array(a);
		defer catch arr.free();
		for (sz i = 0; i < o.get_len(); i++) arr.push_object(self.clone(o.get_at(i), a, count, depth + 1)!);
		return arr;
	}
	Object* map = object::new_obj(a);
	defer catch map.free();
	if (o.type == void) return map;   // empty map
	foreach (key : o.map.keys(tmem)) map.set(key, self.clone(o.get(key)!, a, count, depth + 1)!);
	return map;
}

// ---- core schema ---------------------------------------------------------

// Untagged plain scalars are resolved by the core schema; the tags !!str !!null !!bool !!int
// !!float force their type; quoted, block and otherwise tagged scalars are strings.
fn Object*? Builder.scalar(&self, Event e)
{
	String v = e.value;
	String tag = e.tag;
	if (!tag.len && e.style == PLAIN)
	{
		switch
		{
			case is_null_text(v): tag = TAG_NULL;
			case is_bool_text(v): tag = TAG_BOOL;
			case is_int_text(v): tag = TAG_INT;
			case is_float_text(v): tag = TAG_FLOAT;
		}
	}
	switch (tag)
	{
		case TAG_NULL:
			if (is_null_text(v)) return object::new_null();
		case TAG_BOOL:
			if (is_bool_text(v)) return object::new_bool(v[0] == 't' || v[0] == 'T');
		case TAG_INT:
			if (is_int_text(v))
			{
				int128? i = v.starts_with("0o") ? v[2..].to_int128(8) : v.starts_with("0x") ? v[2..].to_int128(16) : v.to_int128();
				if (try i) return object::new_int(self.a, i);
				if (is_float_text(v)) return object::new_float(self.a, v.to_double()!);   // overflow
				if (!e.tag.len) return object::new_string(self.a, v);   // 0x/0o overflow
			}
		case TAG_FLOAT:
			if (is_float_text(v)) return object::new_float(self.a, float_value(v)!);
		default:
			return object::new_string(self.a, v);
	}
	return self.error(e.start, "the value does not match its tag", INVALID_INPUT_FORMAT)~;
}

fn bool is_null_text(String v)
{
	switch (v)
	{
		case "":
		case "~":
		case "null":
		case "Null":
		case "NULL": return true;
		default: return false;
	}
}

fn bool is_bool_text(String v)
{
	switch (v)
	{
		case "true":
		case "True":
		case "TRUE":
		case "false":
		case "False":
		case "FALSE": return true;
		default: return false;
	}
}

// Number of characters from `*i` on that are digits in `base`; advances `*i`.
fn sz digits(String v, sz* i, int base = 10)
{
	sz from = *i;
	while (*i < v.len && (base == 16 ? v[*i].is_xdigit() : v[*i] >= '0' && v[*i] < '0' + base)) (*i)++;
	return *i - from;
}

// [-+]?[0-9]+ | 0o[0-7]+ | 0x[0-9a-fA-F]+
fn bool is_int_text(String v)
{
	sz i = 2;
	if (v.starts_with("0o")) return digits(v, &i, 8) && i == v.len;
	if (v.starts_with("0x")) return digits(v, &i, 16) && i == v.len;
	i = v.len && (v[0] == '-' || v[0] == '+') ? 1 : 0;
	return digits(v, &i) && i == v.len;
}

// [-+]?(\.[0-9]+|[0-9]+(\.[0-9]*)?)([eE][-+]?[0-9]+)? | [-+]?\.(inf|Inf|INF) | \.(nan|NaN|NAN)
fn bool is_float_text(String v)
{
	sz i = v.len && (v[0] == '-' || v[0] == '+') ? 1 : 0;
	switch (v[i..])
	{
		case ".inf":
		case ".Inf":
		case ".INF": return true;
		case ".nan":
		case ".NaN":
		case ".NAN": return i == 0;
	}
	sz whole = digits(v, &i);
	if (i < v.len && v[i] == '.')
	{
		i++;
		if (!digits(v, &i) && !whole) return false;
	}
	else if (!whole)
	{
		return false;
	}
	if (i < v.len && (v[i] == 'e' || v[i] == 'E'))
	{
		i++;
		if (i < v.len && (v[i] == '-' || v[i] == '+')) i++;
		if (!digits(v, &i)) return false;
	}
	return i == v.len;
}

fn double? float_value(String v)
{
	String unsigned = v.len && (v[0] == '-' || v[0] == '+') ? v[1..] : v;
	switch (unsigned)
	{
		case ".inf":
		case ".Inf":
		case ".INF": return v[0] == '-' ? -double::inf : double::inf;
		case ".nan":
		case ".NaN":
		case ".NAN": return double::nan;
		default: return v.to_double();
	}
}
