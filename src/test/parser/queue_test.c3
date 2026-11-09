// Regression test for the token queue. In module yaml::parser to see the
// scanner, which is @private.
module yaml::parser;

import yaml::test_util;

// A simple key found late is marked on its queued token, not inserted in front of it: an
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

// next_token moves a head index instead of List.pop_first, a memmove of the whole queue
// (before: a 600 KB flow-map key, valid YAML, took a minute)
fn void next_token_does_not_shift_the_queue() @test => @pool()
{
	DString s = dstring::temp();
	s.append("{{");
	s.append_repeat("a, ", 1000);
	s.append("}: x}");
	Scanner scanner;
	scanner.init(s.str_view(), false);
	scanner.next_token()!!;   // STREAM_START
	scanner.next_token()!!;   // '{'
	scanner.next_token()!!;   // the implied KEY of "{a, …}"
	sz queued = scanner.tokens.len();
	assert(queued > 2000, "the whole key is queued");
	for (int i = 0; i < 1000; i++) scanner.next_token()!!;
	test::eq(scanner.tokens.len(), queued);   // the taken tokens stay until the queue is drained
	assert(test_util::events(s.str_view(), " ", false, false)!!.ends_with("=VAL :a =VAL : -MAP =VAL :x -MAP"));
}
