// Parser: tokens -> events (libyaml-style state machine with a state stack).
module yaml::parser;
import std::io, std::collections::list;


enum State : char
{
	STREAM_START, IMPLICIT_DOCUMENT_START, DOCUMENT_START, DOCUMENT_CONTENT, DOCUMENT_END,
	BLOCK_NODE, BLOCK_SEQUENCE_ENTRY, INDENTLESS_SEQUENCE_ENTRY,
	BLOCK_MAPPING_KEY, BLOCK_MAPPING_VALUE, END
}

struct Parser
{
	Scanner scanner;
	State state;
	List {State} states;   // where to continue after the current node
}

fn Parser* Parser.init(&self, String input, bool verbose = true)
{
	*self = {};
	self.scanner.init(input, verbose);
	self.states.tinit();
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
		case END: return SYNTAX_ERROR~;
	}
}

fn Event empty_scalar(Mark m) => { .type = SCALAR, .start = m };

fn bool Parser.peek_is(&self, Token t, TokenType... types)
{
	foreach (type : types) if (t.type == type) return true;
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
	self.states.push(DOCUMENT_END);
	if (t.type == T_DOCUMENT_START)
	{
		self.scanner.next_token()!;
		self.state = DOCUMENT_CONTENT;
		return { .type = DOCUMENT_START, .explicit = true, .start = t.start };
	}
	if (!implicit) return self.fail(t, "expected '---' before a new document");
	self.state = BLOCK_NODE;
	return { .type = DOCUMENT_START, .start = t.start };
}

fn Event? Parser.document_content(&self)
{
	Token t = self.scanner.peek_token()!;
	if (self.peek_is(t, T_DOCUMENT_START, T_DOCUMENT_END, T_STREAM_END))
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
	return { .type = DOCUMENT_END, .explicit = explicit, .start = t.start };
}

// One node; the state to return to is on top of `states`.
fn Event? Parser.node(&self, bool indentless_sequence)
{
	Token t = self.scanner.peek_token()!;
	switch (t.type)
	{
		case T_BLOCK_ENTRY:
			if (!indentless_sequence) break;
			self.state = INDENTLESS_SEQUENCE_ENTRY;
			return { .type = SEQUENCE_START, .start = t.start };
		case T_SCALAR:
			self.scanner.next_token()!;
			self.state = self.states.pop()!!;
			return { .type = SCALAR, .style = t.style, .value = t.value, .start = t.start };
		case T_BLOCK_SEQUENCE_START:
			self.scanner.next_token()!;
			self.state = BLOCK_SEQUENCE_ENTRY;
			return { .type = SEQUENCE_START, .start = t.start };
		case T_BLOCK_MAPPING_START:
			self.scanner.next_token()!;
			self.state = BLOCK_MAPPING_KEY;
			return { .type = MAPPING_START, .start = t.start };
		default:
			break;
	}
	return self.fail(t, "expected a node");
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
	if (self.peek_is(n, T_BLOCK_ENTRY, T_BLOCK_END)) return empty_scalar(t.start);
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
	if (self.peek_is(n, T_BLOCK_ENTRY, T_KEY, T_VALUE, T_BLOCK_END)) return empty_scalar(t.start);
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
			if (self.peek_is(n, T_KEY, T_VALUE, T_BLOCK_END))
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
	if (self.peek_is(n, T_KEY, T_VALUE, T_BLOCK_END))
	{
		self.state = BLOCK_MAPPING_KEY;
		return empty_scalar(t.start);
	}
	self.states.push(BLOCK_MAPPING_KEY);
	return self.node(true);
}

