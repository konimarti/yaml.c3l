// Parser: tokens -> events (libyaml-style state machine with a state stack).
module yaml::parser;
import std::io, std::collections::list;


enum State : char
{
	STREAM_START, IMPLICIT_DOCUMENT_START, DOCUMENT_START, DOCUMENT_CONTENT, DOCUMENT_END,
	BLOCK_NODE, BLOCK_SEQUENCE_ENTRY, INDENTLESS_SEQUENCE_ENTRY,
	BLOCK_MAPPING_KEY, BLOCK_MAPPING_VALUE,
	FLOW_SEQUENCE_FIRST_ENTRY, FLOW_SEQUENCE_ENTRY, FLOW_SEQUENCE_ENTRY_MAPPING_KEY,
	FLOW_SEQUENCE_ENTRY_MAPPING_VALUE, FLOW_SEQUENCE_ENTRY_MAPPING_END,
	FLOW_MAPPING_FIRST_KEY, FLOW_MAPPING_KEY, FLOW_MAPPING_VALUE, FLOW_MAPPING_EMPTY_VALUE, END
}

struct TagDirective { String handle; String prefix; }

struct Parser
{
	Scanner scanner;
	State state;
	List {State} states;   // where to continue after the current node
	List {TagDirective} tag_directives;   // %TAG handles of the current document
}

fn Parser* Parser.init(&self, String input, bool verbose = true)
{
	*self = {};
	self.scanner.init(input, verbose);
	self.states.tinit();
	self.tag_directives.tinit();
	return self;
}

fn Event? Parser.next(&self)
{
	switch (self.state)
	{
		case STREAM_START:
			Token t = self.scanner.next_token()!;   // T_STREAM_START
			self.state = IMPLICIT_DOCUMENT_START;
			return { .type = STREAM_START, .start = t.start };
		case IMPLICIT_DOCUMENT_START: return self.document_start(true);
		case DOCUMENT_START: return self.document_start(false);
		case DOCUMENT_CONTENT: return self.document_content();
		case DOCUMENT_END: return self.document_end();
		case BLOCK_NODE: return self.node(false);
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
			return { .type = MAPPING_END, .start = self.scanner.peek_token()!.start };
		case FLOW_MAPPING_FIRST_KEY: return self.flow_mapping_key(true);
		case FLOW_MAPPING_KEY: return self.flow_mapping_key(false);
		case FLOW_MAPPING_VALUE: return self.flow_mapping_value(false);
		case FLOW_MAPPING_EMPTY_VALUE: return self.flow_mapping_value(true);
		case END: return SYNTAX_ERROR~;
	}
}

fn Event empty_scalar(Mark m) => { .type = SCALAR, .start = m };

fn bool Token.is(self, TokenType... types)
{
	foreach (type : types) if (self.type == type) return true;
	return false;
}

fn Event? Parser.fail(&self, Token t, String msg)
{
	return self.scanner.error(t.start, msg)~;
}

// The document ends at '...', '---' or the end of the stream.
fn Event? Parser.document_start(&self, bool implicit)
{
	Token t = self.scanner.peek_token()!;
	while (t.type == T_DOCUMENT_END)   // bare '...' outside a document emits nothing
	{
		self.scanner.next_token()!;
		t = self.scanner.peek_token()!;
		implicit = true;
	}
	if (t.type == T_STREAM_END)
	{
		self.scanner.next_token()!;
		self.state = END;
		return { .type = STREAM_END, .start = t.start };
	}
	if (t.type == T_VERSION_DIRECTIVE || t.type == T_TAG_DIRECTIVE)
	{
		if (!implicit) return self.fail(t, "a directive after a document needs '...' first");
		t = self.directives()!;
		if (t.type != T_DOCUMENT_START) return self.fail(t, "expected '---' after the directives");
	}
	self.states.push(DOCUMENT_END);
	if (t.type == T_DOCUMENT_START)
	{
		self.scanner.next_token()!;
		self.state = DOCUMENT_CONTENT;
		return { .type = DOCUMENT_START, .explicit = true, .start = t.start };
	}
	if (!implicit) return self.fail(t, "unexpected content after the document's root node");
	self.state = BLOCK_NODE;
	return { .type = DOCUMENT_START, .start = t.start };
}

