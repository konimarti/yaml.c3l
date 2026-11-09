// v2 contract: zero-allocation scanner/parser (Card a).
// Replaces the M1 shim with the real zero-allocation parser.
module yaml::parser;

import std::io;

enum State : char
{
	STREAM_START, IMPLICIT_DOCUMENT_START, DOCUMENT_START, DOCUMENT_CONTENT, DOCUMENT_END,
	BLOCK_NODE, BLOCK_SEQUENCE_ENTRY, INDENTLESS_SEQUENCE_ENTRY,
	BLOCK_MAPPING_KEY, BLOCK_MAPPING_VALUE,
	FLOW_SEQUENCE_FIRST_ENTRY, FLOW_SEQUENCE_ENTRY, FLOW_SEQUENCE_ENTRY_MAPPING_KEY,
	FLOW_SEQUENCE_ENTRY_MAPPING_VALUE, FLOW_SEQUENCE_ENTRY_MAPPING_END,
	FLOW_MAPPING_FIRST_KEY, FLOW_MAPPING_KEY, FLOW_MAPPING_VALUE, FLOW_MAPPING_EMPTY_VALUE, END
}

struct TagDir
{
	Span handle;
	Span prefix;
}

struct Parser
{
	Scanner scanner;
	State state;
	State[MAX_DEPTH + 8] states;
	int states_len;
	TagDir[MAX_TAG_DIRECTIVES] tag_directives;
	int tag_directives_len;
	int depth;

	char[] buf;
	Arena arena;
	Allocator spill;

	bool failed;
	fault last_fault;
}

// Parses `buf` IN PLACE: `buf` must be WRITABLE and its content is destroyed,
// also after an error. The caller keeps `buf` alive as long as any Span of this parser is read.
// `spill`: allocator for text that does not fit in place (`\L`, `\P`);
// null = fail with NO_SPACE (the default; no allocation at all).
fn Parser* Parser.init_inplace(&self, char[] buf, bool verbose = true, Allocator spill = null)
{
	*self = {
		.spill = spill,
	};
	if (spill) self.arena.init(spill);
	self.scanner.init(buf, verbose, &self.arena, spill);
	self.buf = self.scanner.s;
	return self;
}

// Resolves a span to a String.
// Validity: for plain and const spans, the returned String is valid as long as the input
// buffer is alive. For spilled spans (SPILL_BIT), the returned String is valid only until the next
// spill allocation (next Arena.put / next parser event), because the spill arena buffer may reallocate.
fn String Parser.text(&self, Span s) => resolve(self.buf, &self.arena, s);

fn char[] Parser.input(&self) => self.buf;

// Returns an EventView wrapping this parser and event for formatting.
// Spilled strings resolved during formatting are subject to the same validity as Parser.text.
fn EventView Parser.view(&self, Event e) => { self, e };

// The next event; 0 allocations in the real parser. After an error every call fails again.
fn Event? Parser.next(&self)
{
	if (self.failed) return self.last_fault~;
	Event? e = self.next_event();
	if (catch f = e)
	{
		self.failed = true;
		self.last_fault = f;
		return f~;
	}
	return e;
}

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

fn void? Parser.push_state(&self, State s)
{
	if (self.states_len >= self.states.len) return self.error(self.scanner.mark, "parser state stack overflow", LIMIT_EXCEEDED)~;
	self.states[self.states_len++] = s;
}

fn fault Parser.error(&self, Mark m, String msg, fault f = SYNTAX_ERROR) => self.scanner.error(m, msg, f);

fn Event empty_scalar(Mark m) => { .type = SCALAR, .start = m };

fn bool Token.is(self, TokenType... types)
{
	foreach (type : types) if (self.type == type) return true;
	return false;
}

fn Event? Parser.node_or_empty(&self, State next, TokenType[] ends, bool indentless_sequence = false)
{
	Token t = self.scanner.peek_token()!;
	if (t.is(...ends))
	{
		self.state = next;
		return empty_scalar(t.start());
	}
	self.push_state(next)!;
	return self.node(indentless_sequence);
}

