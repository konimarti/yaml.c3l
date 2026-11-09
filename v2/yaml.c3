// v2 contract. Card (b) owns this file: the parse functions, the builder entry and free.
module yaml2;

import std::io;
import yaml2::parser;

faultdef INVALID_INPUT_FORMAT, UNDEFINED_ALIAS, WRONG_KIND, OUT_OF_RANGE, DECODE_ERROR;   // + NOT_FOUND (std)

// The handle of a parsed stream. A value type: copies are handles of the same tree, so free
// exactly one of them (Yaml.free clears only the variable it is called on).
struct Yaml (Printable)
{
	Tree* tree;
}

// Compact JSON, one document per line (json.c3, card (c)).
fn sz? Yaml.to_format(&self, Formatter* f) @dynamic => write_yaml_json(f, self);

fn void Yaml.free(&self)
{
	if (self.tree) self.tree.free();
	self.tree = null;
}

// Copy the input once (the tree owns the copy), then parse the copy in place.
fn Yaml? from_string(String s, Allocator allocator = mem, bool verbose = true) => unreachable("card (b)");
fn Yaml? from_stream(InStream reader, Allocator allocator = mem, bool verbose = true) => unreachable("card (b)");
fn Yaml? from_file(String filename, Allocator allocator = mem, bool verbose = true) => unreachable("card (b)");

// IN PLACE: `buf` must be WRITABLE (a String literal converts to char[] and crashes on the first
// write) and its content is destroyed. Not copied: the caller owns `buf` and keeps it alive as
// long as the Yaml. The tree allocates nodes (and spills) with `allocator`.
fn Yaml? from_buffer(char[] buf, Allocator allocator = mem, bool verbose = true) => unreachable("card (b)");

// Parses a String, a char[] (both COPIED), a DString or an InStream (a File, a ByteReader, ...) by its type.
macro Yaml? parse(input, Allocator allocator = mem, bool verbose = true)
{
	$switch $Typeof(input):
		$case DString:
			return from_string(input.str_view(), allocator, verbose);
		$case String:
			return from_string(input, allocator, verbose);
		$case char[]:
			return from_string((String)input, allocator, verbose);
		$default:
			return from_stream(input, allocator, verbose);   // anything else must be an InStream
	$endswitch
}

// Like parse, with tmem: the result lives until the end of the enclosing @pool().
macro Yaml? tparse(input, bool verbose = true) => parse(input, tmem, verbose);