// %YAML (at most once) and %TAG (each handle once); returns the token after them.
fn Token? Parser.directives(&self)
{
	bool version;
	Token t = self.scanner.peek_token()!;
	while (t.type == T_VERSION_DIRECTIVE || t.type == T_TAG_DIRECTIVE)
	{
		if (t.type == T_VERSION_DIRECTIVE)
		{
			if (version) return self.scanner.error(t.start, "duplicate %YAML directive", INVALID_DIRECTIVE)~;
			version = true;
		}
		else
		{
			foreach (d : self.tag_directives)
			{
				if (d.handle == t.handle) return self.scanner.error(t.start, "duplicate %TAG handle", INVALID_DIRECTIVE)~;
			}
			self.tag_directives.push({ t.handle, t.value });
		}
		self.scanner.next_token()!;
		t = self.scanner.peek_token()!;
	}
	return t;
}

// prefix + suffix; "!" alone is the non-specific tag "!".
fn String? Parser.resolve_tag(&self, Token t)
{
	if (!t.handle.len) return t.value;   // verbatim
	if (t.handle == "!" && !t.value.len) return "!";
	foreach (d : self.tag_directives) if (d.handle == t.handle) return d.prefix.tconcat(t.value);
	if (t.handle == "!") return "!".tconcat(t.value);
	if (t.handle == "!!") return "tag:yaml.org,2002:".tconcat(t.value);
	return self.scanner.error(t.start, "undefined tag handle", UNDEFINED_TAG_HANDLE)~;
}

fn Event? Parser.document_content(&self)
{
	Token t = self.scanner.peek_token()!;
	if (t.is(T_DOCUMENT_START, T_DOCUMENT_END, T_STREAM_END, T_VERSION_DIRECTIVE, T_TAG_DIRECTIVE))
	{
		self.state = self.states.pop()!!;
		return empty_scalar(t.start);
	}
	return self.node(false);
}

fn Event? Parser.document_end(&self)
{
	Token t = self.scanner.peek_token()!;
	bool explicit = t.type == T_DOCUMENT_END;
	if (explicit) self.scanner.next_token()!;
	self.state = explicit ? IMPLICIT_DOCUMENT_START : DOCUMENT_START;
	self.tag_directives.clear();
	return { .type = DOCUMENT_END, .explicit = explicit, .start = t.start };
}

// One node with its optional properties (one anchor, one tag, in either order); the state to
// return to is on top of `states`. Properties without a node give an empty scalar.
fn Event? Parser.node(&self, bool indentless_sequence)
{
	Token t = self.scanner.peek_token()!;
	Event e = { .start = t.start };
	bool props;
	while (t.type == T_ANCHOR || t.type == T_TAG)
	{
		if (t.type == T_ANCHOR)
		{
			if (e.anchor.len) return self.fail(t, "a node can have only one anchor");
			e.anchor = t.value;
		}
		else
		{
			if (e.tag.len) return self.fail(t, "a node can have only one tag");
			e.tag = self.resolve_tag(t)!;
		}
		props = true;
		self.scanner.next_token()!;
		t = self.scanner.peek_token()!;
	}
	switch (t.type)
	{
		case T_ALIAS:
			if (props) return self.fail(t, "an alias cannot have properties");
			self.scanner.next_token()!;
			self.state = self.states.pop()!!;
			return { .type = ALIAS, .anchor = t.value, .start = t.start };
		case T_BLOCK_ENTRY:
			if (!indentless_sequence) break;
			self.state = INDENTLESS_SEQUENCE_ENTRY;
			e.type = SEQUENCE_START;
			return e;
		case T_SCALAR:
			self.scanner.next_token()!;
			self.state = self.states.pop()!!;
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
			return e;
		case T_BLOCK_MAPPING_START:
		case T_FLOW_MAPPING_START:
			self.scanner.next_token()!;
			self.state = t.type == T_BLOCK_MAPPING_START ? BLOCK_MAPPING_KEY : FLOW_MAPPING_FIRST_KEY;
			e.type = MAPPING_START;
			e.explicit = t.type == T_FLOW_MAPPING_START;
			return e;
		default:
			break;
	}
	if (!props) return self.fail(t, "expected a node");
	self.state = self.states.pop()!!;
	e.type = SCALAR;
	return e;
}

