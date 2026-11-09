module yaml::parser;

import std::io;
import std::collections::list;

enum State : char { STREAM_START_STATE, IMPLICIT_DOCUMENT_START, DOCUMENT_START, DOCUMENT_CONTENT,
  DOCUMENT_END, STREAM_END_STATE, TERMINAL }

struct Parser
{
	Scanner scanner;
	State state;
	Token queued_token;
	bool has_queued_token;
}

fn Parser* Parser.init(&self, String input, bool verbose = true)
{
	self.scanner.init(input, verbose);
	self.state = STREAM_START_STATE;
	self.has_queued_token = false;
	return self;
}

fn Event? Parser.next(&self)
{
	switch (self.state)
	{
		case STREAM_START_STATE:
			self.state = IMPLICIT_DOCUMENT_START;
			return (Event){ .type = STREAM_START, .start = (Mark){ .pos = 0, .line = 1, .column = 1 } };
		
		case IMPLICIT_DOCUMENT_START:
			{
			Token? maybe_t = self.get_token();
			if (catch err = maybe_t) return err~;
			Token t = maybe_t;
			
			if (t.type == T_DOCUMENT_START)
			{
				self.state = DOCUMENT_START;
				return (Event){ .type = DOCUMENT_START, .explicit = true, .start = t.start };
			}
			else if (t.type == T_STREAM_END)
			{
				// Empty stream
				self.state = STREAM_END_STATE;
				return (Event){ .type = STREAM_END, .start = t.start };
			}
			else if (t.type == T_DOCUMENT_END)
			{
				// Explicit end with no open document - emit nothing per HWV9, QT73
				self.state = IMPLICIT_DOCUMENT_START;
				return self.next();
			}
			else if (t.type == T_SCALAR)
			{
				// Implicit document start
				self.state = DOCUMENT_START;
				// Queue the scalar for next call
				self.queued_token = t;
				self.has_queued_token = true;
				return (Event){ .type = DOCUMENT_START, .explicit = false, .start = t.start };
			}
			}
			return parser::SYNTAX_ERROR~;
			
		case DOCUMENT_START:
			{
			Token? maybe_t = self.get_token();
			if (catch err = maybe_t) return err~;
			Token t = maybe_t;
			
			if (t.type == T_SCALAR)
			{
				self.state = DOCUMENT_CONTENT;
				return (Event){ .type = SCALAR, .style = t.style, .value = t.value, .start = t.start };
			}
			else if (t.type == T_DOCUMENT_END)
			{
				// Empty document - emit empty scalar first (6XDY)
				self.state = DOCUMENT_CONTENT;
				// Queue the DOCUMENT_END for next call
				self.queued_token = t;
				self.has_queued_token = true;
				return (Event){ .type = SCALAR, .style = PLAIN, .value = "", .start = t.start };
			}
			else if (t.type == T_STREAM_END)
			{
				// Empty document at EOF - emit empty scalar first
				self.state = DOCUMENT_CONTENT;
				// Queue the STREAM_END for next call
				self.queued_token = t;
				self.has_queued_token = true;
				return (Event){ .type = SCALAR, .style = PLAIN, .value = "", .start = t.start };
			}
			else if (t.type == T_DOCUMENT_START)
			{
				// Another document start - empty document
				// For explicit document with no content, emit empty scalar (6XDY)
				self.state = DOCUMENT_CONTENT;
				// Queue the DOCUMENT_START for next call
				self.queued_token = t;
				self.has_queued_token = true;
				// Return SCALAR with empty value
				return (Event){ .type = SCALAR, .style = PLAIN, .value = "", .start = t.start };
			}
			}
			return parser::SYNTAX_ERROR~;
			
		case DOCUMENT_CONTENT:
			{
			Token? maybe_t = self.get_token();
			if (catch err = maybe_t) return err~;
			Token t = maybe_t;
			
			if (t.type == T_DOCUMENT_END)
			{
				self.state = DOCUMENT_END;
				return (Event){ .type = DOCUMENT_END, .explicit = true, .start = t.start };
			}
			else if (t.type == T_STREAM_END)
			{
				// End of stream - emit DOCUMENT_END implicitly, then STREAM_END
				self.state = STREAM_END_STATE;
				return (Event){ .type = DOCUMENT_END, .explicit = false, .start = t.start };
			}
			else if (t.type == T_DOCUMENT_START)
			{
				// New document start - end current document implicitly
				self.state = DOCUMENT_END;
				// Queue the DOCUMENT_START for next iteration
				self.queued_token = t;
				self.has_queued_token = true;
				return (Event){ .type = DOCUMENT_END, .explicit = false, .start = t.start };
			}
			else if (t.type == T_SCALAR)
			{
				// Second scalar in same document - error for M1
				self.scanner.report_error(t.start, "Second scalar in same document not supported yet");
				return parser::SYNTAX_ERROR~;
			}
			}
			return parser::SYNTAX_ERROR~;
			
		case DOCUMENT_END:
			{
			Token? maybe_t = self.get_token();
			if (catch err = maybe_t) return err~;
			Token t = maybe_t;
			
			if (t.type == T_DOCUMENT_START)
			{
				self.state = DOCUMENT_START;
				return (Event){ .type = DOCUMENT_START, .explicit = true, .start = t.start };
			}
			else if (t.type == T_DOCUMENT_END)
			{
				// Explicit end with no open document - emit nothing
				self.state = DOCUMENT_END;
				return self.next();
			}
			else if (t.type == T_STREAM_END)
			{
				self.state = STREAM_END_STATE;
				return (Event){ .type = STREAM_END, .start = t.start };
			}
			else if (t.type == T_SCALAR)
			{
				// Implicit document start
				self.state = DOCUMENT_START;
				// Queue the scalar
				self.queued_token = t;
				self.has_queued_token = true;
				return (Event){ .type = DOCUMENT_START, .explicit = false, .start = t.start };
			}
			}
			return parser::SYNTAX_ERROR~;
			
		case STREAM_END_STATE:
			// Emit STREAM_END
			self.state = TERMINAL;
			return (Event){ .type = STREAM_END, .start = self.scanner.mark };
			
		case TERMINAL:
			// After STREAM_END, return error
			self.scanner.report_error(self.scanner.mark, "No more events after STREAM_END");
			return parser::SYNTAX_ERROR~;
	}
	
	// Should not reach here
	self.scanner.report_error(self.scanner.mark, "Unexpected state");
	return parser::SYNTAX_ERROR~;
}

fn Token? Parser.get_token(&self)
{
	if (self.has_queued_token)
	{
		self.has_queued_token = false;
		return self.queued_token;
	}
	return self.scanner.next_token();
}
