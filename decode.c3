module yaml;

import std::io, std::collections::list, std::collections::object;

faultdef DECODE_ERROR;

// Where a decode is, for error messages, and what it allocated (to undo that on an error).
struct DecodeCtx @private
{
	Allocator allocator;
	bool verbose;
	DString path;
	List {void*} owned;
}

fn String kind_name(Object* o) @private
{
	switch
	{
		case o.is_null(): return "null";
		case o.is_bool(): return "bool";
		case o.is_int(): return "int";
		case o.is_float(): return "float";
		case o.is_string(): return "string";
		case o.is_array(): return "sequence";
		default: return "mapping";
	}
}

fn fault DecodeCtx.fail(&self, String expected, Object* o)
{
	if (self.verbose)
	{
		String where = self.path.len() ? self.path.str_view() : "(document)";
		io::eprintfn("%s: expected %s, got %s", where, expected, kind_name(o));
	}
	return DECODE_ERROR;
}

fn fault DecodeCtx.fail_text(&self, String what)
{
	if (self.verbose)
	{
		String where = self.path.len() ? self.path.str_view() : "(document)";
		io::eprintfn("%s: %s", where, what);
	}
	return DECODE_ERROR;
}

// Decodes the object `o` as a $Type. Strings and slices are allocated with ctx.allocator.
fn Type? decode_node(Object* o, DecodeCtx* ctx) <Type> @private
{
	$switch:
		$case Type::typeid == String::typeid:
			if (!o.is_string()) return ctx.fail("string", o)~;
			String s = o.s.copy(ctx.allocator);
			if (s.len) ctx.owned.push(s.ptr);
			return s;
		$case Type::kind == BOOL:
			if (!o.is_bool()) return ctx.fail("bool", o)~;
			return o.b;
		$case Type::kind == SIGNED_INT:
			if (!o.is_int()) return ctx.fail("int", o)~;
			$if Type::size < 16:
				if (o.i < (int128)Type::min || o.i > (int128)Type::max) return ctx.fail_text(string::tformat("%d is out of range", o.i))~;
			$endif
			return (Type)o.i;
		$case Type::kind == UNSIGNED_INT:
			if (!o.is_int()) return ctx.fail("int", o)~;
			$if Type::size < 16:
				if (o.i < 0 || o.i > (int128)Type::max) return ctx.fail_text(string::tformat("%d is out of range", o.i))~;
			$else
				if (o.i < 0) return ctx.fail_text(string::tformat("%d is out of range", o.i))~;
			$endif
			return (Type)o.i;
		$case Type::kind == FLOAT:
			if (o.is_float()) return (Type)o.f;
			if (o.is_int()) return (Type)o.i;
			return ctx.fail("float", o)~;
		$case Type::kind == ENUM:
			if (!o.is_string()) return ctx.fail("an enum name", o)~;
			foreach (i, name : Type::names)
			{
				if (name == o.s) return Type::values[i];
			}
			return ctx.fail_text(string::tformat("'%s' is not a name of the enum", o.s))~;
		$case Type::kind == STRUCT:
			if (!o.is_map()) return ctx.fail("mapping", o)~;
			Type t;
			$foreach $m : Type::members:
				if (o.has_key($m.name) && !o.get($m.name)!!.is_null())
				{
					sz mark = ctx.path.len();
					if (mark) ctx.path.append_char('.');
					ctx.path.append($m.name);
					t.$eval($m.name) = decode_node{$Typefrom($m.type)}(o.get($m.name)!!, ctx)!;
					ctx.path.chop(mark);
				}
			$endforeach
			return t;
		$case Type::kind == ARRAY:
			if (!o.is_array()) return ctx.fail("sequence", o)~;
			if (o.get_len() > Type::len) return ctx.fail_text(string::tformat("sequence has %d items, at most %d fit", o.get_len(), Type::len))~;
			Type t;
			for (sz i = 0; i < o.get_len(); i++)
			{
				sz mark = ctx.path.len();
				if (mark) ctx.path.append_char('.');
				ctx.path.appendf("%d", i);
				t[i] = decode_node{$Typefrom(Type::inner)}(o.get_at(i), ctx)!;
				ctx.path.chop(mark);
			}
			return t;
		$case Type::kind == SLICE:
			if (!o.is_array()) return ctx.fail("sequence", o)~;
			sz n = o.get_len();
			Type t = alloc::new_array(ctx.allocator, $Typefrom(Type::inner), n);
			if (n) ctx.owned.push(t.ptr);
			for (sz i = 0; i < n; i++)
			{
				sz mark = ctx.path.len();
				if (mark) ctx.path.append_char('.');
				ctx.path.appendf("%d", i);
				t[i] = decode_node{$Typefrom(Type::inner)}(o.get_at(i), ctx)!;
				ctx.path.chop(mark);
			}
			return t;
		$default:
			$error "yaml::decode: unsupported member type";
	$endswitch
}

// Decodes document `doc` of `yaml` into a Type. Members whose key is missing (or null) keep
// their default, unknown keys are ignored. A mismatch or an out-of-range integer fails with
// DECODE_ERROR (and prints the path of the value, e.g. `db.ports.1: expected int, got string`,
// when `verbose`).
//
// Memory: every String and slice in the result is allocated with `allocator`; use tmem or an
// arena to free it all at once, or free each of them. On an error nothing stays allocated.
fn Type? decode_in(Yaml yaml, sz doc, Allocator allocator = mem, bool verbose = true) <Type>
{
	if (doc >= yaml.docs.len()) return NOT_FOUND~;
	@pool()
	{
		DecodeCtx ctx = { .allocator = allocator, .verbose = verbose, .path = dstring::temp() };
		ctx.owned.tinit();
		Type? result = decode_node{Type}(yaml.docs[doc], &ctx);
		if (catch err = result)
		{
			foreach (p : ctx.owned) alloc::free(allocator, p);
			return err~;
		}
		return result;
	};
}

// The first document: `Config c = yaml::decode{Config}(data)!;`
fn Type? decode(Yaml yaml, Allocator allocator = mem, bool verbose = true) <Type> => decode_in{Type}(yaml, 0, allocator, verbose);
