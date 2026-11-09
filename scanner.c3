// Scanner: characters -> tokens (libyaml style: indent stack, simple keys, one token queue).
module yaml::parser;
import std::io, std::collections::list;

faultdef INVALID_CHARACTER, INVALID_INDENTATION, MISSING_COLON, INVALID_TAB, INVALID_ESCAPE, UNCLOSED_QUOTE,
	INVALID_BLOCK_HEADER, UNCLOSED_FLOW, INVALID_DIRECTIVE, UNDEFINED_TAG_HANDLE;

enum TokenType : char
{
	T_STREAM_START, T_STREAM_END, T_DOCUMENT_START, T_DOCUMENT_END,
	T_BLOCK_SEQUENCE_START, T_BLOCK_MAPPING_START, T_BLOCK_END,
	T_FLOW_SEQUENCE_START, T_FLOW_SEQUENCE_END, T_FLOW_MAPPING_START, T_FLOW_MAPPING_END,
	T_BLOCK_ENTRY, T_FLOW_ENTRY, T_KEY, T_VALUE, T_SCALAR,
	T_ANCHOR, T_ALIAS, T_TAG, T_VERSION_DIRECTIVE, T_TAG_DIRECTIVE, T_RESERVED_DIRECTIVE
}

// value: scalar text, anchor/alias name, tag suffix, YAML version, TAG prefix or directive name.
// handle: tag handle ("" for a verbatim tag) or TAG directive handle.
struct Token { TokenType type; Mark start; String value; String handle; ScalarStyle style; }

// A possible implicit key: the token that may become a KEY when a ':' follows on the same line.
struct SimpleKey
{
	bool possible;
	bool required;     // block context and key at the current indent: losing it is an error
	bool compact_ok;   // may open a new block mapping on this line
	bool tab_indent;   // its line has a TAB in the indentation
	bool flow_map;     // the level is a flow mapping: the key may span lines ("{a\n: b}")
	sz token_number;   // absolute token index (tokens_taken + position after the queue head)
	Mark mark;
}

struct Scanner
{
	String s;
	Mark mark;
	sz invalid;                // the first byte that may not appear in a YAML stream, or s.len
	bool verbose;
	List {Token} tokens;
	sz tokens_taken;           // tokens already handed to the parser
	sz head;                   // index of the next token in `tokens` (no O(n) pop_first)
	bool stream_start_done;
	bool stream_end_done;
	int indent;                // 0-based column of the current block, -1 at stream level
	List {int} indents;
	bool simple_key_allowed;
	bool compact_ok;           // true at line start and after '-', '?', ':'(explicit) + spaces
	bool tab_indent;           // current line has a TAB before its first token
	List {SimpleKey} keys;     // one possible simple key per flow level, [0] = block context
	int flow_level;            // depth of '[' / '{' nesting
	int json_line;             // line of a just scanned quoted scalar or flow end ("{"a":b}"), or 0
}

fn void Scanner.init(&self, String s, bool verbose = true)
{
	if (s.starts_with("\xef\xbb\xbf")) s = s[3..];   // a byte order mark is not content
	*self = { .s = normalize_breaks(s), .mark = { 0, 1, 1 }, .verbose = verbose, .indent = -1 };
	self.invalid = first_invalid(self.s);
	self.tokens.tinit();
	self.indents.tinit();
	self.keys.tinit();
	self.keys.push({});
}

// The simple key slot of the current flow level.
fn SimpleKey* Scanner.key(&self) @inline => self.keys.get_ref(self.keys.len() - 1);

fn bool is_flow_indicator(char c) => c == ',' || c == '[' || c == ']' || c == '{' || c == '}';

// "\r\n" and "\r" are line breaks: rewrite them as "\n" (a tmem copy, only if needed).
fn String normalize_breaks(String s)
{
	if (!s.contains_char('\r')) return s;
	DString out = dstring::temp();
	foreach (i, c : s)
	{
		if (c != '\r')
		{
			out.append_char(c);
		}
		else if (i + 1 >= s.len || s[i + 1] != '\n')
		{
			out.append_char('\n');
		}
	}
	return out.str_view();
}

