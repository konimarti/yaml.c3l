// Regression test for the token queue (re-review N2). In module yaml::parser to see the
// scanner, which is @private.
module yaml::parser;

import yaml::test_util;

// N2: a simple key found late is marked on its queued token, not inserted in front of it: an
// insert into a queue that holds a whole collection key is a memmove of the queue (before:
// 500 nested keys around 1 M entries took 4.3 s)
fn void key_is_not_inserted() @test => @pool()
{
	DString s = dstring::temp();
	s.append("{{");
	s.append_repeat("a, ", 1000);
	s.append("}: x}");
	Scanner scanner;
	scanner.init(s.str_view(), false);
	scanner.next_token()!!;   // STREAM_START
	scanner.next_token()!!;   // '{'
	test::eq(scanner.peek_token()!!.type, TokenType.T_KEY);   // the whole key "{a, …}" is queued now
	foreach (t : scanner.tokens) assert(t.type != TokenType.T_KEY, "the KEY is not stored in the queue");
	// the implied BLOCK_MAPPING_START and KEY come out in order before the key token
	test::eq(test_util::events("[a]: x\nk: {[b]: y}\n", " ", false, false)!!,
		"+MAP +SEQ [] =VAL :a -SEQ =VAL :x =VAL :k +MAP {} +SEQ [] =VAL :b -SEQ =VAL :y -MAP -MAP");
}
