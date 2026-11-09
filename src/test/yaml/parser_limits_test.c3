// Tests for parser limits.
// MAX_DEPTH = 256 for collections and block indents; 257 => LIMIT_EXCEEDED.
// MAX_TAG_DIRECTIVES = 16; 17th => LIMIT_EXCEEDED.
module yaml::parser_test;

import std::io;
import yaml::parser;
import yaml::testing;
import yaml;

fn void depth_256_and_257_flow() @test => @pool()
{
	// Flow nesting 256: passes
	DString s256 = dstring::temp();
	s256.append_repeat('[', parser::MAX_DEPTH);
	s256.append("a");
	s256.append_repeat(']', parser::MAX_DEPTH);
	(void)parse_events(s256.str_view())!!;

	// Flow nesting 257: fails LIMIT_EXCEEDED
	DString s257 = dstring::temp();
	s257.append_repeat('[', parser::MAX_DEPTH + 1);
	s257.append("a");
	s257.append_repeat(']', parser::MAX_DEPTH + 1);
	test::@error(parse_events(s257.str_view()), parser::LIMIT_EXCEEDED);
}

fn void depth_256_and_257_block_indents() @test => @pool()
{
	// Block indents 256: passes
	DString s256 = dstring::temp();
	for (int i = 0; i < parser::MAX_DEPTH; i++)
	{
		s256.append_repeat(' ', (sz)(i * 2));
		s256.append("a:\n");
	}
	s256.append_repeat(' ', (sz)(parser::MAX_DEPTH * 2));
	s256.append("1\n");
	(void)parse_events(s256.str_view())!!;

	// Block indents 257: fails LIMIT_EXCEEDED
	DString s257 = dstring::temp();
	for (int i = 0; i < parser::MAX_DEPTH + 1; i++)
	{
		s257.append_repeat(' ', (sz)(i * 2));
		s257.append("a:\n");
	}
	s257.append_repeat(' ', (sz)((parser::MAX_DEPTH + 1) * 2));
	s257.append("1\n");
	test::@error(parse_events(s257.str_view()), parser::LIMIT_EXCEEDED);
}

fn void depth_256_and_257_indentless_sequence() @test => @pool()
{
	DString s257 = dstring::temp();
	for (int i = 0; i < parser::MAX_DEPTH + 1; i++)
	{
		s257.append_repeat(' ', (sz)(i * 2));
		s257.append("k:\n");
		s257.append_repeat(' ', (sz)(i * 2));
		s257.append("-\n");
	}
	s257.append_repeat(' ', (sz)((parser::MAX_DEPTH + 1) * 2));
	s257.append("1\n");
	test::@error(parse_events(s257.str_view()), parser::LIMIT_EXCEEDED);
}

fn void tag_directives_limit() @test => @pool()
{
	// 16 %TAG directives: passes
	DString s16 = dstring::temp();
	for (int i = 0; i < parser::MAX_TAG_DIRECTIVES; i++)
	{
		s16.appendf("%%TAG !t%d! tag:example.com,2000:t%d/\n", i, i);
	}
	s16.append("---\n!t0!foo\n");
	(void)parse_events(s16.str_view())!!;

	// 17 %TAG directives: fails LIMIT_EXCEEDED
	DString s17 = dstring::temp();
	for (int i = 0; i < parser::MAX_TAG_DIRECTIVES + 1; i++)
	{
		s17.appendf("%%TAG !t%d! tag:example.com,2000:t%d/\n", i, i);
	}
	s17.append("---\n!t0!foo\n");
	test::@error(parse_events(s17.str_view()), parser::LIMIT_EXCEEDED);
}

// Columns beyond 65535 are accepted.
fn void column_beyond_65535_succeeds() @test => @pool()
{
	DString s = dstring::temp();
	s.append_repeat(' ', 65536);
	s.append("a: 1\n");
	(void)parse_events(s.str_view())!!;

	DString s_comment = dstring::temp();
	s_comment.append("# ");
	s_comment.append_repeat('x', 70000);
	s_comment.append("\na: 1\n");
	(void)parse_events(s_comment.str_view())!!;
}