// YAML 1.2.2 5.1: the printable Unicode characters (TAB, LF, CR, no other C0/C1 control, no DEL,
// surrogate, FFFE or FFFF).
fn bool is_printable(Char32 c)
{
	return c == '\t' || c == '\n' || c == '\r' || (c >= 0x20 && c <= 0x7e) || c == 0x85
		|| (c >= 0xa0 && c <= 0xd7ff) || (c >= 0xe000 && c <= 0xfffd) || c >= 0x10000;
}

// The position of the first byte that is not valid UTF-8 (5.2) or not printable, or s.len.
fn sz first_invalid(String s)
{
	for (sz i = 0; i < s.len;)
	{
		if (s[i] >= 0x20 && s[i] < 0x7f)   // most of the input
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
fn bool is_blankz(char c) => c.is_blank() || c == '\n' || c == '\0';   // '\0': the end; no '\r' after normalize_breaks

fn void Scanner.advance(&self)
{
	if (self.at_end()) return;
	if (self.s[self.mark.pos] == '\n')
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

// Report an error (unless !verbose) and return its fault: `return self.error(m, msg)~;`.
fn fault Scanner.error(&self, Mark m, String msg, fault f = SYNTAX_ERROR)
{
	if (self.verbose)
	{
		// the line around the error, at most EXCERPT bytes on each side and not inside a
		// UTF-8 character: a long line cannot flood stderr
		const sz EXCERPT = 60;
		sz start = m.pos;
		while (start > 0 && m.pos - start < EXCERPT && self.s[start - 1] != '\n') start--;
		while (start < m.pos && conv::is_cont(self.s[start])) start++;
		sz end = m.pos;
		while (end < self.s.len && end - m.pos < EXCERPT && self.s[end] != '\n') end++;
		while (end > m.pos && end < self.s.len && conv::is_cont(self.s[end])) end--;
		(void)io::eprintfn("YAML ERROR -- Line %d, Col %d: %s", m.line, m.column, msg);
		(void)io::eprintn(self.s[start:end - start]);
		(void)io::eprintfn("%*s^", (int)conv::utf8_codepoints(self.s[start:m.pos - start]), "");
	}
	return f;
}

// ---- token queue ---------------------------------------------------------

fn Token? Scanner.next_token(&self)
{
	self.fetch_more_tokens()!;
	self.tokens_taken++;
	Token t = self.tokens[self.head++];   // the queue is reset once it is drained
	if (self.head == self.tokens.len())
	{
		self.tokens.clear();
		self.head = 0;
	}
	return t;
}

// The position in `tokens` of the absolute token index `number`.
fn sz Scanner.queue_index(&self, sz number) @inline => self.head + number - self.tokens_taken;

fn Token? Scanner.peek_token(&self)
{
	self.fetch_more_tokens()!;
	return self.tokens[self.head];
}

// Fetch until the head token can no longer become a KEY.
fn void? Scanner.fetch_more_tokens(&self)
{
	while (true)
	{
		if (self.tokens.len() > self.head)
		{
			self.stale_simple_keys()!;
			bool head_may_be_key = false;
			foreach (k : self.keys) head_may_be_key |= k.possible && k.token_number == self.tokens_taken;
			if (!head_may_be_key) return;
		}
		if (self.stream_end_done) return;
		self.fetch_next_token()!;
	}
}

fn void Scanner.push(&self, TokenType type, Mark m, String value = "", ScalarStyle style = PLAIN, String handle = "")
{
	self.tokens.push({ .type = type, .start = m, .value = value, .style = style, .handle = handle });
}

fn void? Scanner.fetch_next_token(&self)
{
	if (!self.stream_start_done)
	{
		if (self.invalid < self.s.len)
		{
			while (self.mark.pos < self.invalid) self.advance();
			String msg = self.s[self.invalid] < 0x80 ? "control characters are not allowed" : "invalid UTF-8 or a non-printable character";
			return self.error(self.mark, msg, INVALID_CHARACTER)~;
		}
		self.stream_start_done = true;
		self.simple_key_allowed = true;
		self.compact_ok = true;
		self.push(T_STREAM_START, self.mark);
		return;
	}
	int line = self.mark.line;
	self.scan_to_next_token();
	self.stale_simple_keys()!;
	// the previous token is a JSON-like key: ':' may follow directly (in a flow map, on a later line)
	bool json_key = self.json_line && (self.json_line == self.mark.line || self.key().flow_map);
	self.json_line = 0;
	if (self.flow_level)
	{
		// every line inside a flow collection is indented more than the enclosing block
		if (self.mark.line != line && !self.at_end() && self.line_indent() <= self.indent)
		{
			return self.error(self.mark, "flow collection line is not indented enough", INVALID_INDENTATION)~;
		}
	}
	else
	{
		self.unroll_indent(self.col());
	}
	if (self.at_end()) return self.fetch_stream_end();
	char c = self.peek();
	char n = self.peek(1);
	bool flow = self.flow_level > 0;
	bool ends_indicator = is_blankz(n) || (flow && is_flow_indicator(n));   // "- ", "? ", ": " (flow: "-,")
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

// Skip blanks, comments and line breaks. Sets simple_key_allowed / compact_ok at a new line.
fn void Scanner.scan_to_next_token(&self)
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
			if (self.compact_ok) self.tab_indent = true;   // TAB before the first token
			self.compact_ok = false;
			self.advance();
		}
		else if (c == '#' && (self.mark.pos == 0 || is_blankz(self.s[self.mark.pos - 1])))
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
		else
		{
			return;
		}
	}
}

// ---- indentation ---------------------------------------------------------

// Open a block collection at `column` if it is deeper than the current indent.
// `number` < 0: append the token; otherwise insert it at that absolute token index.
fn void Scanner.roll_indent(&self, int column, TokenType type, Mark m, sz number = -1)
{
	if (self.indent >= column) return;
	self.indents.push(self.indent);
	self.indent = column;
	Token t = { .type = type, .start = m };
	if (number < 0)
	{
		self.tokens.push(t);
	}
	else
	{
		self.tokens.insert_at(self.queue_index(number), t);
	}
}

fn void Scanner.unroll_indent(&self, int column)
{
	while (self.indent > column)
	{
		self.push(T_BLOCK_END, self.mark);
		self.indent = self.indents.pop()!!;
	}
}

// ---- simple keys ---------------------------------------------------------

fn void? Scanner.save_simple_key(&self)
{
	if (!self.simple_key_allowed) return;
	self.remove_simple_key()!;
	SimpleKey* k = self.key();
	*k = {
		.possible = true,
		.flow_map = k.flow_map,
		.required = !self.flow_level && self.indent == self.col(),
		.compact_ok = self.compact_ok,
		.tab_indent = self.tab_indent,
		.token_number = self.tokens_taken + self.tokens.len() - self.head,
		.mark = self.mark,
	};
}

fn void? Scanner.remove_simple_key(&self) => self.drop_key(self.key());

// A key that can no longer get its ':'; losing a required one is an error.
fn void? Scanner.drop_key(&self, SimpleKey* k)
{
	if (k.possible && k.required) return self.error(k.mark, "could not find expected ':'", MISSING_COLON)~;
	k.possible = false;
}

// Implicit keys are single-line and at most 1024 characters; keys in a flow mapping have no limit.
fn void? Scanner.stale_simple_keys(&self)
{
	foreach (&k : self.keys)
	{
		if (!k.possible || k.flow_map) continue;
		if (k.mark.line == self.mark.line && self.mark.pos - k.mark.pos <= 1024) continue;
		self.drop_key(k)!;
	}
}

// ---- indicators ----------------------------------------------------------

fn void? Scanner.fetch_stream_end(&self)
{
	if (self.flow_level) return self.error(self.mark, "unclosed flow collection: missing ']' or '}'", UNCLOSED_FLOW)~;
	self.unroll_indent(-1);
	self.remove_simple_key()!;
	self.simple_key_allowed = false;
	self.stream_end_done = true;
	self.push(T_STREAM_END, self.mark);
}

// '-' (block entry, block context only) or '?' (explicit key). In block context the indicator
// may open a new block collection at its column, but only where compact_ok allows it.
fn void? Scanner.fetch_indicator(&self, TokenType token, TokenType collection, String not_here)
{
	if (!self.flow_level)
	{
		if (self.tab_indent) return self.error(self.mark, "tab character in indentation", INVALID_TAB)~;
		if (self.indent < self.col())
		{
			if (!self.compact_ok || !self.simple_key_allowed) return self.error(self.mark, not_here)~;
			self.roll_indent(self.col(), collection, self.mark);
		}
	}
	self.remove_simple_key()!;
	Mark m = self.mark;
	self.advance();
	self.simple_key_allowed = !self.flow_level;
	self.compact_ok = self.peek() == ' ';   // "-\t-" may not nest
	self.push(token, m);
}

fn void? Scanner.fetch_value(&self)
{
	SimpleKey* k = self.key();
	if (k.possible)
	{
		if (!self.flow_level)
		{
			if (k.tab_indent) return self.error(k.mark, "tab character in indentation", INVALID_TAB)~;
			if (self.indent < k.mark.column - 1 && !k.compact_ok)
			{
				return self.error(k.mark, "mapping values are not allowed here")~;
			}
		}
		self.tokens.insert_at(self.queue_index(k.token_number), { .type = T_KEY, .start = k.mark });
		if (!self.flow_level) self.roll_indent(k.mark.column - 1, T_BLOCK_MAPPING_START, k.mark, k.token_number);
		k.possible = false;
		self.simple_key_allowed = false;
		self.compact_ok = false;   // "a: - b", "a: b: c"
	}
	else if (!self.flow_level)
	{
		// value of an explicit '?' key, or an empty key
		if (!self.simple_key_allowed) return self.error(self.mark, "mapping values are not allowed here")~;
		self.roll_indent(self.col(), T_BLOCK_MAPPING_START, self.mark);
		self.simple_key_allowed = true;
		self.compact_ok = self.peek(1) == ' ';
	}
	else
	{
		self.simple_key_allowed = false;   // "{? a : b}", "{: b}"
	}
	Mark m = self.mark;
	self.advance();
	self.push(T_VALUE, m);
}

// '[' or '{': the collection may itself be an implicit key ("[a]: b").
fn void? Scanner.fetch_flow_start(&self, TokenType type)
{
	// also bounds the per-token work over `keys`, which grows with the flow level
	if (self.flow_level >= MAX_DEPTH) return self.error(self.mark, "flow nesting depth limit exceeded", LIMIT_EXCEEDED)~;
	self.save_simple_key()!;
	self.keys.push({ .flow_map = type == T_FLOW_MAPPING_START });
	self.flow_level++;
	Mark m = self.mark;
	self.advance();
	self.simple_key_allowed = true;
	self.compact_ok = false;
	self.push(type, m);
}

fn void? Scanner.fetch_flow_end(&self, TokenType type)
{
	if (!self.flow_level) return self.error(self.mark, "closing bracket without an opening one")~;
	if (self.key().flow_map != (type == T_FLOW_MAPPING_END)) return self.error(self.mark, "closing bracket does not match the opening one")~;
	self.remove_simple_key()!;
	self.keys.pop()!!;
	self.flow_level--;
	Mark m = self.mark;
	self.advance();
	self.simple_key_allowed = false;
	self.json_line = self.mark.line;
	self.push(type, m);
}

fn void? Scanner.fetch_flow_entry(&self)
{
	if (!self.flow_level) return self.error(self.mark, "',' outside a flow collection")~;
	self.remove_simple_key()!;
	Mark m = self.mark;
	self.advance();
	self.simple_key_allowed = true;
	self.push(T_FLOW_ENTRY, m);
}

const String INDICATORS = "%@`";   // '%' outside column 1, reserved '@' and '`'

fn void? Scanner.fetch_document_indicator(&self, TokenType type)
{
	if (self.flow_level) return self.error(self.mark, "document marker inside a flow collection")~;
	self.unroll_indent(-1);
	self.remove_simple_key()!;
	self.simple_key_allowed = false;
	self.compact_ok = false;   // "--- a: b" (9KBC) and "--- - a" may not open a block collection
	Mark m = self.mark;
	for (int i = 0; i < 3; i++) self.advance();
	if (type == T_DOCUMENT_END) self.end_of_line()!;   // "... text" (3HFZ)
	self.push(type, m);
}

fn void Scanner.skip_line(&self)
{
	while (!self.at_end() && self.peek() != '\n') self.advance();
}

// Only blanks and a comment ('#' after a blank) may follow on this line.
fn void? Scanner.end_of_line(&self, String msg = "unexpected text at the end of the line", fault f = SYNTAX_ERROR)
{
	sz blanks = self.mark.pos;
	self.skip_blanks();
	if (self.peek() == '#' && self.mark.pos > blanks) self.skip_line();
	if (!self.at_end() && self.peek() != '\n') return self.error(self.mark, msg, f)~;
}

// '---' or '...' at column 1 followed by a blank or EOF
fn bool Scanner.at_marker(&self) => self.mark.column == 1 && self.is_marker(self.mark.pos);

// '---' or '...' starting at byte `i` (which must be at a line start) followed by a blank or EOF
fn bool Scanner.is_marker(&self, sz i)
{
	if (i + 3 > self.s.len) return false;
	char c = self.s[i];
	return (c == '-' || c == '.') && self.s[i + 1] == c && self.s[i + 2] == c
		&& (i + 3 == self.s.len || is_blankz(self.s[i + 3]));
}

// Plain scalar (DESIGN.md "Plain scalars"). Ends at ': ', ':'EOL, ' #', a line break followed by
// a line at column <= indent, a comment line, a document marker, or EOF. The line breaks that end
// it are not consumed (scan_to_next_token does that).
fn void? Scanner.fetch_plain(&self)
{
	self.save_simple_key()!;
	Mark m = self.mark;
	int line = m.line;
	String value = self.scan_plain();
	self.simple_key_allowed = self.mark.line != line;   // crossed a line break
	self.compact_ok = false;
	self.push(T_SCALAR, m, value);
}

fn String Scanner.scan_plain(&self)
{
	String first;     // the first line: a slice of the input, no copy
	DString buf;      // created only when the scalar continues on another line
	bool flow = self.flow_level > 0;
	int breaks = 0;   // line breaks between the previous text and this line
	while (true)
	{
		// the text of one line, without trailing blanks
		sz start = self.mark.pos;
		sz end = start;
		while (!self.at_end())
		{
			char c = self.peek();
			if (c == '\n' || (c == ':' && (is_blankz(self.peek(1)) || (flow && is_flow_indicator(self.peek(1)))))) break;
			if (flow && is_flow_indicator(c)) break;
			if (c == '#' && self.mark.pos > start && self.s[self.mark.pos - 1].is_blank()) break;
			self.advance();
			if (!c.is_blank()) end = self.mark.pos;
		}
		if (end > start && !breaks)
		{
			first = self.s[start:end - start];
		}
		else if (end > start)
		{
			if (!buf) buf = dstring::temp(first);
			if (breaks == 1) buf.append_char(' ');
			for (int i = 1; i < breaks; i++) buf.append_char('\n');
			buf.append(self.s[start:end - start]);
		}
		if (self.peek() != '\n') return buf ? buf.str_view() : first;
		// look ahead over line breaks and blank lines to the next text
		sz i = self.mark.pos;
		sz line_start;
		int n = 0;
		while (i < self.s.len && (self.s[i] == '\n' || self.s[i].is_blank()))
		{
			if (self.s[i] == '\n')
			{
				n++;
				line_start = i + 1;
			}
			i++;
		}
		if (i >= self.s.len || self.spaces_at(line_start) <= self.indent || self.s[i] == '#' || self.is_marker(line_start))
		{
			return buf ? buf.str_view() : first;
		}
		while (self.mark.pos < i) self.advance();
		breaks = n;
	}
}

// Indentation counts spaces only, never TABs.
fn int Scanner.spaces_at(&self, sz i)
{
	int n = 0;
	while (i + n < self.s.len && self.s[i + n] == ' ') n++;
	return n;
}

fn int Scanner.line_indent(&self) => self.spaces_at(self.mark.pos - (sz)self.col());

// ---- quoted scalars ------------------------------------------------------

fn void? Scanner.fetch_flow_scalar(&self, bool single)
{
	self.save_simple_key()!;
	Mark m = self.mark;
	String value = self.scan_flow_scalar(single)!;
	self.simple_key_allowed = false;
	self.compact_ok = false;
	self.json_line = self.mark.line;
	// only blanks, then ':', a comment or the end of the line may follow (in flow also ", ] }")
	sz i = self.mark.pos;
	while (i < self.s.len && self.s[i].is_blank()) i++;
	char c = i < self.s.len ? self.s[i] : '\n';
	bool ok = c == '\n' || c == '#' || (c == ':' && (i + 1 == self.s.len || is_blankz(self.s[i + 1])));
	if (self.flow_level) ok |= c == ':' || c == ',' || c == ']' || c == '}';
	if (!ok) return self.error(self.mark, "unexpected text after a quoted scalar")~;
	self.push(T_SCALAR, m, value, single ? SINGLE : DOUBLE);
}

fn String? Scanner.scan_flow_scalar(&self, bool single)
{
	Mark start = self.mark;
	char quote = self.peek();
	self.advance();
	DString buf = dstring::temp();
	while (true)
	{
		if (self.at_marker()) return self.error(self.mark, "document marker inside a quoted scalar")~;
		if (self.at_end()) return self.error(start, "unclosed quoted scalar", UNCLOSED_QUOTE)~;
		// non-blank characters
		bool escaped_break = false;
		while (!self.at_end())
		{
			char c = self.peek();
			if (c.is_blank() || c == '\n') break;
			if (single && c == '\'' && self.peek(1) == '\'')
			{
				buf.append_char('\'');
				self.advance();
				self.advance();
				continue;
			}
			if (c == quote)
			{
				self.advance();
				return buf.str_view();
			}
			if (!single && c == '\\')
			{
				if (self.peek(1) == '\n')
				{
					self.advance();
					escaped_break = true;
					break;
				}
				self.scan_escape(&buf)!;
				continue;
			}
			buf.append_char(c);
			self.advance();
		}
		// blanks and line breaks: blanks inside a line are kept, around a break they are dropped
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
			buf.append(self.s[blanks:self.mark.pos - blanks]);
			continue;
		}
		if (!self.at_end() && self.line_indent() <= self.indent)
		{
			return self.error(self.mark, "continuation line of a quoted scalar is not indented enough", INVALID_INDENTATION)~;
		}
		// one break folds to a space, n breaks give n-1 line feeds; an escaped break gives no space
		if (breaks == 1 && !escaped_break) buf.append_char(' ');
		for (int i = 2; i <= breaks; i++) buf.append_char('\n');
	}
}

