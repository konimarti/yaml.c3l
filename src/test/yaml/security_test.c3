// Regression tests for the size and time limits on untrusted input (review items S1-S7).
module yaml::security_test;

import std::io, std::time;
import yaml, yaml::parser, yaml::test_util, yaml::api_test;

// S4: the scanner limits flow nesting, so the event API is bounded too (before: '{' x 40 000
// was tokenized completely, in seconds, before the builder saw depth 513)
fn void flow_depth_limit() @test => @pool()
{
	DString ok = dstring::temp();
	ok.append_repeat('{', parser::MAX_DEPTH);
	ok.append_repeat('}', parser::MAX_DEPTH);
	test_util::events(ok.str_view())!!;
	DString deep = dstring::temp();
	deep.append_repeat('[', 40_000);
	deep.append_repeat(']', 40_000);
	Clock start = clock::now();
	test::@error(test_util::events(deep.str_view()), parser::LIMIT_EXCEEDED);
	test::@error(yaml::from_string(deep.str_view(), mem, false), parser::LIMIT_EXCEEDED);
	assert(start.to_now() < (NanoDuration)100_000_000, "the limit must be hit early");
}

// S3: a flow collection used as a key in a flow mapping keeps all its tokens queued; taking
// them one by one was O(n) each (before: 50 000 entries took seconds, valid YAML)
fn void long_queued_key() @test => @pool()
{
	DString s = dstring::temp();
	s.append("{{");
	s.append_repeat("a, ", 50_000);
	s.append("}: x}");
	Clock start = clock::now();
	test_util::events(s.str_view())!!;
	YamlData data = yaml::from_string(s.str_view(), &allocators::LIBC_ALLOCATOR, false)!!;
	data.free();
	assert(start.to_now() < (NanoDuration)500_000_000, "the token queue must be linear");
}

// S1: a collection key is its JSON text, and a nested one is escaped again at every level
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
	Clock start = clock::now();
	foreach (s : (String[]){ flow.str_view(), block.str_view(), many.str_view() })
	{
		test::@error(yaml::from_string(s, mem, false), parser::LIMIT_EXCEEDED);
	}
	assert(start.to_now() < (NanoDuration)500_000_000, "the limit must be hit early");
	YamlData data = yaml::from_string("{[a, {b: c}]: 1}", mem, false)!!;
	defer data.free();
	test::eq(data.get(`["a",{"b":"c"}]`)!!.i, 1);
}

// S2: alias expansion counts the copied bytes, not only the nodes (before: 1 MB of input with
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

// S5: the error report shows at most 60 bytes on each side of the error, not inside a UTF-8
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
	test::eq(api_test::stderr_of(s.str_view(), true), want.str_view());
	s.clear();
	s.append("k: \"");
	for (int i = 0; i < 100; i++) s.append("é");
	s.append("\\q\"\n");
	want.clear();
	want.append("YAML ERROR -- Line 1, Col 205: invalid escape sequence\n");
	for (int i = 0; i < 30; i++) want.append("é");
	want.append("\\q\"\n");
	want.append_repeat(' ', 30);
	want.append("^\n");
	test::eq(api_test::stderr_of(s.str_view(), true), want.str_view());
}
