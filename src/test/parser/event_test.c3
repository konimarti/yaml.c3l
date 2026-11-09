module yaml::event_test;

import std::io;
import yaml::parser, yaml::test_util;
import yaml;

fn void empty_stream() @test => @pool()
{
	test::eq(test_util::events("")!!, "+STR\n-STR");
}

fn void single_scalar_a() @test => @pool()
{
	test::eq(test_util::events("a\n")!!, "+STR\n+DOC\n=VAL :a\n-DOC\n-STR");
}

fn void explicit_markers() @test => @pool()
{
	test::eq(test_util::events("---\na\n...\n")!!, "+STR\n+DOC ---\n=VAL :a\n-DOC ...\n-STR");
}

fn void folded_multiline() @test => @pool()
{
	// one line break folds to a space, two give a line feed
	test::eq(test_util::events("a\nb\n\nc\n")!!, "+STR\n+DOC\n=VAL :a b\\nc\n-DOC\n-STR");
}

fn void scalar_with_comment() @test => @pool()
{
	// no trailing space before the comment
	test::eq(test_util::events("a # c\n")!!, "+STR\n+DOC\n=VAL :a\n-DOC\n-STR");
}

fn void two_documents() @test => @pool()
{
	test::eq(test_util::events("a\n---\nb\n")!!, "+STR\n+DOC\n=VAL :a\n-DOC\n+DOC ---\n=VAL :b\n-DOC\n-STR");
}

fn void escaping_test() @test => @pool()
{
	// the scalar keeps TAB and backslash; the event line escapes them
	test::eq(test_util::scalar("x\ty\\\n")!!, "x\ty\\");
	test::eq(test_util::events("x\ty\\\n", stream: false, docs: false)!!, "=VAL :x\\ty\\\\");
}

fn void unmatched_bracket() @test => @pool()
{
	test::@error(test_util::events("]\n"), parser::SYNTAX_ERROR);
}

fn void from_string_single_doc() @test => @pool()
{
	YamlData data = yaml::from_string("a", mem, false)!!;
	defer data.free();
	test::eq(data.len(), 1);
	test::eq(data.get("")!!.s, "a");
}