// One escape sequence of a double-quoted scalar, at the backslash.
fn void? Scanner.scan_escape(&self, DString* buf)
{
	Mark m = self.mark;
	self.advance();
	char c = self.peek();
	self.advance();
	int digits;
	switch (c)
	{
		case '0': buf.append_char('\0');
		case 'a': buf.append_char(0x07);
		case 'b': buf.append_char(0x08);
		case 't':
		case '\t': buf.append_char('\t');
		case 'n': buf.append_char('\n');
		case 'v': buf.append_char(0x0b);
		case 'f': buf.append_char(0x0c);
		case 'r': buf.append_char('\r');
		case 'e': buf.append_char(0x1b);
		case ' ':
		case '"':
		case '/':
		case '\\': buf.append_char(c);
		case 'N': buf.append_char32(0x85);
		case '_': buf.append_char32(0xa0);
		case 'L': buf.append_char32(0x2028);
		case 'P': buf.append_char32(0x2029);
		case 'x': digits = 2;
		case 'u': digits = 4;
		case 'U': digits = 8;
		default: return self.error(m, "invalid escape sequence", INVALID_ESCAPE)~;
	}
	if (!digits) return;
	uint code = 0;
	for (int i = 0; i < digits; i++)
	{
		char h = self.peek();
		if (!h.is_xdigit()) return self.error(m, "invalid hex digit in escape sequence", INVALID_ESCAPE)~;
		code = code * 16 + h.from_hex();
		self.advance();
	}
	if (code > 0x10ffff || (code >= 0xd800 && code <= 0xdfff)) return self.error(m, "invalid Unicode code point", INVALID_ESCAPE)~;
	buf.append_char32(code);
}