// Repro 1: 80 KB one-line flow sequence
fn void wide_flow_sequence_80kb() @test => @pool()
{
	DString s = dstring::temp();
	s.append("[");
	for (int i = 0; i < 40000; i++) s.append("1,");
	s.append("1]");
	Yaml y = yaml::from_string(s.str_view(), mem, false)!!;
	defer y.free();
	test::eq(y.doc(0).len(), 40001);
	test::eq(y.doc(0).at(0).as_int()!!, 1);
	test::eq(y.doc(0).at(40000).as_int()!!, 1);
	String json = y.to_json(tmem)!!;
	test::eq(json[0], '[');
	test::eq(json[json.len - 2], ']');
	test::eq(json[json.len - 1], '\n');
}

// Repro 2: 100 000-char quoted value in a flow map
fn void wide_quoted_value_100kb() @test => @pool()
{
	DString s = dstring::temp();
	s.append("{\"a\": \"");
	s.append_repeat('x', 100000);
	s.append("\"}");
	Yaml y = yaml::from_string(s.str_view(), mem, false)!!;
	defer y.free();
	test::eq(y.doc(0)["a"].as_string()!!.len, 100000);
	String json = y.to_json(tmem)!!;
	test::eq(json.starts_with("{\"a\":\""), true);
	test::eq(json[json.len - 2], '}');
	test::eq(json[json.len - 1], '\n');
}

// Repro 3: 10 000-key one-line flow map
fn void wide_flow_map_10k_keys() @test => @pool()
{
	DString s = dstring::temp();
	s.append("{");
	for (int i = 0; i < 10000; i++)
	{
		if (i > 0) s.append(",");
		s.appendf("k%d: v", i);
	}
	s.append("}");
	Yaml y = yaml::from_string(s.str_view(), mem, false)!!;
	defer y.free();
	test::eq(y.doc(0).len(), 10000);
	test::eq(y.doc(0)["k0"].as_string()!!, "v");
	test::eq(y.doc(0)["k9999"].as_string()!!, "v");
	String json = y.to_json(tmem)!!;
	test::eq(json[0], '{');
	test::eq(json[json.len - 2], '}');
	test::eq(json[json.len - 1], '\n');
}

// Repro 4: 2.5 MB one-line JSON array with 200 000 items
fn void wide_json_array_200k_items() @test => @pool()
{
	DString s = dstring::temp();
	s.append("[");
	for (int i = 0; i < 200000; i++)
	{
		if (i > 0) s.append(",");
		s.appendf("{\"k\":%d}", i);
	}
	s.append("]");
	Yaml y = yaml::from_string(s.str_view(), mem, false)!!;
	defer y.free();
	test::eq(y.doc(0).len(), 200000);
	test::eq(y.doc(0).at(0)["k"].as_int()!!, 0);
	test::eq(y.doc(0).at(199999)["k"].as_int()!!, 199999);
	String json = y.to_json(tmem)!!;
	test::eq(json[0], '[');
	test::eq(json[json.len - 2], ']');
	test::eq(json[json.len - 1], '\n');
}

// Tag handle length > 65535 fails LIMIT_EXCEEDED.
fn void tag_handle_length_limit_exceeded() @test => @pool()
{
	// In-stream tag handle > 65535
	DString s = dstring::temp();
	s.append("--- !");
	s.append_repeat('a', 65536);
	s.append("!x v\n");
	test::@error(parse_events(s.str_view()), parser::LIMIT_EXCEEDED);

	// %TAG directive handle > 65535
	DString s_dir = dstring::temp();
	s_dir.append("%TAG !");
	s_dir.append_repeat('a', 65536);
	s_dir.append("! tag:example.com,2000:app/\n---\nv\n");
	test::@error(parse_events(s_dir.str_view()), parser::LIMIT_EXCEEDED);
}
