module yaml;

import std::io;
import std::collections::object;
import std::collections::list;

import yaml::parser;

faultdef INVALID_INPUT_FORMAT, UNDEFINED_ALIAS;

struct YamlData (Printable)   // to_format prints JSON, one document per line
{
	List {Object*} docs;
	Allocator allocator;
}

fn sz? YamlData.to_format(&self, Formatter* f) @dynamic
{
	sz n = 0;
	foreach (o : self.docs) n += write_json(f, o)! + f.print("\n")!;
	return n;
}

// Prints an Object as compact JSON (Object.to_format does not escape strings).
struct Json (Printable) @private
{
	Object* o;
}

fn sz? Json.to_format(&self, Formatter* f) @dynamic => write_json(f, self.o);

fn sz? write_json(Formatter* f, Object* o) @private
{
	switch
	{
		case o.is_null(): return f.print("null");
		case o.is_bool(): return f.print(o.b ? "true" : "false");
		case o.is_int(): return f.printf("%d", o.i);
		case o.is_float(): return write_float(f, o.f);
		case o.is_string(): return write_string(f, o.s);
		case o.is_array():
			sz n = f.print("[")!;
			for (sz i = 0; i < o.get_len(); i++)
			{
				if (i) n += f.print(",")!;
				n += write_json(f, o.get_at(i))!;
			}
			return n + f.print("]")!;
		default:
			sz n = f.print("{")!;
			bool first = true;
			o.@each_entry(; String key, Object* value)
			{
				if (!first) n += f.print(",")!;
				first = false;
				n += write_string(f, key)! + f.print(":")!;
				n += write_json(f, value)!;
			};
			return n + f.print("}")!;
	}
}

// The shortest of %.15g, %.16g, %.17g that reads back as the same double, with a '.' or an
// exponent; no JSON for inf/nan.
fn sz? write_float(Formatter* f, double d) @private
{
	if (d != d || d == double::inf || d == -double::inf) return f.print("null");
	String s;
	foreach (format : (String[]){ "%.15g", "%.16g", "%.17g" })
	{
		s = string::tformat(format, d);
		double? back = s.to_double();   // fails when rounding goes past DBL_MAX; %.17g always reads back
		if (try back && back == d) break;
	}
	if (s.contains_char('.') || s.contains_char('e')) return f.print(s);
	return f.print(s)! + f.print(".0")!;   // stays a float: "1" would read back as an int
}

// RFC 8259 string escapes.
fn sz? write_string(Formatter* f, String s) @private
{
	sz n = f.print("\"")!;
	foreach (c : s)
	{
		switch (c)
		{
			case '"': n += f.print(`\"`)!;
			case '\\': n += f.print(`\\`)!;
			case '\n': n += f.print(`\n`)!;
			case '\t': n += f.print(`\t`)!;
			case '\r': n += f.print(`\r`)!;
			case '\b': n += f.print(`\b`)!;
			case '\f': n += f.print(`\f`)!;
			default: n += c < 0x20 ? f.printf("\\u%04x", c)! : f.print_char(c)!;
		}
	}
	return n + f.print("\"")!;
}

// The parser emits exactly one node (maybe an empty scalar) per document.
fn YamlData? from_string(String s, Allocator allocator = mem, bool verbose = true) => @pool()
{
	Parser p;
	p.init(s, verbose);
	YamlData data = { .allocator = allocator };
	data.docs.init(allocator);
	defer catch data.free();
	while (true)
	{
		Event ev = p.next()!;
		switch (ev.type)
		{
			case STREAM_END: return data;
			case SCALAR:
			case SEQUENCE_START:
			case MAPPING_START:
			case ALIAS: data.docs.push(build_document(&p, ev, allocator)!);
			default: break;
		}
	}
}

fn YamlData? from_stream(InStream reader, Allocator allocator = mem, bool verbose = true) => @pool()
{
	ByteWriter writer;
	io::copy_to(reader, writer.tinit())!;
	return from_string(writer.str_view(), allocator, verbose);
}

fn YamlData? from_file(String filename, Allocator allocator = mem, bool verbose = true)
{
	File f = io::file::open(filename, "r")!;
	defer (void)f.close();
	return from_stream(&f, allocator, verbose)!;
}

// "a.b.0": map keys and array indexes separated by '.'; document 0. An empty segment or an
// index with a leading zero is NOT_FOUND; keys that are empty or contain '.' are not reachable.
fn Object*? YamlData.get(&self, String path) @operator([]) => self.get_in(0, path);

fn Object*? YamlData.get_in(&self, sz doc, String path)
{
	if (doc >= self.docs.len()) return NOT_FOUND~;
	Object* o = self.docs[doc];
	if (!path.len) return o;
	foreach (segment : path.tsplit("."))
	{
		if (!segment.len) return NOT_FOUND~;   // "a.", "a..b", ".a"
		if (o.is_array())
		{
			sz i = 0;
			// only plain digits, no leading zero
			if (!digits(segment, &i) || i != segment.len || (segment[0] == '0' && segment.len > 1)) return NOT_FOUND~;
			int? index = segment.to_int();
			if (catch index) return NOT_FOUND~;
			if (index >= o.get_len()) return NOT_FOUND~;
			o = o.get_at(index);
		}
		else if (o.is_map())
		{
			o = o.get(segment)!;
		}
		else
		{
			return NOT_FOUND~;
		}
	}
	return o;
}

fn sz YamlData.len(&self) @operator(len)
{
	return self.docs.len();
}

fn void YamlData.free(&self)
{
	foreach (obj : self.docs) obj.free();
	self.docs.free();
}
