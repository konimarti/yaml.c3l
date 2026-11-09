// Scanner: characters -> tokens (libyaml style: indent stack, simple keys, one token queue).
module yaml::parser;
import std::io, std::collections::list;

faultdef INVALID_INDENTATION, MISSING_COLON, INVALID_TAB, INVALID_ESCAPE, UNCLOSED_QUOTE,
	INVALID_BLOCK_HEADER;

// Mark, ScalarStyle and SYNTAX_ERROR stay in event.c3. Move TokenType/Token from event.c3 to here.
enum TokenType : char
{
	T_STREAM_START, T_STREAM_END, T_DOCUMENT_START, T_DOCUMENT_END,
	T_BLOCK_SEQUENCE_START, T_BLOCK_MAPPING_START, T_BLOCK_END,
	T_BLOCK_ENTRY, T_KEY, T_VALUE, T_SCALAR
}
struct Token { TokenType type; Mark start; String value; ScalarStyle style; }

// A possible implicit key: the token that may become a KEY when a ':' follows on the same line.
struct SimpleKey
{
	bool possible;
	bool required;     // block context and key at the current indent: losing it is an error
	bool compact_ok;   // may open a new block mapping on this line
	bool tab_indent;   // its line has a TAB in the indentation
	sz token_number;   // absolute token index (tokens_taken + index in queue)
	Mark mark;
}

struct Scanner
{
	String s;
	Mark mark;
	bool verbose;
	List {Token} tokens;
	sz tokens_taken;           // tokens already handed to the parser
	bool stream_start_done;
	bool stream_end_done;
	int indent;                // 0-based column of the current block, -1 at stream level
	List {int} indents;
	bool simple_key_allowed;
	bool compact_ok;           // true at line start and after '-', '?', ':'(explicit) + spaces
	bool tab_indent;           // current line has a TAB before its first token
	SimpleKey key;             // M4: List {SimpleKey}, one per flow level
	Mark error_mark;           // position of the last reported error
}

fn void Scanner.init(&self, String s, bool verbose = true)
{
	*self = { .s = normalize_breaks(s), .mark = { 0, 1, 1 }, .verbose = verbose, .indent = -1 };
	self.tokens.tinit();
	self.indents.tinit();
}

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

fn int Scanner.col(&self) @inline => self.mark.column - 1;
fn bool Scanner.at_end(&self) @inline => self.mark.pos >= self.s.len;
fn char Scanner.peek(&self, sz offset = 0)
{
	sz i = self.mark.pos + offset;
	return i < self.s.len ? self.s[i] : '\0';
}
fn bool is_blankz(char c) => c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\0';

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
	self.error_mark = m;
	if (self.verbose)
	{
		sz start = m.pos;
		while (start > 0 && self.s[start - 1] != '\n') start--;
		sz end = m.pos;
		while (end < self.s.len && self.s[end] != '\n') end++;
		(void)io::eprintfn("YAML ERROR -- Line %d, Col %d: %s", m.line, m.column, msg);
		(void)io::eprintn(self.s[start:end - start]);
		(void)io::eprintfn("%*s^", m.column - 1, "");
	}
	return f;
}

// ---- token queue ---------------------------------------------------------

fn Token? Scanner.next_token(&self)
{
	self.fetch_more_tokens()!;
	self.tokens_taken++;
	return self.tokens.pop_first();
}

fn Token? Scanner.peek_token(&self)
{
	self.fetch_more_tokens()!;
	return self.tokens[0];
}

// Fetch until the head token can no longer become a KEY.
fn void? Scanner.fetch_more_tokens(&self)
{
	while (true)
	{
		if (self.tokens.len() > 0)
		{
			self.stale_simple_key()!;
			if (!self.key.possible || self.key.token_number != self.tokens_taken) return;
		}
		if (self.stream_end_done) return;
		self.fetch_next_token()!;
	}
}

fn void Scanner.push(&self, TokenType type, Mark m, String value = "")
{
	self.tokens.push({ .type = type, .start = m, .value = value });
}

