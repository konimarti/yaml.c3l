// v2 contract. Card (d) owns this file. Same rules, messages and ownership as the old decode.c3
// (README "Decoding into a struct"); integers go through Node.as_int128 / schema::int_of.
module yaml2;

import std::io, std::collections::list;

// Where a decode is, for error messages, and what it allocated (to undo that on an error).
struct DecodeCtx @private
{
	Allocator allocator;
	bool verbose;
	bool borrowed;
	DString path;
	List {void*} owned;
}

fn String kind_name(Node n) @private
{
	switch (n.kind())
	{
		case NULL: return "null";
		case BOOL: return "bool";
		case INT: return "int";
		case FLOAT: return "float";
		case STRING: return "string";
		case SEQUENCE: return "sequence";
		case MAPPING: return "mapping";
		case MISSING: return "missing";
	}
}

fn fault DecodeCtx.fail(&self, String expected, Node n)
{
	if (self.verbose)
	{
		String where = self.path.len() ? self.path.str_view() : "(document)";
		io::eprintfn("%s: expected %s, got %s", where, expected, kind_name(n));
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

// Decodes node `n` as a $Type. Strings and slices are allocated with ctx.allocator (unless borrowed).
fn Type? decode_node_internal(Node n, DecodeCtx* ctx) <Type> @private
{
	$switch:
		$case Type::typeid == String::typeid:
			if (!n.is_string()) return ctx.fail("string", n)~;
			String text = n.text();
			if (ctx.borrowed) return text;
			String s = text.copy(ctx.allocator);
			ctx.owned.push(s.ptr);
			return s;
		$case Type::kind == BOOL:
			if (!n.is_bool()) return ctx.fail("bool", n)~;
			bool? b = n.as_bool();
			if (catch b) return ctx.fail("bool", n)~;
			return b;
		$case Type::kind == SIGNED_INT:
			if (!n.is_int()) return ctx.fail("int", n)~;
			int128? vi = n.as_int128();
			if (catch vi) return ctx.fail("int", n)~;
			$if Type::size < 16:
				if (vi < (int128)Type::min || vi > (int128)Type::max) return ctx.fail_text(string::tformat("%d is out of range", vi))~;
			$endif
			return (Type)vi;
		$case Type::kind == UNSIGNED_INT:
			if (!n.is_int()) return ctx.fail("int", n)~;
			int128? vi = n.as_int128();
			if (catch vi) return ctx.fail("int", n)~;
			$if Type::size < 16:
				if (vi < 0 || vi > (int128)Type::max) return ctx.fail_text(string::tformat("%d is out of range", vi))~;
			$else
				if (vi < 0) return ctx.fail_text(string::tformat("%d is out of range", vi))~;
			$endif
			return (Type)vi;
		$case Type::kind == FLOAT:
			if (n.is_float() || n.is_int())
			{
				double? d = n.as_float();
				if (try d) return (Type)d;
			}
			return ctx.fail("float", n)~;
		$case Type::kind == ENUM:
			if (!n.is_string()) return ctx.fail("an enum name", n)~;
			String txt = n.text();
			foreach (i, name : Type::names)
			{
				if (name == txt) return Type::values[i];
			}
			return ctx.fail_text(string::tformat("'%s' is not a name of the enum", txt))~;
		$case Type::kind == STRUCT:
			if (!n.is_map()) return ctx.fail("mapping", n)~;
			Type t;
			$foreach $m : Type::members:
				if (try child = n.get($m.name))
				{
					if (!child.is_null())
					{
						sz mark = ctx.path.len();
						if (mark) ctx.path.append_char('.');
						ctx.path.append($m.name);
						t.$eval($m.name) = decode_node_internal{$Typefrom($m.type)}(child, ctx)!;
						ctx.path.chop(mark);
					}
				}
			$endforeach
			return t;
		$case Type::kind == ARRAY:
			if (!n.is_seq()) return ctx.fail("sequence", n)~;
			sz len = n.len();
			if (len > Type::len) return ctx.fail_text(string::tformat("sequence has %d items, at most %d fit", len, Type::len))~;
			Type t;
			foreach (i, item : n.items())
			{
				sz mark = ctx.path.len();
				if (mark) ctx.path.append_char('.');
				ctx.path.appendf("%d", i);
				t[i] = decode_node_internal{$Typefrom(Type::inner)}(item, ctx)!;
				ctx.path.chop(mark);
			}
			return t;
		$case Type::kind == SLICE:
			if (!n.is_seq()) return ctx.fail("sequence", n)~;
			sz count = n.len();
			Type t = alloc::new_array(ctx.allocator, $Typefrom(Type::inner), count);
			if (count) ctx.owned.push(t.ptr);
			foreach (i, item : n.items())
			{
				sz mark = ctx.path.len();
				if (mark) ctx.path.append_char('.');
				ctx.path.appendf("%d", i);
				t[i] = decode_node_internal{$Typefrom(Type::inner)}(item, ctx)!;
				ctx.path.chop(mark);
			}
			return t;
		$default:
			$error "yaml2::decode: unsupported member type";
	$endswitch
}

fn Type? decode_node_entry(Node n, Allocator allocator, bool verbose, bool borrowed) <Type> @private
{
	@pool()
	{
		DecodeCtx ctx = { .allocator = allocator, .verbose = verbose, .borrowed = borrowed, .path = dstring::temp() };
		ctx.owned.tinit();
		Type? result = decode_node_internal{Type}(n, &ctx);
		if (catch err = result)
		{
			for (sz i = ctx.owned.len(); i > 0; i--) alloc::free(allocator, ctx.owned[i - 1]);
			return err~;
		}
		return result;
	};
}

// A method cannot be generic (verified on 0.8.6), so: a free generic function and a macro method.
//   Config c = yaml2::decode{Config}(data)!!;      Config c = node.decode(Config)!!;
fn Type? decode_node(Node n, Allocator allocator = mem, bool verbose = true) <Type> => decode_node_entry{Type}(n, allocator, verbose, false);
macro Node.decode(self, $Type, Allocator allocator = mem, bool verbose = true) => decode_node{$Type}(self, allocator, verbose);

fn Type? decode_in(Yaml yaml, sz doc, Allocator allocator = mem, bool verbose = true) <Type>
{
	if (!yaml.tree || doc >= yaml.len()) return NOT_FOUND~;
	return decode_node{Type}(yaml.doc(doc), allocator, verbose);
}

fn Type? decode(Yaml yaml, Allocator allocator = mem, bool verbose = true) <Type> => decode_in{Type}(yaml, 0, allocator, verbose);

// Zero string allocations: the Strings of the result are views into the tree (valid while the
// Yaml lives). Slices of the result are still allocated with `allocator`.
fn Type? decode_borrowed(Node n, Allocator allocator = mem, bool verbose = true) <Type> => decode_node_entry{Type}(n, allocator, verbose, true);
macro Node.decode_borrowed(self, $Type, Allocator allocator = mem, bool verbose = true) => decode_borrowed{$Type}(self, allocator, verbose);
