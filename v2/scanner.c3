// Scanner: characters -> tokens for zero-allocation parsing.
// Ring token queue (QUEUE_SIZE = 2048), fixed indent stack (MAX_DEPTH = 256),
// fixed simple keys, in-place scalar decoding via InPlaceWriter.
module yaml2::parser @private;

import std::io;

enum TokenType : char
{
	T_STREAM_START, T_STREAM_END, T_DOCUMENT_START, T_DOCUMENT_END,
	T_BLOCK_SEQUENCE_START, T_BLOCK_MAPPING_START, T_BLOCK_END,
	T_FLOW_SEQUENCE_START, T_FLOW_SEQUENCE_END, T_FLOW_MAPPING_START, T_FLOW_MAPPING_END,
	T_BLOCK_ENTRY, T_FLOW_ENTRY, T_KEY, T_VALUE, T_SCALAR,
	T_ANCHOR, T_ALIAS, T_TAG, T_VERSION_DIRECTIVE, T_TAG_DIRECTIVE, T_RESERVED_DIRECTIVE
}

const char FLAG_IMPLIED_MAP = 1;
const char FLAG_IMPLIED_KEY = 2;

struct Token
{
	Span value;
	uint handle_off;
	uint pos;
	uint line;
	ushort col;
	ushort handle_len;
	TokenType type;
	ScalarStyle style;
	char flags;
	char pad;
}

fn Mark Token.start(self) @inline => { (sz)self.pos, (int)self.line, (int)self.col };
fn Span Token.handle(self) @inline => { self.handle_off, (uint)self.handle_len };
fn bool Token.implied_mapping_start(self) @inline => (self.flags & FLAG_IMPLIED_MAP) != 0;
fn bool Token.implied_key(self) @inline => (self.flags & FLAG_IMPLIED_KEY) != 0;

const char KEY_POSSIBLE   = 1;
const char KEY_REQUIRED   = 2;
const char KEY_COMPACT_OK = 4;
const char KEY_TAB_INDENT = 8;
const char KEY_FLOW_MAP   = 16;

struct SimpleKey
{
	sz token_number;   // absolute token index (tokens_taken + position after queue head)
	uint pos;
	uint line;
	ushort col;
	char flags;
	char pad;
}

fn Mark SimpleKey.mark(self) @inline => { (sz)self.pos, (int)self.line, (int)self.col };
fn bool SimpleKey.possible(self) @inline => (self.flags & KEY_POSSIBLE) != 0;
fn bool SimpleKey.required(self) @inline => (self.flags & KEY_REQUIRED) != 0;
fn bool SimpleKey.compact_ok(self) @inline => (self.flags & KEY_COMPACT_OK) != 0;
fn bool SimpleKey.tab_indent(self) @inline => (self.flags & KEY_TAB_INDENT) != 0;
fn bool SimpleKey.flow_map(self) @inline => (self.flags & KEY_FLOW_MAP) != 0;

struct Scanner
{
	char[] s;
	Arena* arena;
	Allocator spill;
	Mark mark;
	sz invalid_at;
	bool verbose;
	bool prev_blank;

	Token[QUEUE_SIZE] tokens;
	uint head;
	uint count;
	sz tokens_taken;

	bool stream_start_done;
	bool stream_end_done;
	int indent;
	int[MAX_DEPTH + 2] indents;
	int indents_len;

	bool simple_key_allowed;
	bool compact_ok;
	bool tab_indent;

	SimpleKey[MAX_DEPTH + 2] keys;
	int keys_len;

	int flow_level;
	bool json_node;
}

const String BOM = "\xef\xbb\xbf";   // U+FEFF, the UTF-8 byte order mark

fn void Scanner.init(&self, char[] buf, bool verbose, Arena* arena, Allocator spill)
{
	*self = {
		.verbose = verbose,
		.arena = arena,
		.spill = spill,
		.indent = -1,
		.prev_blank = true,
	};

	// In-place CRLF compaction: \r\n and \r -> \n
	uint r = 0;
	uint w = 0;
	uint blen = (uint)buf.len;
	while (r < blen)
	{
		char c = buf[r++];
		if (c == '\r')
		{
			buf[w++] = '\n';
			if (r < blen && buf[r] == '\n') r++;
		}
		else
		{
			buf[w++] = c;
		}
	}
	self.s = buf[0:w];

	// Leading BOM: do NOT remove from buf, start scanning at byte 3
	if (((String)self.s).starts_with(BOM))
	{
		self.mark = { 3, 1, 1 };
	}
	else
	{
		self.mark = { 0, 1, 1 };
	}

	self.invalid_at = first_invalid((String)self.s, self.mark.pos);

	self.keys[0] = {};
	self.keys_len = 1;
}

fn SimpleKey* Scanner.simple_key(&self) @inline => &self.keys[self.keys_len - 1];

fn bool is_flow_indicator(char c) => c == ',' || c == '[' || c == ']' || c == '{' || c == '}';
fn bool is_blankz(char c) => c.is_blank() || c == '\n' || c == '\0';

fn bool is_printable(Char32 c)
{
	return c == '\t' || c == '\n' || c == '\r' || (c >= 0x20 && c <= 0x7e) || c == 0x85
		|| (c >= 0xa0 && c <= 0xd7ff) || (c >= 0xe000 && c <= 0xfffd) || c >= 0x10000;
}

