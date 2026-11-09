// Regression tests for the size and time limits on untrusted input.
module yaml::port_security_test;

import std::io;
import yaml, yaml::parser, yaml::testing;
import yaml::port_test_util;

// The scanner limits flow nesting, so the event API is bounded too (before: '{' x 40 000
// was tokenized completely, in seconds, before the builder saw depth 513)
fn void flow_depth_limit() @test => @pool()
{
	DString ok = dstring::temp();
	ok.append_repeat('{', parser::MAX_DEPTH);
	ok.append_repeat('}', parser::MAX_DEPTH);
	port_test_util::events(ok.str_view())!!;
	DString deep = dstring::temp();
	deep.append_repeat('[', 40_000);
	deep.append_repeat(']', 40_000);
	test::@error(port_test_util::events(deep.str_view()), parser::LIMIT_EXCEEDED);
	test::@error(yaml::from_string(deep.str_view(), mem, false), parser::LIMIT_EXCEEDED);
}

// A collection key is its JSON text, and a nested one is escaped again at every level
// (before: 64 bytes of '{' needed 2.6 GB and ended in an uncatchable OUT_OF_MEMORY panic)
fn void nested_collection_keys() @test => @pool()
{
	DString flow = dstring::temp();
	flow.append_repeat('{', 24);
	flow.append(`"a"`);
	flow.append_repeat('}', 24);
	DString block = dstring::temp();
	block.append_repeat("? ", 24);
	block.append("a\n");
	// many keys that are each well below the limit (before: 200 KB of input took 800 MB)
	DString many = dstring::temp();
	many.append("{");
	for (int i = 0; i < 1000; i++) many.appendf("{{{{{{{{{{{{{{a}}}}}}}}}}}}}}: %d, ", i);
	many.append("}");
	foreach (s : (String[]){ flow.str_view(), block.str_view(), many.str_view() })
	{
		test::@error(yaml::from_string(s, mem, false), parser::LIMIT_EXCEEDED);
	}
	Yaml data = yaml::from_string("{[a, {b: c}]: 1}", mem, false)!!;
	defer data.free();
	// In v2, dotted get by JSON representation is dropped; collection keys are detached nodes
	test::@error(data.get(`["a",{"b":"c"}]`), NOT_FOUND);
	test::eq(string::tformat("%s", data), `{"[\"a\",{\"b\":\"c\"}]":1}` "\n");
	bool found = false;
	foreach (e : data.doc(0).entries())
	{
		if (e.key_node.is_seq())
		{
			test::eq(e.value.as_int()!!, 1);
			test::eq(e.key_node.len(), 2);
			found = true;
		}
	}
	assert(found, "collection key entry found");
}

// Alias expansion counts the copied bytes, not only the nodes (before: 1 MB of input with
// 2 000 aliases of a 1 MB string needed 2 GB)
fn void alias_bytes_limit() @test => @pool()
{
	DString s = dstring::temp();
	s.append("a: &a ");
	s.append_repeat('x', 1024 * 1024);
	s.append("\nb: [");
	for (int i = 0; i < 100; i++) s.append("*a, ");
	s.append("]\n");
	test::@error(yaml::from_string(s.str_view(), &allocators::LIBC_ALLOCATOR, false), parser::LIMIT_EXCEEDED);

	// keys are copied too
	DString long_key = dstring::temp();
	long_key.append_repeat('y', 1000);
	s.clear();
	s.append("a: &a {");
	for (int i = 0; i < 1000; i++) s.appendf("%d%s: 0, ", i, long_key);
	s.append("}\nb: [");
	for (int i = 0; i < 100; i++) s.append("*a, ");
	s.append("]\n");
	test::@error(yaml::from_string(s.str_view(), &allocators::LIBC_ALLOCATOR, false), parser::LIMIT_EXCEEDED);
}

