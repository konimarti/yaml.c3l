// Helpers shared by the parser tests.
module yaml::test_util;

import std::io, libc;
import yaml, yaml::parser;

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

// What from_string(yaml, verbose) writes to io::stderr() (in tmem); `f` gets its fault.
fn String stderr_of(String yaml, bool verbose, fault* f = null)
{
	CFile tmp = libc::tmpfile();
	assert(tmp, "tmpfile() failed");
	defer libc::fclose(tmp);
	File saved = *io::stderr();
	*io::stderr() = file::from_handle(tmp);
	Yaml? data = yaml::from_string(yaml, mem, verbose);
	*io::stderr() = saved;
	if (catch err = data)
	{
		if (f) *f = err;
	}
	else
	{
		data.free();
	}
	sz len = libc::ftell(tmp);
	char[] buf = mem::talloc_array(char, len);
	libc::rewind(tmp);
	libc::fread(buf.ptr, 1, (usz)len, tmp);
	return (String)buf;
}