fn sz first_invalid(String s, sz start_pos)
{
	for (sz i = start_pos; i < s.len;)
	{
		if (s[i] >= 0x20 && s[i] < 0x7f)
		{
			i++;
			continue;
		}
		sz size = s.len - i;
		Char32? c = conv::utf8_to_char32(&s[i], &size);
		if (catch c) return i;
		if (!is_printable(c)) return i;
		i += size;
	}
	return s.len;
}

fn int Scanner.col(&self) @inline => self.mark.column - 1;
fn bool Scanner.at_end(&self) @inline => self.mark.pos >= self.s.len;

fn char Scanner.peek(&self, sz offset = 0)
{
	sz i = self.mark.pos + offset;
	return i < self.s.len ? self.s[i] : '\0';
}

fn void Scanner.advance(&self)
{
	if (self.at_end()) return;
	char c = self.s[self.mark.pos];
	self.prev_blank = is_blankz(c);
	if (c == '\n')
	{
		self.mark.line++;
		self.mark.column = 1;
	}
	else
	{
		self.mark.column++;
	}
	self.mark.pos++;
}

fn fault Scanner.error(&self, Mark m, String msg, fault f = SYNTAX_ERROR)
{
	if (self.verbose)
	{
		const sz EXCERPT = 60;
		sz col_offset = m.column > 1 ? (sz)(m.column - 1) : 0;
		sz start = m.pos >= col_offset ? m.pos - col_offset : 0;
		if (m.pos - start > EXCERPT) start = m.pos - EXCERPT;
		while (start < m.pos && conv::is_cont(self.s[start])) start++;

		sz end = m.pos < self.s.len ? m.pos : self.s.len;
		while (end < self.s.len && end - m.pos < EXCERPT && self.s[end] != '\n') end++;
		while (end > m.pos && end < self.s.len && conv::is_cont(self.s[end])) end--;
		if (end < start) end = start;

		(void)io::eprintfn("YAML ERROR -- Line %d, Col %d: %s", m.line, m.column, msg);
		int caret;
		print_excerpt((String)self.s[start:end - start], m.pos - start, &caret);
		(void)io::eprintfn("%*s^", caret, "");
	}
	return f;
}

fn void print_excerpt(String line, sz at, int* caret)
{
	char[256] out_buf;
	sz out_len = 0;
	*caret = 0;
	for (sz i = 0; i < line.len && out_len < 250;)
	{
		if (i <= at) *caret = (int)conv::utf8_codepoints((String)out_buf[0:out_len]);
		sz size = line.len - i;
		Char32? c = conv::utf8_to_char32(&line[i], &size);
		if (catch c) size = 1;
		if (try c && is_printable(c) && c != '\n')
		{
			for (sz k = 0; k < size && out_len < 250; k++) out_buf[out_len++] = line[i + k];
		}
		else
		{
			out_buf[out_len++] = '?';
		}
		i += size;
	}
	if (at >= line.len) *caret = (int)conv::utf8_codepoints((String)out_buf[0:out_len]);
	(void)io::eprintn((String)out_buf[0:out_len]);
}

// ---- token ring queue -----------------------------------------------------

fn sz Scanner.ring_index(&self, sz number) @inline
{
	sz dist = number - self.tokens_taken;
	return (sz)((self.head + (uint)dist) % QUEUE_SIZE);
}

fn void? Scanner.push(&self, TokenType type, Mark m, Span value = {}, ScalarStyle style = PLAIN, Span handle = {})
{
	if (self.count >= QUEUE_SIZE) return self.error(m, "token queue overflow", LIMIT_EXCEEDED)~;
	if (m.column > 65535) return self.error(m, "column limit exceeded", LIMIT_EXCEEDED)~;
	if (handle.len > 65535) return self.error(m, "tag handle length limit exceeded", LIMIT_EXCEEDED)~;
	uint idx = (self.head + self.count) % QUEUE_SIZE;
	self.tokens[idx] = {
		.value = value,
		.handle_off = handle.off,
		.handle_len = (ushort)handle.len,
		.pos = (uint)m.pos,
		.line = (uint)m.line,
		.col = (ushort)m.column,
		.type = type,
		.style = style,
	};
	self.count++;
}

fn Token? Scanner.next_token(&self)
{
	Token t = self.peek_token()!;
	Token* head_tok = &self.tokens[self.head];
	switch
	{
		case head_tok.implied_mapping_start(): head_tok.flags &= (char)~FLAG_IMPLIED_MAP;
		case head_tok.implied_key(): head_tok.flags &= (char)~FLAG_IMPLIED_KEY;
		default:
			self.tokens_taken++;
			self.head = (self.head + 1) % QUEUE_SIZE;
			self.count--;
	}
	return t;
}

fn Token? Scanner.peek_token(&self)
{
	self.fetch_more_tokens()!;
	Token t = self.tokens[self.head];
	if (t.implied_mapping_start()) return { .type = T_BLOCK_MAPPING_START, .pos = t.pos, .line = t.line, .col = t.col };
	if (t.implied_key()) return { .type = T_KEY, .pos = t.pos, .line = t.line, .col = t.col };
	return t;
}

fn void? Scanner.fetch_more_tokens(&self)
{
	while (true)
	{
		if (self.count > 0)
		{
			self.stale_simple_keys()!;
			bool head_may_be_key = false;
			for (int i = 0; i < self.keys_len; i++)
			{
				SimpleKey* k = &self.keys[i];
				if (k.possible() && k.token_number == self.tokens_taken)
				{
					head_may_be_key = true;
					break;
				}
			}
			if (!head_may_be_key) return;
		}
		if (self.stream_end_done) return;
		self.fetch_next_token()!;
	}
}

