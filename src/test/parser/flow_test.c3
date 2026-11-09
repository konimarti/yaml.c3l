module yaml::flow_test;

import std::io;
import yaml::parser, yaml::test_util;

fn void flow_sequence() @test => @pool()
{
	test::eq(test_util::events("[a, b]", " ", false, false)!!, "+SEQ [] =VAL :a =VAL :b -SEQ");
	test::eq(test_util::events("[a, b, ]", " ", false, false)!!, "+SEQ [] =VAL :a =VAL :b -SEQ");
}

fn void nested_flow_sequence() @test => @pool()
{
	test::eq(test_util::events("[a, [b]]", " ", false, false)!!, "+SEQ [] =VAL :a +SEQ [] =VAL :b -SEQ -SEQ");
}

fn void flow_mapping_missing_value() @test => @pool()
{
	test::eq(test_util::events("{a: 1, b}", " ", false, false)!!, "+MAP {} =VAL :a =VAL :1 =VAL :b =VAL : -MAP");
	test::eq(test_util::events("{: c}", " ", false, false)!!, "+MAP {} =VAL : =VAL :c -MAP");
}

fn void single_pair_in_sequence() @test => @pool()
{
	test::eq(test_util::events("[a: b]", " ", false, false)!!, "+SEQ [] +MAP {} =VAL :a =VAL :b -MAP -SEQ");
	test::eq(test_util::events("[? a : b]", " ", false, false)!!, "+SEQ [] +MAP {} =VAL :a =VAL :b -MAP -SEQ");
}

fn void json_like_key() @test => @pool()
{
	test::eq(test_util::events(`{"a":b}`, " ", false, false)!!, `+MAP {} =VAL "a =VAL :b -MAP`);
}

fn void flow_map_as_block_value() @test => @pool()
{
	test::eq(test_util::events("k: {a: 1,\n  b: 2}\nn: x\n", " ", false, false)!!,
		"+MAP =VAL :k +MAP {} =VAL :a =VAL :1 =VAL :b =VAL :2 -MAP =VAL :n =VAL :x -MAP");
}

fn void flow_collection_as_key() @test => @pool()
{
	test::eq(test_util::events("[a]: b\n", " ", false, false)!!, "+MAP +SEQ [] =VAL :a -SEQ =VAL :b -MAP");
}

fn void multi_line_key_in_flow_map() @test => @pool()
{
	test::eq(test_util::events("{a\n b: c}", " ", false, false)!!, "+MAP {} =VAL :a b =VAL :c -MAP");
}

fn void doubled_comma() @test => @pool()
{
	test::@error(test_util::events("[a, , b]", " ", false, false), parser::SYNTAX_ERROR);
	test::@error(test_util::events("[a,,]", " ", false, false), parser::SYNTAX_ERROR);
	test::@error(test_util::events("[, a]", " ", false, false), parser::SYNTAX_ERROR);
}

fn void unclosed_flow() @test => @pool()
{
	test::@error(test_util::events("[a", " ", false, false), parser::UNCLOSED_FLOW);
	test::@error(test_util::events("{a: [b}", " ", false, false), parser::SYNTAX_ERROR);   // mismatched closer
	test::@error(test_util::events("[a]]", " ", false, false), parser::SYNTAX_ERROR);
}

// Keys directly in a flow mapping have no 1024-character limit
fn void long_flow_map_key() @test => @pool()
{
	DString k = dstring::temp();
	k.append_repeat('a', 1100);
	String key = k.str_view();
	test::eq(test_util::events(string::tformat("{%s: b}", key), " ", false, false)!!, string::tformat("+MAP {} =VAL :%s =VAL :b -MAP", key));
	test::eq(test_util::events(string::tformat(`{"%s": b}`, key), " ", false, false)!!, string::tformat(`+MAP {} =VAL "%s =VAL :b -MAP`, key));
	test::@error(test_util::events(string::tformat("[%s: b]", key), " ", false, false), parser::SYNTAX_ERROR);
}