// ---- block scalars -------------------------------------------------------

fn void? Scanner.fetch_block_scalar(&self, bool literal)
{
	self.remove_simple_key()!;
	Mark m = self.mark;
	String value = self.scan_block_scalar(literal)!;
	// the scanner is now at the start of the line that ended the scalar
	self.simple_key_allowed = true;
	self.compact_ok = true;
	self.tab_indent = false;
	self.push(T_SCALAR, m, value, literal ? LITERAL : FOLDED);
}

fn String? Scanner.scan_block_scalar(&self, bool literal)
{
	self.advance();
	// header: chomping ('-' strip, '+' keep) and indentation indicator 1-9, in either order
	int chomp = 0;
	int increment = 0;
	while (true)
	{
		char c = self.peek();
		if ((c == '-' || c == '+') && !chomp)
		{
			chomp = c == '+' ? 1 : -1;
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

	// content indentation: given by the indicator, or detected from the first non-empty line
	int min_indent = self.indent + 1;   // indent >= -1
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

	DString buf = dstring::temp();
	bool line_break = false;    // a break follows the previous content line
	bool more_indented = false; // the previous content line started with a blank
	while (self.col() == indent && !self.at_end() && !self.at_marker())
	{
		bool blank = self.peek().is_blank();
		// folded: a single break between two normal lines becomes a space
		if (!literal && line_break && !more_indented && !blank)
		{
			if (!breaks) buf.append_char(' ');
		}
		else if (line_break)
		{
			buf.append_char('\n');
		}
		for (int i = 0; i < breaks; i++) buf.append_char('\n');
		more_indented = blank;
		sz from = self.mark.pos;
		self.skip_line();
		buf.append(self.s[from:self.mark.pos - from]);
		line_break = true;   // the end of the input ends the last line like a line break
		breaks = 0;
		if (self.at_end()) break;
		self.advance();
		breaks = self.block_breaks(indent, min_indent, &max_empty)!;
	}
	// chomping of the final line break and the trailing empty lines
	if (chomp >= 0 && line_break) buf.append_char('\n');
	if (chomp > 0)
	{
		for (int i = 0; i < breaks; i++) buf.append_char('\n');
	}
	return buf.str_view();
}

// Skip the indentation and the empty lines before a block scalar line; return the number of
// empty lines. `indent` < 0: not known yet (only spaces are skipped, `max_empty` records the
// widest empty line). A TAB inside the indentation is an error.
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
		if (self.at_end() && self.mark.pos > line) return breaks + 1;   // a blank last line
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

// Characters up to a blank or a flow indicator (anchor names, directive arguments).
fn String Scanner.scan_word(&self)
{
	sz from = self.mark.pos;
	while (!is_blankz(self.peek()) && !is_flow_indicator(self.peek())) self.advance();
	return self.s[from:self.mark.pos - from];
}

// '&name' or '*name'.
fn void? Scanner.fetch_anchor(&self, bool is_alias)
{
	self.save_simple_key()!;
	self.simple_key_allowed = false;
	Mark m = self.mark;
	self.advance();
	String name = self.scan_word();
	if (!name.len) return self.error(m, is_alias ? "alias without a name" : "anchor without a name")~;
	self.push(is_alias ? T_ALIAS : T_ANCHOR, m, name);
}

fn bool is_word_char(char c) => c.is_alnum() || c == '-';

// URI characters allowed in a tag suffix (no '!' and no flow indicators); '%XX' is decoded.
fn String? Scanner.scan_tag_uri(&self, bool verbatim)
{
	DString buf = dstring::temp();
	while (true)
	{
		char c = self.peek();
		if (c == '%')
		{
			char hi = self.peek(1);
			char lo = self.peek(2);
			if (!hi.is_xdigit() || !lo.is_xdigit()) return self.error(self.mark, "invalid '%' escape in a tag", INVALID_ESCAPE)~;
			buf.append_char(hi.from_hex() * 16 + lo.from_hex());
			for (int i = 0; i < 3; i++) self.advance();
			continue;
		}
		if (!c.is_alnum() && !"-#;/?:@&=+$_.~*'()".contains_char(c) && !(verbatim && "!,[]".contains_char(c))) break;
		buf.append_char(c);
		self.advance();
	}
	return buf.str_view();
}

// '!<uri>', '!', '!suffix', '!!suffix', '!handle!suffix'. Resolved by the parser.
fn void? Scanner.fetch_tag(&self)
{
	self.save_simple_key()!;
	self.simple_key_allowed = false;
	Mark m = self.mark;
	String handle;
	String suffix;
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
			handle = self.s[self.mark.pos:n + 1];   // "!!" or "!name!"
			for (sz i = 0; i <= n; i++) self.advance();
		}
		else
		{
			handle = "!";
			self.advance();
		}
		suffix = self.scan_tag_uri(false)!;
		if (handle.len > 1 && !suffix.len) return self.error(m, "tag without a suffix")~;
	}
	char c = self.peek();
	if (!is_blankz(c) && !(self.flow_level && is_flow_indicator(c))) return self.error(self.mark, "a tag must be followed by a blank")~;
	self.push(T_TAG, m, suffix, handle: handle);
}