fn void? Scanner.fetch_next_token(&self)
{
	if (!self.stream_start_done)
	{
		if (self.s.len > MAX_INPUT)
		{
			return self.error(self.mark, "input size limit exceeded", LIMIT_EXCEEDED)~;
		}
		if (self.invalid_at < self.s.len)
		{
			while (self.mark.pos < self.invalid_at) self.advance();
			String msg = self.s[self.invalid_at] < 0x80 ? "control characters are not allowed" : "invalid UTF-8 or a non-printable character";
			return self.error(self.mark, msg, INVALID_CHARACTER)~;
		}
		self.stream_start_done = true;
		self.simple_key_allowed = true;
		self.compact_ok = true;
		self.push(T_STREAM_START, self.mark)!;
		return;
	}
	int prev_line = self.mark.line;
	self.scan_to_next_token()!;
	self.stale_simple_keys()!;
	bool json_key = self.json_node && (self.mark.line == prev_line || self.simple_key().flow_map());
	self.json_node = false;
	if (self.flow_level)
	{
		if (self.mark.line != prev_line && !self.at_end() && self.line_indent() <= self.indent)
		{
			return self.error(self.mark, "flow collection line is not indented enough", INVALID_INDENTATION)~;
		}
	}
	else
	{
		self.unroll_indent(self.col())!;
	}
	if (self.at_end()) return self.fetch_stream_end();
	char c = self.peek();
	char next = self.peek(1);
	bool flow = self.flow_level > 0;
	bool ends_indicator = is_blankz(next) || (flow && is_flow_indicator(next));
	if (c == '[' || c == '{') return self.fetch_flow_start(c == '[' ? T_FLOW_SEQUENCE_START : T_FLOW_MAPPING_START);
	if (c == ']' || c == '}') return self.fetch_flow_end(c == ']' ? T_FLOW_SEQUENCE_END : T_FLOW_MAPPING_END);
	if (c == ',') return self.fetch_flow_entry();
	if (c == '-' && ends_indicator)
	{
		if (flow) return self.error(self.mark, "block sequence entries are not allowed in a flow collection")~;
		return self.fetch_indicator(T_BLOCK_ENTRY, T_BLOCK_SEQUENCE_START, "block sequence entries are not allowed here");
	}
	if (c == ':' && (ends_indicator || (flow && json_key))) return self.fetch_value();
	if (c == '?' && ends_indicator) return self.fetch_indicator(T_KEY, T_BLOCK_MAPPING_START, "explicit keys are not allowed here");
	if (self.at_marker()) return self.fetch_document_indicator(c == '-' ? T_DOCUMENT_START : T_DOCUMENT_END);
	if (c == '\'' || c == '"') return self.fetch_flow_scalar(c == '\'');
	if (c == '|' || c == '>')
	{
		if (flow) return self.error(self.mark, "block scalars are not allowed in a flow collection")~;
		return self.fetch_block_scalar(c == '|');
	}
	if (c == '#') return self.error(self.mark, "a comment needs a blank before '#'")~;
	if (c == '%' && self.mark.column == 1 && !flow) return self.fetch_directive();
	if (c == '&' || c == '*') return self.fetch_anchor(c == '*');
	if (c == '!') return self.fetch_tag();
	if (INDICATORS.contains_char(c)) return self.error(self.mark, "a plain scalar cannot start with this character")~;
	return self.fetch_plain();
}

fn bool Scanner.bom_at(&self, sz i) @inline => ((String)self.s[i..]).starts_with(BOM);

fn void? Scanner.scan_to_next_token(&self)
{
	while (!self.at_end())
	{
		char c = self.peek();
		if (c == ' ')
		{
			self.advance();
		}
		else if (c == '\t')
		{
			if (self.compact_ok) self.tab_indent = true;
			self.compact_ok = false;
			self.advance();
		}
		else if (c == '#' && (self.mark.pos == 0 || self.prev_blank))
		{
			self.skip_line();
		}
		else if (c == '\n')
		{
			self.advance();
			self.simple_key_allowed = true;
			self.compact_ok = true;
			self.tab_indent = false;
		}
		else if (self.mark.column == 1 && !self.flow_level && self.bom_at(self.mark.pos))
		{
			for (int i = 0; i < BOM.len; i++) self.advance();
			self.mark.column = 1;
		}
		else
		{
			break;
		}
	}
	if (!self.at_end() && self.mark.column > 65535) return self.error(self.mark, "column limit exceeded", LIMIT_EXCEEDED)~;
}

// ---- indentation ---------------------------------------------------------

fn bool? Scanner.roll_indent(&self, int column)
{
	if (self.indent >= column) return false;
	if (column > 65535) return self.error(self.mark, "column limit exceeded", LIMIT_EXCEEDED)~;
	if (self.indents_len >= MAX_DEPTH) return self.error(self.mark, "indentation depth limit exceeded", LIMIT_EXCEEDED)~;
	self.indents[self.indents_len++] = self.indent;
	self.indent = column;
	return true;
}

fn void? Scanner.unroll_indent(&self, int column)
{
	while (self.indent > column)
	{
		self.push(T_BLOCK_END, self.mark)!;
		self.indent = self.indents[--self.indents_len];
	}
}

