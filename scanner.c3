// M2 scanner skeleton (reviewer). Compiles with c3c 0.8.6 together with event.c3 and the
// parser skeleton; a prototype built from it passed all 73 cases in milestones/M2.valid and
// all 28 in milestones/M2.errors. Use it as scanner.c3: keep M1's report_error (source line +
// caret) inside Scanner.error, port M1's plain-scalar folding into scan_plain, and delete
// M1's next_token/peek_token/fetch_more_tokens/skip_whitespace_and_comments.
module yaml::parser;
import std::io, std::collections::list;

faultdef INVALID_INDENTATION, MISSING_COLON, INVALID_TAB;

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
}

fn void Scanner.init(&self, String s, bool verbose = true)
{
	*self = { .s = s, .mark = { 0, 1, 1 }, .verbose = verbose, .indent = -1 };
	self.tokens.tinit();
	self.indents.tinit();
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

fn void? Scanner.error(&self, Mark m, String msg, fault f = SYNTAX_ERROR)
{
	if (self.verbose)
	{
		io::eprintfn("YAML ERROR -- Line %d, Col %d: %s", m.line, m.column, msg)!!;
		sz line_start = 0;
		int current_line = 1;
		for (sz i = 0; i < m.pos; i++)
		{
			if (self.s[i] == '\n')
			{
				line_start = i + 1;
				current_line++;
			}
		}
		sz line_end = line_start;
		while (line_end < self.s.len && self.s[line_end] != '\n') line_end++;
		if (line_start < self.s.len) io::eprintn(self.s[line_start .. line_end].trim_right());
		if (m.column > 1)
		{
			io::eprintfn("%*s^", m.column - 1, "");
		}
		else
		{
			io::eprintfn("^");
		}
	}
	return f~;
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
	// M3: quotes and block scalars, M4: flow indicators, M5: properties and directives
	if (INDICATORS.contains_char(c)) return self.error(self.mark, "character not supported yet");
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
		return self.error(self.key.mark, "could not find expected ':'", MISSING_COLON);
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
	if (self.tab_indent) return self.error(self.mark, "tab character in indentation", INVALID_TAB);
	if (self.indent < self.col())
	{
		if (!self.compact_ok || !self.simple_key_allowed)
		{
			return self.error(self.mark, "block sequence entries are not allowed here");
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
		if (k.tab_indent) return self.error(k.mark, "tab character in indentation", INVALID_TAB);
		if (self.indent < k.mark.column - 1 && !k.compact_ok)
		{
			return self.error(k.mark, "mapping values are not allowed here");
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
		if (!self.simple_key_allowed) return self.error(self.mark, "mapping values are not allowed here");
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
	if (self.tab_indent) return self.error(self.mark, "tab character in indentation", INVALID_TAB);
	if (self.indent < self.col())
	{
		if (!self.compact_ok || !self.simple_key_allowed) return self.error(self.mark, "explicit keys are not allowed here");
		self.roll_indent(self.col(), T_BLOCK_MAPPING_START, self.mark);
	}
	self.remove_simple_key()!;
	Mark m = self.mark;
	self.advance();
	self.simple_key_allowed = true;
	self.compact_ok = self.peek() == ' ';
	self.push(T_KEY, m);
}

const String INDICATORS = "[]{},&*!|>'\"%@`#";

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
fn bool Scanner.at_marker(&self)
{
	char c = self.peek();
	return self.mark.column == 1 && (c == '-' || c == '.') && self.peek(1) == c && self.peek(2) == c && is_blankz(self.peek(3));
}

// Plain scalar (DESIGN.md "Plain scalars"). Reuse the M1 folding code, but:
//  - continuation lines need column > indent (self.col() >= self.indent + 1),
//  - a line starting with '#', a document marker, or EOF ends it (do not consume that line),
//  - ': ' / ':'EOL and ' #' end it on any line,
//  - crossing a line break sets simple_key_allowed = true (block context),
//  - trailing blanks are never part of the value.
fn void? Scanner.fetch_plain(&self)
{
	self.save_simple_key()!;
	self.simple_key_allowed = true;
	Mark m = self.mark;
	String value = self.scan_plain()!;
	self.compact_ok = false;
	self.push(T_SCALAR, m, value);
}

fn String trim_buf(DString buf)
{
	sz i = buf.len();
	while (i > 0 && (buf[i - 1] == ' ' || buf[i - 1] == '\t')) i--;
	if (i < buf.len())
	{
		DString t = dstring::temp();
		for (sz j = 0; j < i; j++) t.append_char(buf[j]);
		return t.str_view();
	}
	return buf.str_view();
}

fn String? Scanner.scan_plain(&self)
{
	DString buf = dstring::temp();
	bool first_line = true;
	
	while (self.mark.pos < self.s.len)
	{
		char c = self.peek();
		if (c == '\n')
		{
			// Trim trailing whitespace
			sz i = buf.len();
			while (i > 0 && (buf[i - 1] == ' ' || buf[i - 1] == '\t')) i--;
			if (i < buf.len())
			{
				// Trim the buffer
				DString trimmed = dstring::temp();
				for (sz j = 0; j < i; j++) trimmed.append_char(buf[j]);
				buf = trimmed;
			}
			
			self.advance();
			if (self.at_end()) return trim_buf(buf);
			if (self.mark.column == 1 && self.at_marker()) return trim_buf(buf);
			if (self.peek() == '#' && self.mark.column == 1) return trim_buf(buf);
			sz save_pos = self.mark.pos;
			int save_col = self.mark.column;
			while (self.peek() == ' ' || self.peek() == '\t') self.advance();
			if (self.peek() == '#') { self.mark.pos = save_pos; self.mark.column = save_col; return trim_buf(buf); }
			if (self.peek() == '\n')
			{
				while (self.peek() == '\n') self.advance();
				if (self.at_end()) return trim_buf(buf);
				while (self.peek() == ' ' || self.peek() == '\t') self.advance();
				if (self.col() > self.indent)
				{
					if (!first_line && buf.len() > 0) buf.append_char('\n');
					first_line = false;
					continue;
				}
				self.mark.pos = save_pos; self.mark.column = save_col; return trim_buf(buf);
			}
			if (self.col() > self.indent)
			{
				if (!first_line && buf.len() > 0) buf.append_char(' ');
				first_line = false;
				continue;
			}
			self.mark.pos = save_pos; self.mark.column = save_col; return trim_buf(buf);
		}
		if (c == '#' && (self.mark.column == 1 || (self.mark.pos > 0 && (self.s[self.mark.pos - 1] == ' ' || self.s[self.mark.pos - 1] == '\t')))) return trim_buf(buf);
		if (c == ':' && self.mark.pos + 1 <= self.s.len)
		{
			char n = self.peek(1);
			if (n == ' ' || n == '\n' || n == '\t' || n == '\r' || n == '\0') return trim_buf(buf);
		}
		if (self.mark.column == 1 && self.at_marker()) return trim_buf(buf);
		buf.append_char(c);
		first_line = false;
		self.advance();
	}
	return trim_buf(buf);
}
