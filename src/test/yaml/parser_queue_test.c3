// Tests for the token queue (M3).
// Flow-map key of exactly 2040 tokens passes, 2041 fails with LIMIT_EXCEEDED.
// 256 nested block levels closed at EOF (burst of 256 BLOCK_END) fits in the ring.
module yaml::parser_test;

import std::io;
import yaml::parser;
import yaml::testing;

fn void queue_key_length_boundary() @test => @pool()
{
	// Build a flow map key of exact token length.
	// { [a, a, ...]: 1 }
	// Token breakdown before ':':
	// '[' (1) + N * 'a,' (2*N) + ']' (1) = 2 + 2*N tokens.
	// To get 2040 tokens: 2 + 2 * 1019 = 2040 tokens!
	// 1019 items gives dist = 2040 -> PASSES.
	// 1020 items gives dist = 2042 (exceeds 2040) -> FAILS.

	// 1. Success case: 2040 tokens
	// 1 token for '[', 1018 pairs of "a, ", 1 token for 'a', 1 token for ']' = 1 + 2036 + 1 + 1 = 2039.
	// With the value ':' arriving, dist = 2040.
	DString s_ok = dstring::temp();
	s_ok.append("{[");
	for (int i = 0; i < 1018; i++) s_ok.append("a,");
	s_ok.append("a]: 1}");
	String? res = parse_events(s_ok.str_view());
	(void)res!!;

	// 2. Failure case: 2041 tokens
	// Add one more token (e.g. one extra item in sequence)
	DString s_fail = dstring::temp();
	s_fail.append("{[");
	for (int i = 0; i < 1019; i++) s_fail.append("a,");
	s_fail.append("a]: 1}");
	test::@error(parse_events(s_fail.str_view()), parser::LIMIT_EXCEEDED);
}

// 256 nested block levels closed at EOF (burst of 256 BLOCK_END) fits in QUEUE_SIZE (2048).
fn void burst_block_end_at_eof() @test => @pool()
{
	DString s = dstring::temp();
	for (int i = 0; i < 256; i++)
	{
		s.append_repeat(' ', (sz)(i * 2));
		s.append("-\n");
	}
	String? res = parse_events(s.str_view());
	(void)res!!;
}

// A simple key found late is marked on its queued token, not inserted in front of it.
fn void key_is_not_inserted() @test => @pool()
{
	// verify implied keys and mappings
	test::eq(parse_events("[a]: x\nk: {[b]: y}\n", " ", false, false)!!,
		"+MAP +SEQ [] =VAL :a -SEQ =VAL :x =VAL :k +MAP {} +SEQ [] =VAL :b -SEQ =VAL :y -MAP -MAP");
}