// ---- simple keys ---------------------------------------------------------

fn void? Scanner.save_simple_key(&self)
{
	if (!self.simple_key_allowed) return;
	if (self.mark.column > 65535) return self.error(self.mark, "column limit exceeded", LIMIT_EXCEEDED)~;
	self.remove_simple_key()!;
	SimpleKey* k = self.simple_key();
	char flags = KEY_POSSIBLE;
	if (k.flow_map()) flags |= KEY_FLOW_MAP;
	if (!self.flow_level && self.indent == self.col()) flags |= KEY_REQUIRED;
	if (self.compact_ok) flags |= KEY_COMPACT_OK;
	if (self.tab_indent) flags |= KEY_TAB_INDENT;
	*k = {
		.token_number = self.tokens_taken + (sz)self.count,
		.pos = (uint)self.mark.pos,
		.line = (uint)self.mark.line,
		.col = (ushort)self.mark.column,
		.flags = flags,
	};
}

fn void? Scanner.remove_simple_key(&self) => self.drop_key(self.simple_key());

fn void? Scanner.drop_key(&self, SimpleKey* k)
{
	if (k.possible() && k.required()) return self.error(k.mark(), "could not find expected ':'", MISSING_COLON)~;
	k.flags &= (char)~KEY_POSSIBLE;
}

fn void? Scanner.stale_simple_keys(&self)
{
	for (int i = 0; i < self.keys_len; i++)
	{
		SimpleKey* k = &self.keys[i];
		if (!k.possible()) continue;
		sz dist = self.tokens_taken + (sz)self.count - k.token_number;
		if (dist > QUEUE_SIZE - 8) return self.error(k.mark(), "implicit key too long", LIMIT_EXCEEDED)~;
		if (k.flow_map()) continue;
		if ((int)k.line == self.mark.line && self.mark.pos - (sz)k.pos <= 1024) continue;
		self.drop_key(k)!;
	}
}

// ---- indicators ----------------------------------------------------------

fn void? Scanner.fetch_stream_end(&self)
{
	if (self.flow_level) return self.error(self.mark, "unclosed flow collection: missing ']' or '}'", UNCLOSED_FLOW)~;
	self.unroll_indent(-1)!;
	self.remove_simple_key()!;
	self.simple_key_allowed = false;
	self.stream_end_done = true;
	self.push(T_STREAM_END, self.mark)!;
}

fn void? Scanner.fetch_indicator(&self, TokenType token, TokenType collection, String not_here)
{
	if (!self.flow_level)
	{
		if (self.tab_indent) return self.error(self.mark, "tab character in indentation", INVALID_TAB)~;
		if (self.indent < self.col())
		{
			if (!self.compact_ok || !self.simple_key_allowed) return self.error(self.mark, not_here)~;
			if (self.roll_indent(self.col())!) self.push(collection, self.mark)!;
		}
	}
	self.remove_simple_key()!;
	Mark m = self.mark;
	self.advance();
	self.simple_key_allowed = !self.flow_level;
	self.compact_ok = self.peek() == ' ';
	self.push(token, m)!;
}

fn void? Scanner.fetch_value(&self)
{
	SimpleKey* k = self.simple_key();
	if (k.possible())
	{
		if (!self.flow_level)
		{
			if (k.tab_indent()) return self.error(k.mark(), "tab character in indentation", INVALID_TAB)~;
			if (self.indent < (int)k.col - 1 && !k.compact_ok())
			{
				return self.error(k.mark(), "mapping values are not allowed here")~;
			}
		}
		Token* key = &self.tokens[self.ring_index(k.token_number)];
		key.flags |= FLAG_IMPLIED_KEY;
		if (!self.flow_level)
		{
			if (self.roll_indent((int)k.col - 1)!) key.flags |= FLAG_IMPLIED_MAP;
		}
		k.flags &= (char)~KEY_POSSIBLE;
		self.simple_key_allowed = false;
		self.compact_ok = false;
	}
	else if (!self.flow_level)
	{
		if (!self.simple_key_allowed) return self.error(self.mark, "mapping values are not allowed here")~;
		if (self.roll_indent(self.col())!) self.push(T_BLOCK_MAPPING_START, self.mark)!;
		self.simple_key_allowed = true;
		self.compact_ok = self.peek(1) == ' ';
	}
	else
	{
		self.simple_key_allowed = false;
	}
	Mark m = self.mark;
	self.advance();
	self.push(T_VALUE, m)!;
}

fn void? Scanner.fetch_flow_start(&self, TokenType type)
{
	if (self.flow_level >= MAX_DEPTH) return self.error(self.mark, "flow nesting depth limit exceeded", LIMIT_EXCEEDED)~;
	self.save_simple_key()!;
	char flags = (type == T_FLOW_MAPPING_START) ? KEY_FLOW_MAP : 0;
	self.keys[self.keys_len++] = { .flags = flags };
	self.flow_level++;
	Mark m = self.mark;
	self.advance();
	self.simple_key_allowed = true;
	self.compact_ok = false;
	self.push(type, m)!;
}

