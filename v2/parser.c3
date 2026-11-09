// v2 contract. Card (a) owns this file and replaces the SHIM below by the real zero-allocation
// parser (the public signatures must not change).
//
// SHIM (milestone M1, delivered by card 0): wraps the old allocating parser and copies every
// anchor, tag and scalar into the arena, so each Span is a spilled span. It lets the tree
// builder be developed before the in-place scanner exists. It is NOT zero allocation.
module yaml2::parser;

import std::io;
import yaml::parser;

struct Parser
{
	yaml::parser::Parser old;   // shim only
	char[] buf;                 // the input; plain spans index it (unused by the shim)
	Arena arena;                // spilled text
	Allocator spill;            // null: the real parser fails NO_SPACE instead of spilling
}

// Parses `buf` IN PLACE: `buf` must be WRITABLE (a String literal also converts to char[] and
// crashes on the first write) and its content is destroyed, also after an error. The caller keeps
// `buf` alive as long as any Span of this parser is read. `spill`: allocator for text that does
// not fit in place (`\L`, `\P`); null = fail with NO_SPACE (the default; no allocation at all).
fn Parser* Parser.init_inplace(&self, char[] buf, bool verbose = true, Allocator spill = null)
{
	*self = { .buf = buf, .spill = spill };
	self.arena.init(spill ? spill : mem);   // shim: always needs an arena
	self.old.init((String)buf, verbose);
	return self;
}

fn String Parser.text(&self, Span s) => resolve(self.buf, &self.arena, s);

// The text that plain spans and Mark.pos index: `buf` after the in-place CRLF compaction (so
// possibly shorter than the buffer passed in). A leading BOM is NOT removed: scanning starts at
// byte 3 (Mark.pos starts at 3, Mark.column at 1). The tree sets `tree.input` to this slice, so
// its `input.ptr` stays the start of the allocation (a tree that owns a copy frees it).
fn char[] Parser.input(&self) => self.buf;

fn EventView Parser.view(&self, Event e) => { self, e };

// The next event; 0 allocations in the real parser. After an error every call fails again.
fn Event? Parser.next(&self)
{
	yaml::parser::Event? raw = self.old.next();
	if (catch f = raw) return map_fault(f)~;
	return {
		.type = (EventType)raw.type.ordinal,
		.style = (ScalarStyle)raw.style.ordinal,
		.explicit = raw.explicit,
		.anchor = self.arena.put(raw.anchor)!,
		.tag = self.arena.put(raw.tag)!,   // shim: the resolved tag, prefix empty
		.value = self.arena.put(raw.value)!,
		.start = { raw.start.pos, raw.start.line, raw.start.column },
	};
}

// Hands the arena (spilled text) to the caller, who must free it; the parser forgets it.
fn Arena Parser.take_spill(&self)
{
	Arena a = self.arena;
	self.arena = {};
	return a;
}

fn void Parser.free(&self)
{
	self.arena.free();
}

fn fault map_fault(fault f) @private
{
	switch (f)
	{
		case yaml::parser::SYNTAX_ERROR: return SYNTAX_ERROR;
		case yaml::parser::LIMIT_EXCEEDED: return LIMIT_EXCEEDED;
		case yaml::parser::INVALID_CHARACTER: return INVALID_CHARACTER;
		case yaml::parser::INVALID_INDENTATION: return INVALID_INDENTATION;
		case yaml::parser::MISSING_COLON: return MISSING_COLON;
		case yaml::parser::INVALID_TAB: return INVALID_TAB;
		case yaml::parser::INVALID_ESCAPE: return INVALID_ESCAPE;
		case yaml::parser::UNCLOSED_QUOTE: return UNCLOSED_QUOTE;
		case yaml::parser::INVALID_BLOCK_HEADER: return INVALID_BLOCK_HEADER;
		case yaml::parser::UNCLOSED_FLOW: return UNCLOSED_FLOW;
		case yaml::parser::INVALID_DIRECTIVE: return INVALID_DIRECTIVE;
		case yaml::parser::UNDEFINED_TAG_HANDLE: return UNDEFINED_TAG_HANDLE;
		default: return f;
	}
}
