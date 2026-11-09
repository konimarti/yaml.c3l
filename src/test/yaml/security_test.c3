// Regression tests for the size and time limits on untrusted input (review items S1-S7).
module yaml::security_test;

import std::io, std::time;
import yaml, yaml::parser, yaml::test_util;

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