// '%YAML 1.2', '%TAG !h! prefix'; other directives are ignored.
fn void? Scanner.fetch_directive(&self)
{
	self.unroll_indent(-1);
	self.remove_simple_key()!;
	self.simple_key_allowed = false;
	Mark m = self.mark;
	self.advance();
	String name = self.scan_word();
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
			String version = self.s[from:self.mark.pos - from];
			if (!version.starts_with("1.")) return self.error(m, "unsupported YAML major version", INVALID_DIRECTIVE)~;
			self.end_of_line()!;
			self.push(T_VERSION_DIRECTIVE, m, version);
		case "TAG":
			String handle = self.scan_word();
			bool ok = handle == "!" || (handle.len >= 2 && handle[0] == '!' && handle[^1] == '!');
			if (handle.len > 2) foreach (c : handle[1:handle.len - 2]) ok &= is_word_char(c);
			if (!ok) return self.error(m, "invalid %TAG handle", INVALID_DIRECTIVE)~;
			self.skip_blanks();
			// a prefix cannot start with a flow indicator (an escaped one, "%2C", is fine)
			if (is_flow_indicator(self.peek())) return self.error(self.mark, "invalid %TAG prefix", INVALID_DIRECTIVE)~;
			Mark pm = self.mark;
			String prefix = self.scan_tag_uri(true)!;
			if (!prefix.len) return self.error(pm, "invalid %TAG prefix", INVALID_DIRECTIVE)~;
			self.end_of_line()!;
			self.push(T_TAG_DIRECTIVE, m, prefix, handle: handle);
		default:
			self.skip_line();   // reserved directive: ignored, but it still needs a following '---'
			self.push(T_RESERVED_DIRECTIVE, m, name);
	}
}
