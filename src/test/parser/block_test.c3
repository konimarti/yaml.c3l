module yaml::block_test;

import std::io;
import yaml::parser;
import yaml;

fn String? events(String yaml)
{
	DString out = dstring::temp();
	Parser p;
	p.init(yaml, false);
	while (true)
	{
		Event e = p.next()!;
		if (out.len() > 0) out.append_char('\n');
		out.appendf("%s", e);
		if (e.type == STREAM_END) return out.str_view();
	}
}

// Test 1: "- a\n- b" → "+SEQ =VAL :a =VAL :b -SEQ"
fn void block_sequence_simple() @test => @pool()
{
	// - a\n- b
	// Should produce: +STR +DOC +SEQ =VAL :a =VAL :b -SEQ -DOC -STR
	test::eq(events("- a\n- b\n")!!, "+STR\n+DOC\n+SEQ\n=VAL :a\n=VAL :b\n-SEQ\n-DOC\n-STR");
}

// Test 2: "-\n  - a" → nested "+SEQ +SEQ =VAL :a -SEQ -SEQ"
fn void nested_block_sequence() @test => @pool()
{
	// -\n  - a
	// Should produce: +STR +DOC +SEQ +SEQ =VAL :a -SEQ -SEQ -DOC -STR
	test::eq(events("-\n  - a\n")!!, "+STR\n+DOC\n+SEQ\n+SEQ\n=VAL :a\n-SEQ\n-SEQ\n-DOC\n-STR");
}

// Test 3: "a: b\nc: d" → one +MAP with 4 scalars
fn void block_mapping_simple() @test => @pool()
{
	// a: b\nc: d
	// Should produce: +STR +DOC +MAP =VAL :a =VAL :b =VAL :c =VAL :d -MAP -DOC -STR
	test::eq(events("a: b\nc: d\n")!!, "+STR\n+DOC\n+MAP\n=VAL :a\n=VAL :b\n=VAL :c\n=VAL :d\n-MAP\n-DOC\n-STR");
}

// Test 4: "key:\n- a\n- b" → zero-indented sequence inside the map
fn void sequence_in_mapping() @test => @pool()
{
	// key:\n- a\n- b
	// Should produce: +STR +DOC +MAP =VAL :key +SEQ =VAL :a =VAL :b -SEQ -MAP -DOC -STR
	test::eq(events("key:\n- a\n- b\n")!!, "+STR\n+DOC\n+MAP\n=VAL :key\n+SEQ\n=VAL :a\n=VAL :b\n-SEQ\n-MAP\n-DOC\n-STR");
}

// Test 5: "- a: b\n  c: d" → map inside a sequence entry
fn void mapping_in_sequence() @test => @pool()
{
	// - a: b\n  c: d
	// Should produce: +STR +DOC +SEQ +MAP =VAL :a =VAL :b =VAL :c =VAL :d -MAP -SEQ -DOC -STR
	test::eq(events("- a: b\n  c: d\n")!!, "+STR\n+DOC\n+SEQ\n+MAP\n=VAL :a\n=VAL :b\n=VAL :c\n=VAL :d\n-MAP\n-SEQ\n-DOC\n-STR");
}

// Test 6: "? a\n: b\n? c" → explicit keys, last value empty (=VAL :)
fn void explicit_keys() @test => @pool()
{
	// ? a\n: b\n? c
	// Should produce: +STR +DOC +MAP =VAL :a =VAL :b =VAL :c =VAL : -MAP -DOC -STR
	test::eq(events("? a\n: b\n? c\n")!!, "+STR\n+DOC\n+MAP\n=VAL :a\n=VAL :b\n=VAL :c\n=VAL :\n-MAP\n-DOC\n-STR");
}

// Test 7: "key: - a" → SYNTAX_ERROR
fn void inline_sequence_not_allowed() @test => @pool()
{
	// key: - a
	// After "key: ", compact_ok is false, so "- a" is not allowed on the same line
	Parser p;
	p.init("key: - a\n", false);
	bool got_error = false;
	while (true)
	{
		Event? ev = p.next();
		if (catch err = ev)
		{
			got_error = true;
			break;
		}
		if (ev.type == STREAM_END) break;
	}
	assert(got_error);
	
	// Test with verbose = false - nothing should be printed
	// We can't easily test stderr output in a unit test, but the error should still occur
	Parser p2;
	p2.init("key: - a\n", false);
	got_error = false;
	while (true)
	{
		Event? ev = p2.next();
		if (catch err = ev)
		{
			got_error = true;
			break;
		}
		if (ev.type == STREAM_END) break;
	}
	assert(got_error);
}

// Test 8: "top:\n  a: 1\nbad" → MISSING_COLON
fn void missing_colon() @test => @pool()
{
	// top:\n  a: 1\nbad
	// "bad" at the same indentation level as "top" but after a mapping should be MISSING_COLON
	Parser p;
	p.init("top:\n  a: 1\nbad\n", true);
	bool got_error = false;
	while (true)
	{
		Event? ev = p.next();
		if (catch err = ev)
		{
			got_error = true;
			break;
		}
		if (ev.type == STREAM_END) break;
	}
	assert(got_error);
}

// M2 review fixes

fn void from_string_nested_error() @test => @pool()
{
	test::@error(yaml::from_string("- a\nfoo\n", mem, false), parser::MISSING_COLON);
}

fn void plain_blank_lines() @test => @pool()
{
	test::eq(events("a\n\n\nb\n")!!, "+STR\n+DOC\n=VAL :a\\n\\nb\n-DOC\n-STR");
}

fn void plain_whitespace_lines() @test => @pool()
{
	test::eq(events("a\n  \n  \nb\n")!!, "+STR\n+DOC\n=VAL :a\\n\\nb\n-DOC\n-STR");
}

fn void plain_crlf() @test => @pool()
{
	test::eq(events("a\r\nb\r\n")!!, "+STR\n+DOC\n=VAL :a b\n-DOC\n-STR");
}

fn void error_line_after_blank_lines() @test => @pool()
{
	test::@error(events("top:\n  a: 1\n\n\n\nbad\n"), parser::MISSING_COLON);
	// the error position comes from the same Mark as the events: "bad" is on line 6
	Parser p;
	p.init("top:\n  a: 1\n\n\n\nbad: x\n", false);
	while (true)
	{
		Event e = p.next()!!;
		assert(e.type != STREAM_END, "no scalar 'bad'");
		if (e.type == SCALAR && e.value == "bad")
		{
			test::eq(e.start.line, 6);
			return;
		}
	}
}

// M3/M4 review item 1: a TAB is not indentation, so a TAB-indented line does not continue a plain scalar
fn void tab_is_not_indentation() @test => @pool()
{
	test::@error(events("k: a\n\tb\n"), parser::SYNTAX_ERROR);
	test::@error(events("- a\n\tb\n"), parser::SYNTAX_ERROR);
	test::@error(events("k: [a\n\tb]\n"), parser::INVALID_INDENTATION);
	test::eq(events("k: a\n \tb\n")!!, "+STR\n+DOC\n+MAP\n=VAL :k\n=VAL :a b\n-MAP\n-DOC\n-STR");
}