fn void? Scanner.fetch_flow_end(&self, TokenType type)
{
	if (!self.flow_level) return self.error(self.mark, "closing bracket without an opening one")~;
	if (self.simple_key().flow_map() != (type == T_FLOW_MAPPING_END)) return self.error(self.mark, "closing bracket does not match the opening one")~;
	self.remove_simple_key()!;
	self.keys_len--;
	self.flow_level--;
	Mark m = self.mark;
	self.advance();
	self.simple_key_allowed = false;
	self.json_node = true;
	self.push(type, m)!;
}

fn void? Scanner.fetch_flow_entry(&self)
{
	if (!self.flow_level) return self.error(self.mark, "',' outside a flow collection")~;
	self.remove_simple_key()!;
	Mark m = self.mark;
	self.advance();
	self.simple_key_allowed = true;
	self.push(T_FLOW_ENTRY, m)!;
}

const String INDICATORS = "%@`";

fn void? Scanner.fetch_document_indicator(&self, TokenType type)
{
	if (self.flow_level) return self.error(self.mark, "document marker inside a flow collection")~;
	self.unroll_indent(-1)!;
	self.remove_simple_key()!;
	self.simple_key_allowed = false;
	self.compact_ok = false;
	Mark m = self.mark;
	for (int i = 0; i < 3; i++) self.advance();
	if (type == T_DOCUMENT_END) self.end_of_line()!;
	self.push(type, m)!;
}

fn void Scanner.skip_line(&self)
{
	while (!self.at_end() && self.peek() != '\n') self.advance();
}

fn void? Scanner.end_of_line(&self, String msg = "unexpected text at the end of the line", fault f = SYNTAX_ERROR)
{
	sz blanks = self.mark.pos;
	self.skip_blanks();
	if (self.peek() == '#' && self.mark.pos > blanks) self.skip_line();
	if (!self.at_end() && self.peek() != '\n') return self.error(self.mark, msg, f)~;
}

fn bool Scanner.at_marker(&self) => self.mark.column == 1 && self.is_marker(self.mark.pos);

fn bool Scanner.is_marker(&self, sz i)
{
	if (self.bom_at(i)) i += BOM.len;
	if (i + 3 > self.s.len) return false;
	char c = self.s[i];
	return (c == '-' || c == '.') && self.s[i + 1] == c && self.s[i + 2] == c
		&& (i + 3 == self.s.len || is_blankz(self.s[i + 3]));
}

// Plain scalar: single line is identity span (no write, no blanking).
// Multiline folds in place into [orig_start, w) and blanks [w, orig_end).
fn void? Scanner.fetch_plain(&self)
{
	self.save_simple_key()!;
	Mark m = self.mark;
	int line = m.line;
	Span value = self.scan_plain()!;
	self.simple_key_allowed = self.mark.line != line;
	self.compact_ok = false;
	self.push(T_SCALAR, m, value)!;
}

fn Span? Scanner.scan_plain(&self)
{
	bool flow = self.flow_level > 0;
	sz start = self.mark.pos;
	sz end = start;

	// Line 1
	while (!self.at_end())
	{
		char c = self.peek();
		if (c == '\n' || (c == ':' && (is_blankz(self.peek(1)) || (flow && is_flow_indicator(self.peek(1)))))) break;
		if (flow && is_flow_indicator(c)) break;
		if (c == '#' && self.mark.pos > start && self.prev_blank) break;
		self.advance();
		if (!c.is_blank()) end = self.mark.pos;
	}

	if (self.peek() != '\n')
	{
		// Single line: identity span, NO write, NO blanking
		return (Span){ (uint)start, (uint)(end - start) };
	}

	// Look ahead to check if scalar continues on next line
	sz text = self.mark.pos;
	sz line_start = 0;
	int text_breaks = 0;
	while (text < self.s.len && (self.s[text] == '\n' || self.s[text].is_blank()))
	{
		if (self.s[text] == '\n')
		{
			text_breaks++;
			line_start = text + 1;
		}
		text++;
	}
	if (text >= self.s.len || self.spaces_at(line_start) <= self.indent || self.s[text] == '#' || self.is_marker(line_start) || (flow && is_flow_indicator(self.s[text])))
	{
		return (Span){ (uint)start, (uint)(end - start) };
	}

	// Multiline: begins in-place writing
	InPlaceWriter writer;
	writer.init(self.s, (uint)start, self.arena, self.spill);
	writer.w = (uint)end;

	while (self.mark.pos < text) self.advance();
	int breaks = text_breaks;

	while (true)
	{
		sz l_start = self.mark.pos;
		sz l_end = l_start;
		while (!self.at_end())
		{
			char c = self.peek();
			if (c == '\n' || (c == ':' && (is_blankz(self.peek(1)) || (flow && is_flow_indicator(self.peek(1)))))) break;
			if (flow && is_flow_indicator(c)) break;
			if (c == '#' && self.mark.pos > l_start && self.prev_blank) break;
			self.advance();
			if (!c.is_blank()) l_end = self.mark.pos;
		}
		if (l_end > l_start)
		{
			if (breaks == 1) writer.append_char(' ', (uint)self.mark.pos)!;
			for (int i = 1; i < breaks; i++) writer.append_char('\n', (uint)self.mark.pos)!;
			writer.append_slice(self.s[l_start:l_end - l_start], (uint)self.mark.pos)!;
		}
		if (self.peek() != '\n')
		{
			return writer.finish((uint)self.mark.pos);
		}

		// Look ahead again
		text = self.mark.pos;
		line_start = 0;
		text_breaks = 0;
		while (text < self.s.len && (self.s[text] == '\n' || self.s[text].is_blank()))
		{
			if (self.s[text] == '\n')
			{
				text_breaks++;
				line_start = text + 1;
			}
			text++;
		}
		if (text >= self.s.len || self.spaces_at(line_start) <= self.indent || self.s[text] == '#' || self.is_marker(line_start) || (flow && is_flow_indicator(self.s[text])))
		{
			return writer.finish((uint)self.mark.pos);
		}
		while (self.mark.pos < text) self.advance();
		breaks = text_breaks;
	}
}