fn Event? Parser.next_event(&self)
{
	switch (self.state)
	{
		case STREAM_START:
			Token t = self.scanner.next_token()!;
			self.state = IMPLICIT_DOCUMENT_START;
			return { .type = STREAM_START, .start = t.start() };
		case IMPLICIT_DOCUMENT_START: return self.document_start(true);
		case DOCUMENT_START: return self.document_start(false);
		case DOCUMENT_CONTENT: return self.document_content();
		case DOCUMENT_END: return self.document_end();
		case BLOCK_NODE: return self.node();
		case BLOCK_SEQUENCE_ENTRY: return self.block_sequence_entry();
		case INDENTLESS_SEQUENCE_ENTRY: return self.indentless_sequence_entry();
		case BLOCK_MAPPING_KEY: return self.block_mapping_key();
		case BLOCK_MAPPING_VALUE: return self.block_mapping_value();
		case FLOW_SEQUENCE_FIRST_ENTRY: return self.flow_sequence_entry(true);
		case FLOW_SEQUENCE_ENTRY: return self.flow_sequence_entry(false);
		case FLOW_SEQUENCE_ENTRY_MAPPING_KEY: return self.flow_sequence_entry_mapping_key();
		case FLOW_SEQUENCE_ENTRY_MAPPING_VALUE: return self.flow_sequence_entry_mapping_value();
		case FLOW_SEQUENCE_ENTRY_MAPPING_END:
			self.state = FLOW_SEQUENCE_ENTRY;
			self.depth--;
			return { .type = MAPPING_END, .start = self.scanner.peek_token()!.start() };
		case FLOW_MAPPING_FIRST_KEY: return self.flow_mapping_key(true);
		case FLOW_MAPPING_KEY: return self.flow_mapping_key(false);
		case FLOW_MAPPING_VALUE: return self.flow_mapping_value(false);
		case FLOW_MAPPING_EMPTY_VALUE: return self.flow_mapping_value(true);
		case END: return SYNTAX_ERROR~;
	}
}

fn Event? Parser.document_start(&self, bool implicit)
{
	Token t = self.scanner.peek_token()!;
	while (t.type == T_DOCUMENT_END)
	{
		self.scanner.next_token()!;
		t = self.scanner.peek_token()!;
		implicit = true;
	}
	if (t.type == T_STREAM_END)
	{
		self.scanner.next_token()!;
		self.state = END;
		return { .type = STREAM_END, .start = t.start() };
	}
	if (t.is(T_VERSION_DIRECTIVE, T_TAG_DIRECTIVE, T_RESERVED_DIRECTIVE))
	{
		if (!implicit) return self.error(t.start(), "a directive after a document needs '...' first")~;
		t = self.directives()!;
		if (t.type != T_DOCUMENT_START) return self.error(t.start(), "expected '---' after the directives")~;
	}
	self.push_state(DOCUMENT_END)!;
	if (t.type == T_DOCUMENT_START)
	{
		self.scanner.next_token()!;
		self.state = DOCUMENT_CONTENT;
		return { .type = DOCUMENT_START, .explicit = true, .start = t.start() };
	}
	if (!implicit) return self.error(t.start(), "unexpected content after the document's root node")~;
	self.state = BLOCK_NODE;
	return { .type = DOCUMENT_START, .start = t.start() };
}

