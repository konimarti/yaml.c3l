module yaml::parser;

import std::io;
import std::collections::list;

struct Scanner
{
	String s;
	Mark mark;
	bool verbose;
	List {Token} tokens;
}

fn Scanner* Scanner.init(&self, String s, bool verbose = true)
{
	self.s = s;
	self.mark = (Mark){ .pos = 0, .line = 1, .column = 1 };
	self.verbose = verbose;
	self.tokens.init(tmem, 8);
	return self;
}

fn void Scanner.advance(&self)
{
	if (self.mark.pos < self.s.len && self.s[self.mark.pos] == '\n')
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

fn bool is_document_marker_char(char c)
{
	return c == '-' || c == '.';
}

fn bool Scanner.at_document_marker(&self)
{
	if (self.mark.column != 1) return false;
	if (self.mark.pos + 2 >= self.s.len) return false;
	char c = self.s[self.mark.pos];
	if (!is_document_marker_char(c)) return false;
	if (self.s[self.mark.pos + 1] != c || self.s[self.mark.pos + 2] != c) return false;
	// Check what follows the three marker characters
	sz after_pos = self.mark.pos + 3;
	if (after_pos < self.s.len)
	{
		char after = self.s[after_pos];
		// Document marker must be followed by whitespace (space, tab, newline) or end of line
		if (after != ' ' && after != '\t' && after != '\n' && after != '\r')
		{
			return false;
		}
	}
	return true;
}

fn void Scanner.report_error(&self, Mark m, String msg)
{
	if (!self.verbose) return;
	
	io::eprintfn("YAML ERROR -- Line %d, Col %d: %s", m.line, m.column, msg)!!;
	
	// Print source line and caret
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
	while (line_end < self.s.len && self.s[line_end] != '\n')
	{
		line_end++;
	}
	if (line_start < self.s.len)
	{
		io::eprintn(self.s[line_start .. line_end].trim_right());
	}
	// Print caret
	if (m.column > 1)
	{
		io::eprintfn("%*s^", m.column - 1, "");
	}
	else
	{
		io::eprintfn("^");
	}
}

fn void Scanner.skip_whitespace_and_comments(&self)
{
	while (self.mark.pos < self.s.len)
	{
		char c = self.s[self.mark.pos];
		if (c == ' ' || c == '\t')
		{
			self.advance();
		}
		else if (c == '\n')
		{
			self.advance();
		}
		else if (c == '#')
		{
			// Comment - skip to end of line
			while (self.mark.pos < self.s.len && self.s[self.mark.pos] != '\n')
			{
				self.advance();
			}
			// Skip the newline too
			if (self.mark.pos < self.s.len && self.s[self.mark.pos] == '\n')
			{
				self.advance();
			}
		}
		else
		{
			break;
		}
	}
}

fn Token? Scanner.next_token(&self)
{
	self.skip_whitespace_and_comments();
	
	// Check if we're at EOF
	if (self.mark.pos >= self.s.len)
	{
		return (Token){ .type = T_STREAM_END, .start = self.mark, .value = "", .style = PLAIN };
	}
	
	// Check for document markers at column 1
	if (self.at_document_marker())
	{
		Mark start = self.mark;
		sz marker_start = self.mark.pos;
		// It's either --- or ...
		self.mark.pos += 3;
		self.mark.column += 3;
		
		// Skip trailing whitespace and comments on the same line
		while (self.mark.pos < self.s.len)
		{
			char c = self.s[self.mark.pos];
			if (c == ' ' || c == '\t')
			{
				self.advance();
			}
			else if (c == '\n')
			{
				self.advance();
				break;
			}
			else if (c == '#')
			{
				// Skip comment
				while (self.mark.pos < self.s.len && self.s[self.mark.pos] != '\n')
				{
					self.advance();
				}
				if (self.mark.pos < self.s.len && self.s[self.mark.pos] == '\n')
				{
					self.advance();
				}
				break;
			}
			else
			{
				// There's content after the marker
				break;
			}
		}
		
		String three = self.s[marker_start .. marker_start + 2];
		if (three == "---")
		{
			return (Token){ .type = T_DOCUMENT_START, .start = start, .value = "", .style = PLAIN };
		}
		else // "..."
		{
			return (Token){ .type = T_DOCUMENT_END, .start = start, .value = "", .style = PLAIN };
		}
	}
	
	// Read a plain scalar
	Mark scalar_start = self.mark;
	
	// Check if scalar starts with unsupported indicator
	// Per DESIGN.md: "- ", "? ", ": ", etc. at start of scalar must be rejected
	char first_char = self.s[self.mark.pos];
	if (first_char == '-' || first_char == '?' || first_char == ':' ||
		first_char == '[' || first_char == ']' || first_char == '{' || first_char == '}' ||
		first_char == ',' || first_char == '&' || first_char == '*' || first_char == '!' ||
		first_char == '|' || first_char == '>' || first_char == '\'' || first_char == '"' ||
		first_char == '%' || first_char == '@' || first_char == '`')
	{
		// Check if it's actually an indicator (followed by space/whitespace)
		// For single char indicators, they must be followed by space/whitespace/EOL
		bool is_indicator = false;
		if (self.mark.pos + 1 < self.s.len)
		{
			char next_char = self.s[self.mark.pos + 1];
			// Single char indicators: ':', ',', '?', '&', '*', '!', '|', '>', '%', '@', '`'
			// These are indicators only when followed by space/whitespace
			if (first_char == ':' || first_char == ',' || first_char == '?' ||
				first_char == '&' || first_char == '*' || first_char == '!' ||
				first_char == '|' || first_char == '>' || first_char == '%' ||
				first_char == '@' || first_char == '`')
			{
				if (next_char == ' ' || next_char == '\t' || next_char == '\n')
				{
					is_indicator = true;
				}
			}
			// '-' and '?' need special handling
			else if (first_char == '-')
			{
				// "- " is sequence indicator
				if (next_char == ' ' || next_char == '\t')
				{
					is_indicator = true;
				}
			}
			else if (first_char == '?')
			{
				// "? " is complex key indicator
				if (next_char == ' ' || next_char == '\t')
				{
					is_indicator = true;
				}
			}
			// '[' and '{' start flow collections
			else if (first_char == '[' || first_char == '{')
			{
				is_indicator = true; // Always indicators
			}
			// ']' and '}' are not valid at start of scalar
			else if (first_char == ']' || first_char == '}')
			{
				is_indicator = true;
			}
		}
		else
		{
			// Single char at end of string - always indicator
			is_indicator = true;
		}
		
		if (is_indicator)
		{
			self.report_error(scalar_start, "Character not supported yet");
			return parser::SYNTAX_ERROR~;
		}
	}
	
	DString buf;
	buf.init(tmem);
	
	bool first_line = true;
	
	while (self.mark.pos < self.s.len)
	{
		char c = self.s[self.mark.pos];
		
		// Check for line break
		if (c == '\n')
		{
			// Trim trailing whitespace from current line
			// Find the new length
			sz new_len = buf.len();
			while (new_len > 0 && (buf[new_len - 1] == ' ' || buf[new_len - 1] == '\t'))
			{
				new_len--;
			}
			// Create new trimmed buffer
			if (new_len < buf.len())
			{
				DString trimmed_buf;
				trimmed_buf.init(tmem);
				for (sz i = 0; i < new_len; i++)
				{
					trimmed_buf.append_char(buf[i]);
				}
				buf.free();
				buf = trimmed_buf;
			}
			
			// Look ahead to see what comes next
			sz next_pos = self.mark.pos + 1;
			
			// Skip the newline
			self.advance();
			
			// Check if next line starts with document marker at column 1
			if (next_pos < self.s.len && self.mark.column == 1 && self.at_document_marker())
			{
				// Document marker ends the scalar
				break;
			}
			
			// Check if next line is empty (another \n)
			if (next_pos < self.s.len && self.s[next_pos] == '\n')
			{
				// Empty line(s): multiple newlines -> fold to single \n
				// Count consecutive empty lines
				int empty_lines = 1;
				while (next_pos < self.s.len && self.s[next_pos] == '\n')
				{
					next_pos++;
					empty_lines++;
				}
				// Skip all the newlines
				for (int i = 1; i < empty_lines; i++)
				{
					if (self.mark.pos < self.s.len) self.advance();
				}
				// Add a single newline for paragraph break (double+ newline in input)
				if (!first_line && buf.len() > 0)
				{
					buf.append_char('\n');
				}
				first_line = false;
				// Skip leading whitespace on the next line
				while (self.mark.pos < self.s.len && (self.s[self.mark.pos] == ' ' || self.s[self.mark.pos] == '\t'))
				{
					self.advance();
				}
				continue;
			}
			
			// Check if next line is a comment
			if (next_pos < self.s.len && self.s[next_pos] == '#')
			{
				// Comment ends the scalar
				break;
			}
			
			// Continuation line - fold single newline to space
			// Skip leading whitespace on continuation line
			while (self.mark.pos < self.s.len && (self.s[self.mark.pos] == ' ' || self.s[self.mark.pos] == '\t'))
			{
				self.advance();
			}
			
			// If we hit another newline, it's a blank line (already handled above)
			if (self.mark.pos < self.s.len && self.s[self.mark.pos] == '\n')
			{
				self.advance();
				continue;
			}
			
			// Add a space for folding
			if (!first_line && buf.len() > 0)
			{
				buf.append_char(' ');
			}
			first_line = false;
			continue;
		}
		
		// Check for comment (at line start or after whitespace)
		if (c == '#')
		{
			if (self.mark.column == 1)
			{
				// # at start of line is a comment
				break;
			}
			else if (self.mark.pos > 0)
			{
				char prev = self.s[self.mark.pos - 1];
				// # after space or tab on same line is a comment
				if (prev == ' ' || prev == '\t')
				{
					break;
				}
			}
		}
		
		// Check for value indicator (: followed by space/newline/tab)
		if (c == ':' && self.mark.pos + 1 < self.s.len)
		{
			char next = self.s[self.mark.pos + 1];
			if (next == ' ' || next == '\n' || next == '\t' || next == '\r')
			{
				// Value indicator ends the scalar
				break;
			}
		}
		
		// Check for document marker
		if (self.at_document_marker())
		{
			break;
		}
		
		// Collect the character
		buf.append_char(c);
		first_line = false;
		self.advance();
	}
	
	// Trim trailing whitespace by finding the last non-whitespace character
	sz end_idx = buf.len();
	while (end_idx > 0 && (buf[end_idx - 1] == ' ' || buf[end_idx - 1] == '\t' || buf[end_idx - 1] == '\n'))
	{
		end_idx--;
	}
	// Copy the trimmed string
	DString trimmed;
	trimmed.init(tmem);
	for (sz i = 0; i < end_idx; i++)
	{
		trimmed.append_char(buf[i]);
	}
	String value = trimmed.str_view().copy(tmem);
	trimmed.free();
	buf.free();
	
	return (Token){ .type = T_SCALAR, .start = scalar_start, .value = value, .style = PLAIN };
}

fn Token? Scanner.peek_token(&self)
{
	if (self.tokens.size > 0)
	{
		return self.tokens[0];
	}
	Token? t = self.next_token();
	if (try token = t)
	{
		self.tokens.push(token);
		return token;
	}
	// Can't return an error for a struct type, so we'll use a flag
	// For now, just return an empty token
	return (Token){ .type = T_STREAM_END, .start = self.mark, .value = "", .style = PLAIN };
}

fn void Scanner.fetch_more_tokens(&self)
{
	if (self.tokens.size == 0)
	{
		Token? t = self.next_token();
		if (try token = t)
		{
			self.tokens.push(token);
		}
	}
}

fn void Scanner.free(&self)
{
	self.tokens.free();
}