fn int Scanner.spaces_at(&self, sz i)
{
	int n = 0;
	while (i + (sz)n < self.s.len && self.s[i + (sz)n] == ' ') n++;
	return n;
}

fn int Scanner.line_indent(&self) => self.spaces_at(self.mark.pos - (sz)self.col());

// ---- quoted scalars ------------------------------------------------------

fn void? Scanner.fetch_flow_scalar(&self, bool single)
{
	self.save_simple_key()!;
	Mark m = self.mark;
	Span value = self.scan_flow_scalar(single)!;
	self.simple_key_allowed = false;
	self.compact_ok = false;
	self.json_node = true;

	sz i = self.mark.pos;
	while (i < self.s.len && self.s[i].is_blank()) i++;
	char c = i < self.s.len ? self.s[i] : '\n';
	bool ok = c == '\n' || c == '#' || (c == ':' && (i + 1 == self.s.len || is_blankz(self.s[i + 1])));
	if (self.flow_level) ok |= c == ':' || c == ',' || c == ']' || c == '}';
	if (!ok) return self.error(self.mark, "unexpected text after a quoted scalar")~;
	self.push(T_SCALAR, m, value, single ? SINGLE : DOUBLE)!;
}

fn Span? Scanner.scan_flow_scalar(&self, bool single)
{
	Mark start = self.mark;
	uint orig_start = (uint)self.mark.pos;
	char quote = self.peek();
	self.advance();

	InPlaceWriter writer;
	writer.init(self.s, orig_start, self.arena, self.spill);

	while (true)
	{
		if (self.at_marker()) return self.error(self.mark, "document marker inside a quoted scalar")~;
		if (self.at_end()) return self.error(start, "unclosed quoted scalar", UNCLOSED_QUOTE)~;

		bool escaped_break = false;
		while (!self.at_end())
		{
			char c = self.peek();
			if (c.is_blank() || c == '\n') break;
			if (single && c == '\'' && self.peek(1) == '\'')
			{
				self.advance();
				self.advance();
				writer.append_char('\'', (uint)self.mark.pos)!;
				continue;
			}
			if (c == quote)
			{
				self.advance();
				return writer.finish((uint)self.mark.pos);
			}
			if (!single && c == '\\')
			{
				if (self.peek(1) == '\n')
				{
					self.advance();
					escaped_break = true;
					break;
				}
				self.scan_escape(&writer)!;
				continue;
			}
			self.advance();
			writer.append_char(c, (uint)self.mark.pos)!;
		}

		sz blanks = self.mark.pos;
		int breaks = 0;
		while (true)
		{
			char c = self.peek();
			if (c == '\n')
			{
				breaks++;
			}
			else if (!c.is_blank())
			{
				break;
			}
			self.advance();
		}
		if (breaks == 0)
		{
			if (self.mark.pos > blanks)
			{
				writer.append_slice(self.s[blanks:self.mark.pos - blanks], (uint)self.mark.pos)!;
			}
			continue;
		}
		if (!self.at_end() && self.line_indent() <= self.indent)
		{
			return self.error(self.mark, "continuation line of a quoted scalar is not indented enough", INVALID_INDENTATION)~;
		}
		if (breaks == 1 && !escaped_break) writer.append_char(' ', (uint)self.mark.pos)!;
		for (int i = 2; i <= breaks; i++) writer.append_char('\n', (uint)self.mark.pos)!;
	}
}

fn void? Scanner.scan_escape(&self, InPlaceWriter* writer)
{
	Mark m = self.mark;
	self.advance();
	char c = self.peek();
	self.advance();
	int digits = 0;
	switch (c)
	{
		case '0': writer.append_char('\0', (uint)self.mark.pos)!; return;
		case 'a': writer.append_char(0x07, (uint)self.mark.pos)!; return;
		case 'b': writer.append_char(0x08, (uint)self.mark.pos)!; return;
		case 't':
		case '\t': writer.append_char('\t', (uint)self.mark.pos)!; return;
		case 'n': writer.append_char('\n', (uint)self.mark.pos)!; return;
		case 'v': writer.append_char(0x0b, (uint)self.mark.pos)!; return;
		case 'f': writer.append_char(0x0c, (uint)self.mark.pos)!; return;
		case 'r': writer.append_char('\r', (uint)self.mark.pos)!; return;
		case 'e': writer.append_char(0x1b, (uint)self.mark.pos)!; return;
		case ' ':
		case '"':
		case '/':
		case '\\': writer.append_char(c, (uint)self.mark.pos)!; return;
		case 'N': writer.append_char32(0x85, (uint)self.mark.pos)!; return;
		case '_': writer.append_char32(0xa0, (uint)self.mark.pos)!; return;
		case 'L':
			if (catch err = writer.append_char32(0x2028, (uint)self.mark.pos))
			{
				if (err == NO_SPACE) return self.error(m, "scalar does not fit in place (\\L/\\P); give the parser a spill allocator", NO_SPACE)~;
				return err~;
			}
			return;
		case 'P':
			if (catch err = writer.append_char32(0x2029, (uint)self.mark.pos))
			{
				if (err == NO_SPACE) return self.error(m, "scalar does not fit in place (\\L/\\P); give the parser a spill allocator", NO_SPACE)~;
				return err~;
			}
			return;
		case 'x': digits = 2;
		case 'u': digits = 4;
		case 'U': digits = 8;
		default: return self.error(m, "invalid escape sequence", INVALID_ESCAPE)~;
	}
	uint code = 0;
	for (int i = 0; i < digits; i++)
	{
		char h = self.peek();
		if (!h.is_xdigit()) return self.error(m, "invalid hex digit in escape sequence", INVALID_ESCAPE)~;
		code = code * 16 + h.from_hex();
		self.advance();
	}
	if (code > 0x10ffff || (code >= 0xd800 && code <= 0xdfff)) return self.error(m, "invalid Unicode code point", INVALID_ESCAPE)~;
	writer.append_char32((Char32)code, (uint)self.mark.pos)!;
}