// The error report shows at most 60 bytes on each side of the error, not inside a UTF-8
// character, and the caret counts characters (before: the whole line, 40 MB for a 20 MB line)
fn void error_excerpt() @test => @pool()
{
	DString s = dstring::temp();
	s.append("k: \"");
	s.append_repeat('a', 100_000);
	s.append("\\q\"\n");
	DString want = dstring::temp();
	want.append("YAML ERROR -- Line 1, Col 100005: invalid escape sequence\n");
	want.append_repeat('a', 60);
	want.append("\\q\"\n");
	want.append_repeat(' ', 60);
	want.append("^\n");
	String got1 = port_test_util::stderr_of(s.str_view(), true);
	test::eq(got1, want.str_view());

	s.clear();
	s.append("k: \"");
	for (int i = 0; i < 100; i++) s.append("é");
	s.append("\\q\"\n");
	String got2 = port_test_util::stderr_of(s.str_view(), true);
	want.clear();
	want.append("YAML ERROR -- Line 1, Col 205: invalid escape sequence\n");
	for (int i = 0; i < 29; i++) want.append("é");
	want.append("?\\q\"\n");
	want.append_repeat(' ', 30);
	want.append("^\n");
	test::eq(got2, want.str_view());
}

// %TAG handles are looked up in a map (before: a list, O(n) per directive and per tag;
// 40 000 directives with as many tags took seconds)
fn void many_tag_directives() @test => @pool()
{
	// In v2, MAX_TAG_DIRECTIVES is 16 per document; exceeding 16 in one document triggers LIMIT_EXCEEDED
	DString too_many = dstring::temp();
	for (int i = 0; i < 17; i++) too_many.appendf("%%TAG !h%d! tag:x,%d:\n", i, i);
	too_many.append("--- a\n");
	test::@error(port_test_util::events(too_many.str_view()), parser::LIMIT_EXCEEDED);

	// Across multiple documents, tag directives reset per document
	DString multi = dstring::temp();
	for (int doc = 0; doc < 100; doc++)
	{
		for (int i = 0; i < 10; i++) multi.appendf("%%TAG !h%d! tag:x,%d,%d:\n", i, doc, i);
		multi.append("--- [!h0!v x]\n...\n");
	}
	multi.append("%TAG !h1! tag:y:\n--- !h1!v x\n");
	String events = port_test_util::events(multi.str_view())!!;
	assert(events.contains("=VAL <tag:x,0,0:v> :x"));
	assert(events.ends_with("=VAL <tag:y:v> :x\n-DOC\n-STR"), "the handles are reset per document");
	test::@error(port_test_util::events("%TAG !a! x\n%TAG !a! y\n--- a\n"), parser::INVALID_DIRECTIVE);
}

// A byte order mark at the start is skipped; only printable characters in valid UTF-8 may
// appear (before: the BOM became part of the first key, NUL was a blank, bad UTF-8 was copied)
fn void input_validation() @test => @pool()
{
	Yaml data = yaml::from_string("\xef\xbb\xbfa: 1\n", mem, false)!!;
	defer data.free();
	test::eq(data.get("a")!!.as_int()!!, 1);
	test::eq(port_test_util::events("\xef\xbb\xbf# comment\n%YAML 1.2\n--- a", " ", false)!!, "+DOC --- =VAL :a -DOC");
	String[*] invalid = {
		"a:\0b", "-\0x", "a: \x01", "a: \x7f", "a: \"\xff\xfe\"", "a: \xc2\x80",
		"a: \xed\xa0\x80" /* surrogate */, "a: \xc0\xaf" /* overlong */, "a: \xef\xbf\xbf", "a: \xe2\x82",
	};
	foreach (s : invalid) test::@error(yaml::from_string(s, mem, false), parser::INVALID_CHARACTER);
	test::eq(port_test_util::scalar("a\tb \u0085 \u00e9 \U0001F600")!!, "a\tb \u0085 \u00e9 \U0001F600");
	test::eq(port_test_util::scalar(`"\0"`)!!, "\0");
}

// A single-line plain scalar is a slice of the input, not a tmem copy (before: every
// scalar was copied, 641 MB RSS for a 34 MB file)
fn void plain_scalar_is_not_copied() @test => @pool()
{
	String input = "key: some value\nnext: multi\n  line\n";
	char[] buf = testing::writable(input);
	Parser p;
	p.init_inplace(buf, false, mem);
	defer p.free();
	String[4] values;
	int n;
	while (true)
	{
		Event e = p.next()!!;
		if (e.type == STREAM_END) break;
		if (e.type == SCALAR) values[n++] = p.text(e.value);
	}
	test::eq(n, 4);
	assert(values[0].ptr == &buf[0] && values[1].ptr == &buf[5] && values[2].ptr == &buf[16]);
	foreach (v : values)
	{
		assert((uptr)v.ptr >= (uptr)buf.ptr && (uptr)v.ptr < (uptr)buf.ptr + buf.len);
	}
	test::eq(values[0], "key");
	test::eq(values[1], "some value");
	test::eq(values[2], "next");
	test::eq(values[3], "multi line");
}

