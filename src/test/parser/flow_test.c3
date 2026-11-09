module yaml::flow_test;

import std::io;
import yaml::parser;

// The events of a single-document stream between +DOC and -DOC, separated by spaces.
fn String? body(String yaml)
{
	DString out = dstring::temp();
	Parser p;
	p.init(yaml, false);
	while (true)
	{
		Event e = p.next()!;
		switch (e.type)
		{
			case STREAM_END: return out.str_view();
			case STREAM_START:
			case DOCUMENT_START:
			case DOCUMENT_END: break;
			default:
				if (out.len()) out.append_char(' ');
				out.appendf("%s", e);
		}
	}
}

fn void flow_sequence() @test => @pool()
{
	test::eq(body("[a, b]")!!, "+SEQ [] =VAL :a =VAL :b -SEQ");
	test::eq(body("[a, b, ]")!!, "+SEQ [] =VAL :a =VAL :b -SEQ");
}

fn void nested_flow_sequence() @test => @pool()
{
	test::eq(body("[a, [b]]")!!, "+SEQ [] =VAL :a +SEQ [] =VAL :b -SEQ -SEQ");
}

fn void flow_mapping_missing_value() @test => @pool()
{
	test::eq(body("{a: 1, b}")!!, "+MAP {} =VAL :a =VAL :1 =VAL :b =VAL : -MAP");
	test::eq(body("{: c}")!!, "+MAP {} =VAL : =VAL :c -MAP");
}

fn void single_pair_in_sequence() @test => @pool()
{
	test::eq(body("[a: b]")!!, "+SEQ [] +MAP {} =VAL :a =VAL :b -MAP -SEQ");
	test::eq(body("[? a : b]")!!, "+SEQ [] +MAP {} =VAL :a =VAL :b -MAP -SEQ");
}

fn void json_like_key() @test => @pool()
{
	test::eq(body(`{"a":b}`)!!, `+MAP {} =VAL "a =VAL :b -MAP`);
}

fn void flow_map_as_block_value() @test => @pool()
{
	test::eq(body("k: {a: 1,\n  b: 2}\nn: x\n")!!,
		"+MAP =VAL :k +MAP {} =VAL :a =VAL :1 =VAL :b =VAL :2 -MAP =VAL :n =VAL :x -MAP");
}

fn void flow_collection_as_key() @test => @pool()
{
	test::eq(body("[a]: b\n")!!, "+MAP +SEQ [] =VAL :a -SEQ =VAL :b -MAP");
}

fn void multi_line_key_in_flow_map() @test => @pool()
{
	test::eq(body("{a\n b: c}")!!, "+MAP {} =VAL :a b =VAL :c -MAP");
}

fn void doubled_comma() @test => @pool()
{
	test::@error(body("[a, , b]"), parser::SYNTAX_ERROR);
	test::@error(body("[a,,]"), parser::SYNTAX_ERROR);
	test::@error(body("[, a]"), parser::SYNTAX_ERROR);
}

fn void unclosed_flow() @test => @pool()
{
	test::@error(body("[a"), parser::UNCLOSED_FLOW);
	test::@error(body("{a: [b}"), parser::SYNTAX_ERROR);   // mismatched closer
	test::@error(body("[a]]"), parser::SYNTAX_ERROR);
}

// M3/M4 review item 2: keys directly in a flow mapping have no 1024-character limit
fn void long_flow_map_key() @test => @pool()
{
	DString k = dstring::temp();
	k.append_repeat('a', 1100);
	String key = k.str_view();
	test::eq(body(string::tformat("{%s: b}", key))!!, string::tformat("+MAP {} =VAL :%s =VAL :b -MAP", key));
	test::eq(body(string::tformat(`{"%s": b}`, key))!!, string::tformat(`+MAP {} =VAL "%s =VAL :b -MAP`, key));
	test::@error(body(string::tformat("[%s: b]", key)), parser::SYNTAX_ERROR);
}