fn void? Scanner.fetch_next_token(&self)
{
	if (!self.stream_start_done)
	{
		self.stream_start_done = true;
		self.simple_key_allowed = true;
		self.compact_ok = true;
		self.push(T_STREAM_START, self.mark);
		return;
	}
	self.scan_to_next_token();
	self.stale_simple_key()!;
	self.unroll_indent(self.col());
	if (self.at_end()) return self.fetch_stream_end();
	char c = self.peek();
	char n = self.peek(1);
	if (c == '-' && is_blankz(n)) return self.fetch_block_entry();
	if (c == ':' && is_blankz(n)) return self.fetch_value();
	if (c == '?' && is_blankz(n)) return self.fetch_key();
	if (self.at_marker()) return self.fetch_document_indicator(c == '-' ? T_DOCUMENT_START : T_DOCUMENT_END);
	if (c == '\'' || c == '"') return self.fetch_flow_scalar(c == '\'');
	if (c == '|' || c == '>') return self.fetch_block_scalar(c == '|');
	// M4: flow indicators, M5: properties and directives
	if (INDICATORS.contains_char(c)) return self.error(self.mark, "character not supported yet")~;
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
		else if (c == '#')
		{
			while (!self.at_end() && self.peek() != '\n') self.advance();
		}
		else if (c == '\n')
		{
			self.advance();
			self.simple_key_allowed = true;   // block context only (M4: flow_level == 0)
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
		self.tokens.insert_at(number - self.tokens_taken, t);
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
	self.key = {
		.possible = true,
		.required = self.indent == self.col(),
		.compact_ok = self.compact_ok,
		.tab_indent = self.tab_indent,
		.token_number = self.tokens_taken + self.tokens.len(),
		.mark = self.mark,
	};
}

fn void? Scanner.remove_simple_key(&self)
{
	if (self.key.possible && self.key.required)
	{
		return self.error(self.key.mark, "could not find expected ':'", MISSING_COLON)~;
	}
	self.key.possible = false;
}

// Implicit keys are single-line and at most 1024 characters.
fn void? Scanner.stale_simple_key(&self)
{
	if (!self.key.possible) return;
	if (self.key.mark.line == self.mark.line && self.mark.pos - self.key.mark.pos <= 1024) return;
	self.remove_simple_key()!;
}

// ---- indicators ----------------------------------------------------------

fn void? Scanner.fetch_stream_end(&self)
{
	self.unroll_indent(-1);
	self.remove_simple_key()!;
	self.simple_key_allowed = false;
	self.stream_end_done = true;
	self.push(T_STREAM_END, self.mark);
}

fn void? Scanner.fetch_block_entry(&self)
{
	if (self.tab_indent) return self.error(self.mark, "tab character in indentation", INVALID_TAB)~;
	if (self.indent < self.col())
	{
		if (!self.compact_ok || !self.simple_key_allowed)
		{
			return self.error(self.mark, "block sequence entries are not allowed here")~;
		}
		self.roll_indent(self.col(), T_BLOCK_SEQUENCE_START, self.mark);
	}
	self.remove_simple_key()!;
	Mark m = self.mark;
	self.advance();
	self.simple_key_allowed = true;
	self.compact_ok = self.peek() == ' ';   // "-\t-" may not nest
	self.push(T_BLOCK_ENTRY, m);
}

fn void? Scanner.fetch_value(&self)
{
	if (self.key.possible)
	{
		SimpleKey k = self.key;
		if (k.tab_indent) return self.error(k.mark, "tab character in indentation", INVALID_TAB)~;
		if (self.indent < k.mark.column - 1 && !k.compact_ok)
		{
			return self.error(k.mark, "mapping values are not allowed here")~;
		}
		self.tokens.insert_at(k.token_number - self.tokens_taken, { .type = T_KEY, .start = k.mark });
		self.roll_indent(k.mark.column - 1, T_BLOCK_MAPPING_START, k.mark, k.token_number);
		self.key.possible = false;
		self.simple_key_allowed = false;
		self.compact_ok = false;   // "a: - b", "a: b: c"
	}
	else
	{
		// value of an explicit '?' key, or an empty key
		if (!self.simple_key_allowed) return self.error(self.mark, "mapping values are not allowed here")~;
		self.roll_indent(self.col(), T_BLOCK_MAPPING_START, self.mark);
		self.simple_key_allowed = true;
		self.compact_ok = self.peek(1) == ' ';
	}
	Mark m = self.mark;
	self.advance();
	self.push(T_VALUE, m);
}

fn void? Scanner.fetch_key(&self)
{
	if (self.tab_indent) return self.error(self.mark, "tab character in indentation", INVALID_TAB)~;
	if (self.indent < self.col())
	{
		if (!self.compact_ok || !self.simple_key_allowed) return self.error(self.mark, "explicit keys are not allowed here")~;
		self.roll_indent(self.col(), T_BLOCK_MAPPING_START, self.mark);
	}
	self.remove_simple_key()!;
	Mark m = self.mark;
	self.advance();
	self.simple_key_allowed = true;
	self.compact_ok = self.peek() == ' ';
	self.push(T_KEY, m);
}

const String INDICATORS = "[]{},&*!%@`#";

fn void? Scanner.fetch_document_indicator(&self, TokenType type)
{
	self.unroll_indent(-1);
	self.remove_simple_key()!;
	self.simple_key_allowed = false;
	self.compact_ok = false;   // "--- a: b" (9KBC) and "--- - a" may not open a block collection
	Mark m = self.mark;
	for (int i = 0; i < 3; i++) self.advance();
	self.push(type, m);
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
	DString buf = dstring::temp();
	int breaks = 0;   // line breaks between the previous text and this line
	while (true)
	{
		// the text of one line, without trailing blanks
		sz start = self.mark.pos;
		sz end = start;
		while (!self.at_end())
		{
			char c = self.peek();
			if (c == '\n' || (c == ':' && is_blankz(self.peek(1)))) break;
			if (c == '#' && self.mark.pos > start && (self.s[self.mark.pos - 1] == ' ' || self.s[self.mark.pos - 1] == '\t')) break;
			self.advance();
			if (c != ' ' && c != '\t') end = self.mark.pos;
		}
		if (end > start)
		{
			if (breaks == 1) buf.append_char(' ');
			for (int i = 1; i < breaks; i++) buf.append_char('\n');
			buf.append(self.s[start:end - start]);
		}
		if (self.peek() != '\n') return buf.str_view();
		// look ahead over line breaks and blank lines to the next text
		sz i = self.mark.pos;
		sz line_start;
		int n = 0;
		while (i < self.s.len && (self.s[i] == '\n' || self.s[i] == ' ' || self.s[i] == '\t'))
		{
			if (self.s[i] == '\n')
			{
				n++;
				line_start = i + 1;
			}
			i++;
		}
		if (i >= self.s.len || (int)(i - line_start) <= self.indent || self.s[i] == '#' || self.is_marker(line_start))
		{
			return buf.str_view();
		}
		while (self.mark.pos < i) self.advance();
		breaks = n;
	}
}

// Number of spaces at the start of the current line (a TAB is not indentation).
fn int Scanner.line_indent(&self)
{
	sz i = self.mark.pos - (sz)(self.mark.column - 1);
	int n = 0;
	while (i + n < self.s.len && self.s[i + n] == ' ') n++;
	return n;
}

// ---- quoted scalars ------------------------------------------------------

fn void? Scanner.fetch_flow_scalar(&self, bool single)
{
	self.save_simple_key()!;
	Mark m = self.mark;
	String value = self.scan_flow_scalar(single)!;
	self.simple_key_allowed = false;
	self.compact_ok = false;
	// only blanks, then ':', a comment or the end of the line may follow (M4: ", ] }" in flow)
	sz i = self.mark.pos;
	while (i < self.s.len && (self.s[i] == ' ' || self.s[i] == '\t')) i++;
	char c = i < self.s.len ? self.s[i] : '\n';
	bool ok = c == '\n' || (c == '#' && i > self.mark.pos) || (c == ':' && (i + 1 == self.s.len || is_blankz(self.s[i + 1])));
	if (!ok) return self.error(self.mark, "unexpected text after a quoted scalar")~;
	self.tokens.push({ .type = T_SCALAR, .start = m, .value = value, .style = single ? SINGLE : DOUBLE });
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
			if (c == ' ' || c == '\t' || c == '\n') break;
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
			else if (c != ' ' && c != '\t')
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
		uint v;
		switch
		{
			case h >= '0' && h <= '9': v = h - '0';
			case (h | 0x20) >= 'a' && (h | 0x20) <= 'f': v = (h | 0x20) - 'a' + 10;
			default: return self.error(m, "invalid hex digit in escape sequence", INVALID_ESCAPE)~;
		}
		code = code * 16 + v;
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
	self.tokens.push({ .type = T_SCALAR, .start = m, .value = value, .style = literal ? LITERAL : FOLDED });
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
	sz blanks = self.mark.pos;
	while (self.peek() == ' ' || self.peek() == '\t') self.advance();
	if (self.peek() == '#' && self.mark.pos > blanks)
	{
		while (!self.at_end() && self.peek() != '\n') self.advance();
	}
	if (!self.at_end() && self.peek() != '\n')
	{
		return self.error(self.mark, "invalid block scalar header", INVALID_BLOCK_HEADER)~;
	}
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
		bool blank = self.peek() == ' ' || self.peek() == '\t';
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
		while (!self.at_end() && self.peek() != '\n') self.advance();
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
