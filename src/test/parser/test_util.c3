// Helpers shared by the parser tests.
module yaml::test_util;

import std::io;
import yaml::parser;

// The events of `yaml` as test.event lines joined by `sep`. `stream = false` leaves out
// +STR/-STR, `docs = false` also +DOC/-DOC.
fn String? events(String yaml, String sep = "\n", bool stream = true, bool docs = true)
{
	DString out = dstring::temp();
	Parser p;
	p.init(yaml, false);
	while (true)
	{
		Event e = p.next()!;
		bool skip = (!stream && (e.type == STREAM_START || e.type == STREAM_END))
			|| (!docs && (e.type == DOCUMENT_START || e.type == DOCUMENT_END));
		if (!skip)
		{
			if (out.len()) out.append(sep);
			out.appendf("%s", e);
		}
		if (e.type == STREAM_END) return out.str_view();
	}
}

// The value of the first scalar event of `yaml`.
fn String? scalar(String yaml)
{
	Parser p;
	p.init(yaml, false);
	while (true)
	{
		Event e = p.next()!;
		if (e.type == SCALAR) return e.value;
		if (e.type == STREAM_END) return NOT_FOUND~;
	}
}