fn Token? Parser.directives(&self)
{
	bool version;
	Token t = self.scanner.peek_token()!;
	while (t.is(T_VERSION_DIRECTIVE, T_TAG_DIRECTIVE, T_RESERVED_DIRECTIVE))
	{
		if (t.type == T_VERSION_DIRECTIVE)
		{
			if (version) return self.error(t.start(), "duplicate %YAML directive", INVALID_DIRECTIVE)~;
			version = true;
		}
		else if (t.type == T_TAG_DIRECTIVE)
		{
			if (self.tag_directives_len >= MAX_TAG_DIRECTIVES)
			{
				return self.error(t.start(), "too many tag directives", LIMIT_EXCEEDED)~;
			}
			Span h_span = t.handle();
			String h = self.text(h_span);
			for (int i = 0; i < self.tag_directives_len; i++)
			{
				if (self.text(self.tag_directives[i].handle) == h)
				{
					return self.error(t.start(), "duplicate %TAG handle", INVALID_DIRECTIVE)~;
				}
			}
			self.tag_directives[self.tag_directives_len++] = { h_span, t.value };
		}
		self.scanner.next_token()!;
		t = self.scanner.peek_token()!;
	}
	return t;
}

fn void? Parser.resolve_tag(&self, Token t, Span* prefix, Span* suffix)
{
	Span h_span = t.handle();
	if (h_span.is_empty())
	{
		*prefix = {};
		*suffix = t.value;
		return;
	}
	String h = self.text(h_span);
	if (h == "!" && t.value.is_empty())
	{
		*prefix = const_span(CONST_TAG_PRIMARY);
		*suffix = {};
		return;
	}
	for (int i = 0; i < self.tag_directives_len; i++)
	{
		if (self.text(self.tag_directives[i].handle) == h)
		{
			*prefix = self.tag_directives[i].prefix;
			*suffix = t.value;
			return;
		}
	}
	if (h == "!")
	{
		*prefix = const_span(CONST_TAG_PRIMARY);
		*suffix = t.value;
		return;
	}
	if (h == "!!")
	{
		*prefix = const_span(CONST_TAG_YAML);
		*suffix = t.value;
		return;
	}
	return self.error(t.start(), "undefined tag handle", UNDEFINED_TAG_HANDLE)~;
}

fn Event? Parser.document_content(&self)
{
	Token t = self.scanner.peek_token()!;
	if (t.is(T_DOCUMENT_START, T_DOCUMENT_END, T_STREAM_END, T_VERSION_DIRECTIVE, T_TAG_DIRECTIVE, T_RESERVED_DIRECTIVE))
	{
		self.state = self.states[--self.states_len];
		return empty_scalar(t.start());
	}
	return self.node();
}

fn Event? Parser.document_end(&self)
{
	Token t = self.scanner.peek_token()!;
	bool explicit = t.type == T_DOCUMENT_END;
	if (explicit) self.scanner.next_token()!;
	self.state = explicit ? IMPLICIT_DOCUMENT_START : DOCUMENT_START;
	self.tag_directives_len = 0;
	return { .type = DOCUMENT_END, .explicit = explicit, .start = t.start() };
}