// The alias and key budgets cover all documents of a from_* call, because Yaml keeps
// them all (before: 20 documents that each stayed below the limits needed 2 GB)
fn void limits_cover_the_stream() @test => @pool()
{
	// 2 x 601 000 alias nodes
	DString nodes = dstring::temp();
	for (int doc = 0; doc < 2; doc++)
	{
		nodes.append("--- {a: &a [");
		for (int i = 0; i < 1000; i++) nodes.append("0, ");
		nodes.append("], b: [");
		for (int i = 0; i < 600; i++) nodes.append("*a, ");
		nodes.append("]}\n");
	}
	test::@error(yaml::from_string(nodes.str_view(), &allocators::LIBC_ALLOCATOR, false), parser::LIMIT_EXCEEDED);

	// 2 x 40 MiB copied by aliases
	DString bytes = dstring::temp();
	for (int doc = 0; doc < 2; doc++)
	{
		bytes.append("--- {a: &a ");
		bytes.append_repeat('x', 1024 * 1024);
		bytes.append(", b: [");
		for (int i = 0; i < 40; i++) bytes.append("*a, ");
		bytes.append("]}\n");
	}
	test::@error(yaml::from_string(bytes.str_view(), &allocators::LIBC_ALLOCATOR, false), parser::LIMIT_EXCEEDED);

	// 8 x about 1.8 MB of collection key text
	DString keys = dstring::temp();
	for (int doc = 0; doc < 8; doc++)
	{
		keys.append("--- ");
		keys.append_repeat('{', 19);
		keys.append("a");
		keys.append_repeat('}', 19);
		keys.append("\n");
	}
	test::@error(yaml::from_string(keys.str_view(), mem, false), parser::LIMIT_EXCEEDED);

	// one such document is fine
	Yaml data = yaml::from_string(keys.str_view()[:keys.str_view().index_of("\n")!! + 1], mem, false)!!;
	defer data.free();
	String j = data.to_json(tmem)!!;
	assert(j.len > 0);
}

// The key text budget grows with the input, so a large valid file with many collection
// keys passes (before: a fixed 4 MiB rejected this 1.7 MB file at line 54 616)
fn void many_valid_collection_keys() @test => @pool()
{
	DString s = dstring::temp();
	for (int i = 0; i < 60_000; i++) s.appendf("{a, b, c, d, e, f, g, %d}: v\n", i);
	Yaml data = yaml::from_string(s.str_view(), &allocators::LIBC_ALLOCATOR, false)!!;
	defer data.free();
	test::eq(data.doc(0).len(), 60_000);
	String json = data.to_json(tmem)!!;
	assert(json.len > 0);
}

// The excerpt shows control characters and invalid UTF-8 as '?', so a rejected input
// cannot send escape sequences to the terminal (before: ESC and BEL were echoed)
fn void excerpt_has_no_control_characters() @test => @pool()
{
	test::eq(port_test_util::stderr_of("a: \"\e]0;x\a\e[2J\"\n", true),
		"YAML ERROR -- Line 1, Col 5: control characters are not allowed\na: \"?]0;x??[2J\"\n    ^\n");
	test::eq(port_test_util::stderr_of("é: \xc2\x9b\xff q\n", true),
		"YAML ERROR -- Line 1, Col 5: invalid UTF-8 or a non-printable character\né: ?? q\n   ^\n");
}

// A UTF-8 BOM is legal before the first document and between documents (before: unexpected character)
fn void bom_before_a_document() @test => @pool()
{
	test::eq(port_test_util::events("a\n...\n\xef\xbb\xbf--- b\n", " ", false)!!, "+DOC =VAL :a -DOC ... +DOC --- =VAL :b -DOC");
	test::eq(port_test_util::events("a\n\xef\xbb\xbf--- b\n", " ", false)!!, "+DOC =VAL :a -DOC +DOC --- =VAL :b -DOC");
	test::eq(port_test_util::events("...\n\xef\xbb\xbfk: v\n", " ", false, false)!!, "+MAP =VAL :k =VAL :v -MAP");
	test::eq(port_test_util::events("k:\n  \xef\xbb\xbfv\n", " ", false, false)!!, "+MAP =VAL :k =VAL :\ufeffv -MAP");
	test::@error(port_test_util::events(`"a`), parser::UNCLOSED_QUOTE);
}
