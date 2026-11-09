// Helper functions for v2 parser tests.
module yaml2::parser_test;

import std::io;
import yaml2::parser;
import yaml2::testing;

fn String? parse_events(String yaml, String sep = "\n", bool stream = true, bool docs = true)
{
	DString out = dstring::temp();
	Parser p;
	p.init_inplace(testing::writable(yaml), false, mem);
	defer p.free();
	while (true)
	{
		Event e = p.next()!;
		bool skip = (!stream && (e.type == STREAM_START || e.type == STREAM_END))
			|| (!docs && (e.type == DOCUMENT_START || e.type == DOCUMENT_END));
		if (!skip)
		{
			if (out.len()) out.append(sep);
			out.appendf("%s", p.view(e));
		}
		if (e.type == STREAM_END) return out.str_view();
	}
}

fn String? parse_scalar(String yaml)
{
	Parser p;
	p.init_inplace(testing::writable(yaml), false, mem);
	defer p.free();
	while (true)
	{
		Event e = p.next()!;
		if (e.type == SCALAR) return p.text(e.value);
		if (e.type == STREAM_END) return "";
	}
}
