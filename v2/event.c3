// v2 contract (frozen by the designer; changes need a design amendment).
// Temporary module `yaml2::parser`; card (e) renames yaml2 -> yaml at the cutover.
// The public side of the event parser: faults, limits, spans, events.
module yaml2::parser;

import std::io;

faultdef SYNTAX_ERROR, LIMIT_EXCEEDED, INVALID_CHARACTER, INVALID_INDENTATION, MISSING_COLON,
	INVALID_TAB, INVALID_ESCAPE, UNCLOSED_QUOTE, INVALID_BLOCK_HEADER, UNCLOSED_FLOW,
	INVALID_DIRECTIVE, UNDEFINED_TAG_HANDLE,
	NO_SPACE;   // a scalar needs more room than in place and no spill allocator was given

// ---- limits (exceeding one fails with LIMIT_EXCEEDED) -------------------------------------
const int MAX_DEPTH = 256;                    // collection depth (block and flow together) AND block indent levels
const uint MAX_INPUT = 0x3FFF_FFFF;           // bytes; offsets are 30 bits (bits 31 and 30 are span flags)
const int QUEUE_SIZE = 2048;                  // token ring; a pending key may hold at most QUEUE_SIZE - 8 tokens
const int MAX_TAG_DIRECTIVES = 16;            // %TAG per document
// Budgets for one from_* call (all documents of the stream): what alias expansion would create.
const sz MAX_ALIAS_NODES = 1_000_000;
const sz MAX_ALIAS_BYTES = 64 * 1024 * 1024;
// Only JSON output and to_object: the text of collection keys.
const sz MAX_KEY_TEXT = 4 * 1024 * 1024;
const sz KEY_TEXT_PER_BYTE = 4;

// ---- spans ----------------------------------------------------------------------------------
// A Span names text without a pointer. `off` has three meanings, decided by its top bits:
//   plain       0x0.. : byte offset into the input buffer (after the BOM, in normalised coordinates)
//   SPILL_BIT   0x8.. : byte offset into the Arena (text that does not fit in place, or that a
//                       temporary parser had to copy)
//   CONST_BIT   0x4.. : a constant text, `off & 0x3FFF_FFFF` is the id (CONST_TAG_*)
// Only `resolve` (and Parser.text / Tree.text, which call it) knows this. A resolved String of a
// SPILL span is valid until the next Arena.put (the arena may move); plain and const ones are
// stable for the life of the buffer.
const uint SPILL_BIT = 0x8000_0000;
const uint CONST_BIT = 0x4000_0000;
const uint CONST_TAG_YAML = 0;     // "tag:yaml.org,2002:"  (the prefix of !!str)
const uint CONST_TAG_PRIMARY = 1;  // "!"

struct Span
{
	uint off;
	uint len;
}

fn bool Span.is_empty(self) @inline => self.len == 0;
fn Span const_span(uint id) => { CONST_BIT | id, id == CONST_TAG_YAML ? 18 : 1 };

// Growable byte store for spilled text. Addressed by offset, so reallocation is harmless.
struct Arena
{
	char* ptr;
	uint len;
	uint cap;
	Allocator allocator;
}

fn void Arena.init(&self, Allocator allocator)
{
	*self = { .allocator = allocator };
}

// Copies `s` into the arena; the span has SPILL_BIT set. LIMIT_EXCEEDED beyond MAX_INPUT bytes.
fn Span? Arena.put(&self, String s)
{
	if (!s.len) return (Span){};
	if ((sz)self.len + s.len > MAX_INPUT) return LIMIT_EXCEEDED~;
	uint need = self.len + (uint)s.len;
	if (need > self.cap)
	{
		uint cap = self.cap ? self.cap : 256;
		while (cap < need) cap *= 2;
		self.ptr = alloc::realloc_array(self.allocator, self.ptr, char, cap).ptr;
		self.cap = cap;
	}
	mem::copy(self.ptr + self.len, s.ptr, s.len);
	Span span = { SPILL_BIT | self.len, (uint)s.len };
	self.len = need;
	return span;
}

fn void Arena.free(&self)
{
	if (self.ptr) alloc::free(self.allocator, self.ptr);
	*self = {};
}

// The one accessor: plain spans index `base` (the input), SPILL spans index `arena` (may be null).
fn String resolve(char[] base, Arena* arena, Span s)
{
	if (!s.len) return "";
	if (s.off & CONST_BIT) return (s.off & ~CONST_BIT) == CONST_TAG_YAML ? "tag:yaml.org,2002:" : "!";
	if (s.off & SPILL_BIT) return (String)(arena.ptr[(s.off & ~SPILL_BIT):s.len]);
	return (String)base[s.off:s.len];
}

// ---- events ---------------------------------------------------------------------------------
struct Mark
{
	sz pos;
	int line;
	int column;
}

enum EventType : char { STREAM_START, STREAM_END, DOCUMENT_START, DOCUMENT_END,
	MAPPING_START, MAPPING_END, SEQUENCE_START, SEQUENCE_END, SCALAR, ALIAS }

enum ScalarStyle : char { PLAIN, SINGLE, DOUBLE, LITERAL, FOLDED }

// Texts are Spans; read them with Parser.text(span). Untagged: tag_prefix and tag are empty.
// The tag is never concatenated: its text is tag_prefix followed by tag.
// An alias event has `anchor` = the name. A scalar's `value` is its decoded text.
struct Event
{
	EventType type;
	ScalarStyle style;
	bool explicit;
	Span anchor;
	Span tag_prefix;
	Span tag;
	Span value;
	Mark start;
}

// `io::printn(parser.view(event))` prints one test.event line.
struct EventView (Printable)
{
	Parser* parser;
	Event event;
}

fn sz? EventView.to_format(&self, Formatter* f) @dynamic
{
	const String[*] EVENT_NAMES = { "+STR", "-STR", "+DOC", "-DOC", "+MAP", "-MAP", "+SEQ", "-SEQ", "=VAL", "=ALI" };
	Event* e = &self.event;
	sz n = f.print(EVENT_NAMES[e.type.ordinal])!;
	String anchor = self.parser.text(e.anchor);
	switch (e.type)
	{
		case DOCUMENT_START: if (e.explicit) n += f.print(" ---")!;
		case DOCUMENT_END: if (e.explicit) n += f.print(" ...")!;
		case MAPPING_START: if (e.explicit) n += f.print(" {}")!;
		case SEQUENCE_START: if (e.explicit) n += f.print(" []")!;
		case ALIAS: return n + f.printf(" *%s", anchor)!;
		default: break;
	}
	if (anchor.len) n += f.printf(" &%s", anchor)!;
	if (e.tag_prefix.len || e.tag.len) n += f.printf(" <%s%s>", self.parser.text(e.tag_prefix), self.parser.text(e.tag))!;
	if (e.type != SCALAR) return n;
	n += f.print((String[]){ " :", " '", " \"", " |", " >" }[e.style.ordinal])!;
	foreach (c : self.parser.text(e.value))
	{
		switch (c)
		{
			case '\\': n += f.print(`\\`)!;
			case '\0': n += f.print(`\0`)!;
			case '\b': n += f.print(`\b`)!;
			case '\t': n += f.print(`\t`)!;
			case '\n': n += f.print(`\n`)!;
			case '\r': n += f.print(`\r`)!;
			default: n += f.print_char(c)!;
		}
	}
	return n;
}
