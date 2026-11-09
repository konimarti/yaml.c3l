module yaml::parser;

import std::io;
import std::collections::list;

faultdef SYNTAX_ERROR;

struct Mark
{
	sz pos;
	int line;
	int column;
}

enum EventType : char { STREAM_START, STREAM_END, DOCUMENT_START, DOCUMENT_END,
	MAPPING_START, MAPPING_END, SEQUENCE_START, SEQUENCE_END, SCALAR, ALIAS }

enum ScalarStyle : char { PLAIN, SINGLE, DOUBLE, LITERAL, FOLDED }

enum TokenType : char { T_STREAM_START, T_STREAM_END, T_DOCUMENT_START, T_DOCUMENT_END, T_SCALAR }

struct Token
{
	TokenType type;
	Mark start;
	String value;
	ScalarStyle style;
}

struct Event (Printable)
{
	EventType type;
	ScalarStyle style;
	bool explicit;
	String anchor;
	String tag;
	String value;
	Mark start;
}

fn sz? Event.to_format(&self, Formatter* f) @dynamic
{
	const String[*] EVENT_NAMES = { "+STR", "-STR", "+DOC", "-DOC", "+MAP", "-MAP", "+SEQ", "-SEQ", "=VAL", "=ALI" };
	sz n = f.print(EVENT_NAMES[self.type.ordinal])!;
	switch (self.type)
	{
		case DOCUMENT_START: if (self.explicit) n += f.print(" ---")!;
		case DOCUMENT_END: if (self.explicit) n += f.print(" ...")!;
		case MAPPING_START: if (self.explicit) n += f.print(" {}")!;
		case SEQUENCE_START: if (self.explicit) n += f.print(" []")!;
		case ALIAS: return n + f.printf(" *%s", self.anchor)!;
		default: break;
	}
	if (self.anchor.len) n += f.printf(" &%s", self.anchor)!;
	if (self.tag.len) n += f.printf(" <%s>", self.tag)!;
	if (self.type != SCALAR) return n;
	n += f.print((String[]){ " :", " '", " \"", " |", " >" }[self.style.ordinal])!;
	foreach (c : self.value)
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