fn Event? Parser.block_sequence_entry(&self)
{
	Token t = self.scanner.peek_token()!;
	if (t.type == T_BLOCK_END)
	{
		self.scanner.next_token()!;
		self.state = self.states.pop()!!;
		return { .type = SEQUENCE_END, .start = t.start };
	}
	if (t.type != T_BLOCK_ENTRY) return self.fail(t, "expected '-' or a less indented line");
	self.scanner.next_token()!;
	Token n = self.scanner.peek_token()!;
	if (n.is(T_BLOCK_ENTRY, T_BLOCK_END)) return empty_scalar(t.start);
	self.states.push(BLOCK_SEQUENCE_ENTRY);
	return self.node(false);
}

// "key:\n- a": entries at the mapping's own indent, no BLOCK_SEQUENCE_START/BLOCK_END.
fn Event? Parser.indentless_sequence_entry(&self)
{
	Token t = self.scanner.peek_token()!;
	if (t.type != T_BLOCK_ENTRY)
	{
		self.state = self.states.pop()!!;
		return { .type = SEQUENCE_END, .start = t.start };
	}
	self.scanner.next_token()!;
	Token n = self.scanner.peek_token()!;
	if (n.is(T_BLOCK_ENTRY, T_KEY, T_VALUE, T_BLOCK_END)) return empty_scalar(t.start);
	self.states.push(INDENTLESS_SEQUENCE_ENTRY);
	return self.node(false);
}

fn Event? Parser.block_mapping_key(&self)
{
	Token t = self.scanner.peek_token()!;
	switch (t.type)
	{
		case T_BLOCK_END:
			self.scanner.next_token()!;
			self.state = self.states.pop()!!;
			return { .type = MAPPING_END, .start = t.start };
		case T_VALUE:   // empty key
			self.state = BLOCK_MAPPING_VALUE;
			return empty_scalar(t.start);
		case T_KEY:
			self.scanner.next_token()!;
			Token n = self.scanner.peek_token()!;
			if (n.is(T_KEY, T_VALUE, T_BLOCK_END))
			{
				self.state = BLOCK_MAPPING_VALUE;
				return empty_scalar(t.start);
			}
			self.states.push(BLOCK_MAPPING_VALUE);
			return self.node(true);
		default:
			return self.fail(t, "expected a mapping key or a less indented line");
	}
}

fn Event? Parser.block_mapping_value(&self)
{
	Token t = self.scanner.peek_token()!;
	if (t.type != T_VALUE)
	{
		self.state = BLOCK_MAPPING_KEY;   // "? a" without ':'
		return empty_scalar(t.start);
	}
	self.scanner.next_token()!;
	Token n = self.scanner.peek_token()!;
	if (n.is(T_KEY, T_VALUE, T_BLOCK_END))
	{
		self.state = BLOCK_MAPPING_KEY;
		return empty_scalar(t.start);
	}
	self.states.push(BLOCK_MAPPING_KEY);
	return self.node(true);
}


// ---- flow collections ----------------------------------------------------

// Every entry but the first follows a ','; returns the token after it.
fn Token? Parser.flow_separator(&self, Token t, bool first, String msg)
{
	if (first) return t;
	if (t.type != T_FLOW_ENTRY) return self.scanner.error(t.start, msg)~;
	self.scanner.next_token()!;
	return self.scanner.peek_token()!;
}