// ---- block scalars -------------------------------------------------------

fn void? Scanner.fetch_block_scalar(&self, bool literal)
{
	self.remove_simple_key()!;
	Mark m = self.mark;
	Span value = self.scan_block_scalar(literal)!;
	self.simple_key_allowed = true;
	self.compact_ok = true;
	self.tab_indent = false;
	self.push(T_SCALAR, m, value, literal ? LITERAL : FOLDED)!;
}

enum Chomp : char { CLIP, STRIP, KEEP }

fn Span? Scanner.scan_block_scalar(&self, bool literal)
{
	uint orig_start = (uint)self.mark.pos;
	self.advance();

	Chomp chomp = CLIP;
	int increment = 0;
	while (true)
	{
		char c = self.peek();
		if ((c == '-' || c == '+') && chomp == CLIP)
		{
			chomp = c == '+' ? KEEP : STRIP;
		}
		else if (c >= '1' && c <= '9' && !increment)
		{
			increment = c - '0';
		}
		else if ((c >= '0' && c <= '9') || c == '-' || c == '+')
		{
			return self.error(self.mark, "invalid block scalar header", INVALID_BLOCK_HEADER)~;
		}
		else
		{
			break;
		}
		self.advance();
	}
	self.end_of_line("invalid block scalar header", INVALID_BLOCK_HEADER)!;
	self.advance();

	int min_indent = self.indent + 1;
	int indent = increment ? (self.indent > 0 ? self.indent : 0) + increment : -1;
	int max_empty = 0;
	int breaks = self.block_breaks(indent, min_indent, &max_empty)!;
	if (indent < 0)
	{
		indent = self.col() > min_indent ? self.col() : min_indent;
		if (!self.at_end() && self.col() >= min_indent && max_empty > self.col())
		{
			return self.error(self.mark, "leading empty lines are more indented than the content", INVALID_INDENTATION)~;
		}
	}

	InPlaceWriter writer;
	writer.init(self.s, orig_start, self.arena, self.spill);

	bool line_break = false;
	bool more_indented = false;
	while (self.col() == indent && !self.at_end() && !self.at_marker())
	{
		bool blank = self.peek().is_blank();
		if (!literal && line_break && !more_indented && !blank)
		{
			if (!breaks) writer.append_char(' ', (uint)self.mark.pos)!;
		}
		else if (line_break)
		{
			writer.append_char('\n', (uint)self.mark.pos)!;
		}
		for (int i = 0; i < breaks; i++) writer.append_char('\n', (uint)self.mark.pos)!;
		more_indented = blank;
		sz from = self.mark.pos;
		self.skip_line();
		if (self.mark.pos > from)
		{
			writer.append_slice(self.s[from:self.mark.pos - from], (uint)self.mark.pos)!;
		}
		line_break = true;
		breaks = 0;
		if (self.at_end()) break;
		self.advance();
		breaks = self.block_breaks(indent, min_indent, &max_empty)!;
	}
	if (chomp != STRIP && line_break) writer.append_char('\n', (uint)self.mark.pos)!;
	if (chomp == KEEP) for (int i = 0; i < breaks; i++) writer.append_char('\n', (uint)self.mark.pos)!;
	return writer.finish((uint)self.mark.pos);
}

fn int? Scanner.block_breaks(&self, int indent, int min_indent, int* max_empty)
{
	int breaks = 0;
	while (true)
	{
		sz line = self.mark.pos;
		while ((indent < 0 || self.col() < indent) && self.peek() == ' ') self.advance();
		if (self.peek() == '\t' && self.col() < (indent < 0 ? min_indent : indent))
		{
			return self.error(self.mark, "tab character where indentation is expected", INVALID_TAB)~;
		}
		if (self.at_end() && self.mark.pos > line) return breaks + 1;
		if (self.peek() != '\n') return breaks;
		if (indent < 0 && self.col() > *max_empty) *max_empty = self.col();
		self.advance();
		breaks++;
	}
}

// ---- node properties and directives ----------------------------------------

fn void Scanner.skip_blanks(&self)
{
	while (self.peek().is_blank()) self.advance();
}

fn Span Scanner.scan_word(&self)
{
	sz from = self.mark.pos;
	while (!is_blankz(self.peek()) && !is_flow_indicator(self.peek())) self.advance();
	return { (uint)from, (uint)(self.mark.pos - from) };
}