fn Event? Parser.node(&self, bool indentless_sequence = false)
{
	Token t = self.scanner.peek_token()!;
	Event e = { .start = t.start() };
	bool props;
	while (t.type == T_ANCHOR || t.type == T_TAG)
	{
		if (t.type == T_ANCHOR)
		{
			if (!e.anchor.is_empty()) return self.error(t.start(), "a node can have only one anchor")~;
			e.anchor = t.value;
		}
		else
		{
			if (!e.tag.is_empty() || !e.tag_prefix.is_empty()) return self.error(t.start(), "a node can have only one tag")~;
			self.resolve_tag(t, &e.tag_prefix, &e.tag)!;
		}
		props = true;
		self.scanner.next_token()!;
		t = self.scanner.peek_token()!;
	}
	switch (t.type)
	{
		case T_ALIAS:
			if (props) return self.error(t.start(), "an alias cannot have properties")~;
			self.scanner.next_token()!;
			self.state = self.states[--self.states_len];
			return { .type = ALIAS, .anchor = t.value, .start = t.start() };
		case T_BLOCK_ENTRY:
			if (!indentless_sequence) break;
			self.state = INDENTLESS_SEQUENCE_ENTRY;
			e.type = SEQUENCE_START;
			self.depth++;
			if (self.depth > MAX_DEPTH) return self.error(e.start, "collection depth limit exceeded", LIMIT_EXCEEDED)~;
			return e;
		case T_SCALAR:
			self.scanner.next_token()!;
			self.state = self.states[--self.states_len];
			e.type = SCALAR;
			e.style = t.style;
			e.value = t.value;
			return e;
		case T_BLOCK_SEQUENCE_START:
		case T_FLOW_SEQUENCE_START:
			self.scanner.next_token()!;
			self.state = t.type == T_BLOCK_SEQUENCE_START ? BLOCK_SEQUENCE_ENTRY : FLOW_SEQUENCE_FIRST_ENTRY;
			e.type = SEQUENCE_START;
			e.explicit = t.type == T_FLOW_SEQUENCE_START;
			self.depth++;
			if (self.depth > MAX_DEPTH) return self.error(e.start, "collection depth limit exceeded", LIMIT_EXCEEDED)~;
			return e;
		case T_BLOCK_MAPPING_START:
		case T_FLOW_MAPPING_START:
			self.scanner.next_token()!;
			self.state = t.type == T_BLOCK_MAPPING_START ? BLOCK_MAPPING_KEY : FLOW_MAPPING_FIRST_KEY;
			e.type = MAPPING_START;
			e.explicit = t.type == T_FLOW_MAPPING_START;
			self.depth++;
			if (self.depth > MAX_DEPTH) return self.error(e.start, "collection depth limit exceeded", LIMIT_EXCEEDED)~;
			return e;
		default:
			break;
	}
	if (!props) return self.error(t.start(), "expected a node")~;
	self.state = self.states[--self.states_len];
	e.type = SCALAR;
	return e;
}

fn Event? Parser.block_sequence_entry(&self)
{
	Token t = self.scanner.peek_token()!;
	if (t.type == T_BLOCK_END)
	{
		self.scanner.next_token()!;
		self.state = self.states[--self.states_len];
		self.depth--;
		return { .type = SEQUENCE_END, .start = t.start() };
	}
	if (t.type != T_BLOCK_ENTRY) return self.error(t.start(), "expected '-' or a less indented line")~;
	self.scanner.next_token()!;
	return self.node_or_empty(BLOCK_SEQUENCE_ENTRY, { T_BLOCK_ENTRY, T_BLOCK_END });
}

fn Event? Parser.indentless_sequence_entry(&self)
{
	Token t = self.scanner.peek_token()!;
	if (t.type != T_BLOCK_ENTRY)
	{
		self.state = self.states[--self.states_len];
		self.depth--;
		return { .type = SEQUENCE_END, .start = t.start() };
	}
	self.scanner.next_token()!;
	return self.node_or_empty(INDENTLESS_SEQUENCE_ENTRY, { T_BLOCK_ENTRY, T_KEY, T_VALUE, T_BLOCK_END });
}

fn Event? Parser.block_mapping_key(&self)
{
	Token t = self.scanner.peek_token()!;
	switch (t.type)
	{
		case T_BLOCK_END:
			self.scanner.next_token()!;
			self.state = self.states[--self.states_len];
			self.depth--;
			return { .type = MAPPING_END, .start = t.start() };
		case T_VALUE:
			self.state = BLOCK_MAPPING_VALUE;
			return empty_scalar(t.start());
		case T_KEY:
			self.scanner.next_token()!;
			return self.node_or_empty(BLOCK_MAPPING_VALUE, { T_KEY, T_VALUE, T_BLOCK_END }, indentless_sequence: true);
		default:
			return self.error(t.start(), "expected a mapping key or a less indented line")~;
	}
}