// Entries are separated by ','; a trailing ',' before ']' is allowed.
fn Event? Parser.flow_sequence_entry(&self, bool first)
{
	Token t = self.scanner.peek_token()!;
	if (t.type != T_FLOW_SEQUENCE_END)
	{
		t = self.flow_separator(t, first, "expected ',' or ']'")!;
		if (t.type == T_KEY || t.type == T_VALUE)   // "[a: b]", "[? a : b]", "[: b]": a single-pair map
		{
			if (t.type == T_KEY) self.scanner.next_token()!;
			self.state = FLOW_SEQUENCE_ENTRY_MAPPING_KEY;
			return { .type = MAPPING_START, .explicit = true, .start = t.start };
		}
		if (t.type != T_FLOW_SEQUENCE_END)
		{
			self.states.push(FLOW_SEQUENCE_ENTRY);
			return self.node(false);
		}
	}
	self.scanner.next_token()!;
	self.state = self.states.pop()!!;
	return { .type = SEQUENCE_END, .start = t.start };
}

fn Event? Parser.flow_sequence_entry_mapping_key(&self)
{
	Token t = self.scanner.peek_token()!;
	self.state = FLOW_SEQUENCE_ENTRY_MAPPING_VALUE;
	if (t.is(T_VALUE, T_FLOW_ENTRY, T_FLOW_SEQUENCE_END)) return empty_scalar(t.start);
	self.states.push(FLOW_SEQUENCE_ENTRY_MAPPING_VALUE);
	return self.node(false);
}

fn Event? Parser.flow_sequence_entry_mapping_value(&self)
{
	Token t = self.scanner.peek_token()!;
	self.state = FLOW_SEQUENCE_ENTRY_MAPPING_END;
	if (t.type != T_VALUE) return empty_scalar(t.start);
	self.scanner.next_token()!;
	t = self.scanner.peek_token()!;
	if (t.is(T_FLOW_ENTRY, T_FLOW_SEQUENCE_END)) return empty_scalar(t.start);
	self.states.push(FLOW_SEQUENCE_ENTRY_MAPPING_END);
	return self.node(false);
}

// "{a: 1, b, : c}": a missing key or value is an empty scalar.
fn Event? Parser.flow_mapping_key(&self, bool first)
{
	Token t = self.scanner.peek_token()!;
	if (t.type != T_FLOW_MAPPING_END)
	{
		t = self.flow_separator(t, first, "expected ',' or '}'")!;
		if (t.type == T_KEY)
		{
			self.scanner.next_token()!;
			t = self.scanner.peek_token()!;
			if (t.is(T_VALUE, T_FLOW_ENTRY, T_FLOW_MAPPING_END))
			{
				self.state = FLOW_MAPPING_VALUE;
				return empty_scalar(t.start);
			}
			self.states.push(FLOW_MAPPING_VALUE);
			return self.node(false);
		}
		if (t.type == T_VALUE)
		{
			self.state = FLOW_MAPPING_VALUE;
			return empty_scalar(t.start);
		}
		if (t.type != T_FLOW_MAPPING_END)
		{
			self.states.push(FLOW_MAPPING_EMPTY_VALUE);
			return self.node(false);
		}
	}
	self.scanner.next_token()!;
	self.state = self.states.pop()!!;
	return { .type = MAPPING_END, .start = t.start };
}

fn Event? Parser.flow_mapping_value(&self, bool empty)
{
	Token t = self.scanner.peek_token()!;
	self.state = FLOW_MAPPING_KEY;
	if (empty || t.type != T_VALUE) return empty_scalar(t.start);
	self.scanner.next_token()!;
	t = self.scanner.peek_token()!;
	if (t.is(T_FLOW_ENTRY, T_FLOW_MAPPING_END)) return empty_scalar(t.start);
	self.states.push(FLOW_MAPPING_KEY);
	return self.node(false);
}