fn void? Scanner.fetch_anchor(&self, bool is_alias)
{
	self.save_simple_key()!;
	self.simple_key_allowed = false;
	Mark m = self.mark;
	self.advance();
	Span name = self.scan_word();
	if (!name.len) return self.error(m, is_alias ? "alias without a name" : "anchor without a name")~;
	self.push(is_alias ? T_ALIAS : T_ANCHOR, m, name)!;
}

fn bool is_word_char(char c) => c.is_alnum() || c == '-';

fn Span? Scanner.scan_tag_uri(&self, bool verbatim)
{
	uint orig_start = (uint)self.mark.pos;
	InPlaceWriter writer;
	writer.init(self.s, orig_start, self.arena, self.spill);

	while (true)
	{
		char c = self.peek();
		if (c == '%')
		{
			char hi = self.peek(1);
			char lo = self.peek(2);
			if (!hi.is_xdigit() || !lo.is_xdigit()) return self.error(self.mark, "invalid '%' escape in a tag", INVALID_ESCAPE)~;
			for (int i = 0; i < 3; i++) self.advance();
			writer.append_char((char)(hi.from_hex() * 16 + lo.from_hex()), (uint)self.mark.pos)!;
			continue;
		}
		if (!c.is_alnum() && !"-#;/?:@&=+$_.~*'()".contains_char(c) && !(verbatim && "!,[]".contains_char(c))) break;
		self.advance();
		writer.append_char(c, (uint)self.mark.pos)!;
	}
	return writer.finish((uint)self.mark.pos);
}

fn void? Scanner.fetch_tag(&self)
{
	self.save_simple_key()!;
	self.simple_key_allowed = false;
	Mark m = self.mark;
	Span handle = {};
	Span suffix = {};
	if (self.peek(1) == '<')
	{
		self.advance();
		self.advance();
		suffix = self.scan_tag_uri(true)!;
		if (self.peek() != '>' || !suffix.len) return self.error(m, "invalid verbatim tag")~;
		self.advance();
	}
	else
	{
		sz n = 1;
		while (is_word_char(self.peek(n))) n++;
		if (self.peek(n) == '!')
		{
			if (n + 1 > 65535) return self.error(m, "tag handle length limit exceeded", LIMIT_EXCEEDED)~;
			handle = { (uint)self.mark.pos, (uint)(n + 1) };
			for (sz i = 0; i <= n; i++) self.advance();
		}
		else
		{
			handle = { (uint)self.mark.pos, 1 };
			self.advance();
		}
		suffix = self.scan_tag_uri(false)!;
		if (handle.len > 1 && !suffix.len) return self.error(m, "tag without a suffix")~;
	}
	char c = self.peek();
	if (!is_blankz(c) && !(self.flow_level && is_flow_indicator(c))) return self.error(self.mark, "a tag must be followed by a blank")~;
	self.push(T_TAG, m, suffix, handle: handle)!;
}

fn void? Scanner.fetch_directive(&self)
{
	self.unroll_indent(-1)!;
	self.remove_simple_key()!;
	self.simple_key_allowed = false;
	Mark m = self.mark;
	self.advance();
	Span name_span = self.scan_word();
	String name = (String)self.s[name_span.off:name_span.len];
	self.skip_blanks();
	switch (name)
	{
		case "YAML":
			sz from = self.mark.pos;
			while (self.peek().is_digit()) self.advance();
			if (self.peek() != '.' || self.mark.pos == from) return self.error(self.mark, "invalid %YAML version", INVALID_DIRECTIVE)~;
			self.advance();
			if (!self.peek().is_digit()) return self.error(self.mark, "invalid %YAML version", INVALID_DIRECTIVE)~;
			while (self.peek().is_digit()) self.advance();
			Span version_span = { (uint)from, (uint)(self.mark.pos - from) };
			String version = (String)self.s[version_span.off:version_span.len];
			if (!version.starts_with("1.")) return self.error(m, "unsupported YAML major version", INVALID_DIRECTIVE)~;
			self.end_of_line()!;
			self.push(T_VERSION_DIRECTIVE, m, version_span)!;
		case "TAG":
			Span handle = self.scan_word();
			if (handle.len > 65535) return self.error(m, "tag handle length limit exceeded", LIMIT_EXCEEDED)~;
			String handle_str = (String)self.s[handle.off:handle.len];
			bool ok = handle_str == "!" || (handle_str.len >= 2 && handle_str[0] == '!' && handle_str[^1] == '!');
			if (handle_str.len > 2) foreach (c : handle_str[1:handle_str.len - 2]) ok &= is_word_char(c);
			if (!ok) return self.error(m, "invalid %TAG handle", INVALID_DIRECTIVE)~;
			self.skip_blanks();
			if (is_flow_indicator(self.peek())) return self.error(self.mark, "invalid %TAG prefix", INVALID_DIRECTIVE)~;
			Mark pm = self.mark;
			Span prefix = self.scan_tag_uri(true)!;
			if (!prefix.len) return self.error(pm, "invalid %TAG prefix", INVALID_DIRECTIVE)~;
			self.end_of_line()!;
			self.push(T_TAG_DIRECTIVE, m, prefix, handle: handle)!;
		default:
			self.skip_line();
			self.push(T_RESERVED_DIRECTIVE, m, name_span)!;
	}
}