fn Event? Parser.block_mapping_value(&self)
{
	Token t = self.scanner.peek_token()!;
	if (t.type != T_VALUE)
	{
		self.state = BLOCK_MAPPING_KEY;
		return empty_scalar(t.start());
	}
	self.scanner.next_token()!;
	return self.node_or_empty(BLOCK_MAPPING_KEY, { T_KEY, T_VALUE, T_BLOCK_END }, indentless_sequence: true);
}

// ---- flow collections ----------------------------------------------------

fn Token? Parser.flow_separator(&self, Token t, bool first, String msg)
{
	if (first) return t;
	if (t.type != T_FLOW_ENTRY) return self.error(t.start(), msg)~;
	self.scanner.next_token()!;
	return self.scanner.peek_token()!;
}

fn Event? Parser.flow_sequence_entry(&self, bool first)
{
	Token t = self.scanner.peek_token()!;
	if (t.type != T_FLOW_SEQUENCE_END)
	{
		t = self.flow_separator(t, first, "expected ',' or ']'")!;
		if (t.type == T_KEY || t.type == T_VALUE)
		{
			if (t.type == T_KEY) self.scanner.next_token()!;
			self.state = FLOW_SEQUENCE_ENTRY_MAPPING_KEY;
			self.depth++;
			if (self.depth > MAX_DEPTH) return self.error(t.start(), "collection depth limit exceeded", LIMIT_EXCEEDED)~;
			return { .type = MAPPING_START, .explicit = true, .start = t.start() };
		}
		if (t.type != T_FLOW_SEQUENCE_END)
		{
			self.push_state(FLOW_SEQUENCE_ENTRY)!;
			return self.node();
		}
	}
	self.scanner.next_token()!;
	self.state = self.states[--self.states_len];
	self.depth--;
	return { .type = SEQUENCE_END, .start = t.start() };
}

fn Event? Parser.flow_sequence_entry_mapping_key(&self)
	=> self.node_or_empty(FLOW_SEQUENCE_ENTRY_MAPPING_VALUE, { T_VALUE, T_FLOW_ENTRY, T_FLOW_SEQUENCE_END });

fn Event? Parser.flow_sequence_entry_mapping_value(&self)
{
	Token t = self.scanner.peek_token()!;
	self.state = FLOW_SEQUENCE_ENTRY_MAPPING_END;
	if (t.type != T_VALUE) return empty_scalar(t.start());
	self.scanner.next_token()!;
	return self.node_or_empty(FLOW_SEQUENCE_ENTRY_MAPPING_END, { T_FLOW_ENTRY, T_FLOW_SEQUENCE_END });
}

fn Event? Parser.flow_mapping_key(&self, bool first)
{
	Token t = self.scanner.peek_token()!;
	if (t.type != T_FLOW_MAPPING_END)
	{
		t = self.flow_separator(t, first, "expected ',' or '}'")!;
		if (t.type == T_KEY)
		{
			self.scanner.next_token()!;
			return self.node_or_empty(FLOW_MAPPING_VALUE, { T_VALUE, T_FLOW_ENTRY, T_FLOW_MAPPING_END });
		}
		if (t.type == T_VALUE)
		{
			self.state = FLOW_MAPPING_VALUE;
			return empty_scalar(t.start());
		}
		if (t.type != T_FLOW_MAPPING_END)
		{
			self.push_state(FLOW_MAPPING_EMPTY_VALUE)!;
			return self.node();
		}
	}
	self.scanner.next_token()!;
	self.state = self.states[--self.states_len];
	self.depth--;
	return { .type = MAPPING_END, .start = t.start() };
}

fn Event? Parser.flow_mapping_value(&self, bool empty)
{
	Token t = self.scanner.peek_token()!;
	self.state = FLOW_MAPPING_KEY;
	if (empty || t.type != T_VALUE) return empty_scalar(t.start());
	self.scanner.next_token()!;
	return self.node_or_empty(FLOW_MAPPING_KEY, { T_FLOW_ENTRY, T_FLOW_MAPPING_END });
}
