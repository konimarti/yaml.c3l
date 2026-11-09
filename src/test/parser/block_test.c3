module yaml::block_test;

import std::io;
import yaml::parser, yaml::test_util;
import yaml;

fn void block_sequence_simple() @test => @pool()
{
	test::eq(test_util::events("- a\n- b\n")!!, "+STR\n+DOC\n+SEQ\n=VAL :a\n=VAL :b\n-SEQ\n-DOC\n-STR");
}

fn void nested_block_sequence() @test => @pool()
{
	test::eq(test_util::events("-\n  - a\n")!!, "+STR\n+DOC\n+SEQ\n+SEQ\n=VAL :a\n-SEQ\n-SEQ\n-DOC\n-STR");
}

fn void block_mapping_simple() @test => @pool()
{
	test::eq(test_util::events("a: b\nc: d\n")!!, "+STR\n+DOC\n+MAP\n=VAL :a\n=VAL :b\n=VAL :c\n=VAL :d\n-MAP\n-DOC\n-STR");
}

// a sequence at the mapping's own indent
fn void sequence_in_mapping() @test => @pool()
{
	test::eq(test_util::events("key:\n- a\n- b\n")!!, "+STR\n+DOC\n+MAP\n=VAL :key\n+SEQ\n=VAL :a\n=VAL :b\n-SEQ\n-MAP\n-DOC\n-STR");
}

fn void mapping_in_sequence() @test => @pool()
{
	test::eq(test_util::events("- a: b\n  c: d\n")!!, "+STR\n+DOC\n+SEQ\n+MAP\n=VAL :a\n=VAL :b\n=VAL :c\n=VAL :d\n-MAP\n-SEQ\n-DOC\n-STR");
}

// the last explicit key has an empty value
fn void explicit_keys() @test => @pool()
{
	test::eq(test_util::events("? a\n: b\n? c\n")!!, "+STR\n+DOC\n+MAP\n=VAL :a\n=VAL :b\n=VAL :c\n=VAL :\n-MAP\n-DOC\n-STR");
}

// after "key: " a block sequence cannot start on the same line
fn void inline_sequence_not_allowed() @test => @pool()
{
	test::@error(test_util::events("key: - a\n"), parser::SYNTAX_ERROR);
}

// "bad" at the indent of "top" is a key without ':'
fn void missing_colon() @test => @pool()
{
	test::@error(test_util::events("top:\n  a: 1\nbad\n"), parser::MISSING_COLON);
}

// M2 review fixes

fn void from_string_nested_error() @test => @pool()
{
	test::@error(yaml::from_string("- a\nfoo\n", mem, false), parser::MISSING_COLON);
}

fn void plain_blank_lines() @test => @pool()
{
	test::eq(test_util::events("a\n\n\nb\n")!!, "+STR\n+DOC\n=VAL :a\\n\\nb\n-DOC\n-STR");
}

fn void plain_whitespace_lines() @test => @pool()
{
	test::eq(test_util::events("a\n  \n  \nb\n")!!, "+STR\n+DOC\n=VAL :a\\n\\nb\n-DOC\n-STR");
}

fn void plain_crlf() @test => @pool()
{
	test::eq(test_util::events("a\r\nb\r\n")!!, "+STR\n+DOC\n=VAL :a b\n-DOC\n-STR");
}

fn void error_line_after_blank_lines() @test => @pool()
{
	test::@error(test_util::events("top:\n  a: 1\n\n\n\nbad\n"), parser::MISSING_COLON);
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
	test::@error(test_util::events("k: a\n\tb\n"), parser::SYNTAX_ERROR);
	test::@error(test_util::events("- a\n\tb\n"), parser::SYNTAX_ERROR);
	test::@error(test_util::events("k: [a\n\tb]\n"), parser::INVALID_INDENTATION);
	test::eq(test_util::events("k: a\n \tb\n")!!, "+STR\n+DOC\n+MAP\n=VAL :k\n=VAL :a b\n-MAP\n-DOC\n-STR");
}
