module yaml::scalar_test;

import std::io;
import yaml::parser, yaml::test_util;

fn void double_quoted_escapes() @test => @pool()
{
	String[2][*] cases = {
		{ `"\0"`, "\0" }, { `"\a"`, "\a" }, { `"\b"`, "\b" }, { `"\t"`, "\t" }, { "\"\\\t\"", "\t" },
		{ `"\n"`, "\n" }, { `"\v"`, "\v" }, { `"\f"`, "\f" }, { `"\r"`, "\r" }, { `"\e"`, "\e" },
		{ `"\ "`, " " }, { `"\""`, "\"" }, { `"\/"`, "/" }, { `"\\"`, "\\" },
		{ `"\N"`, "\u0085" }, { `"\_"`, "\u00A0" }, { `"\L"`, "\u2028" }, { `"\P"`, "\u2029" },
		{ `"\x41"`, "A" }, { `"\u00e9"`, "é" }, { `"\U0001F600"`, "😀" },
	};
	foreach (c : cases) test::eq(test_util::scalar(c[0])!!, c[1]);
}

fn void double_quoted_line_continuation() @test => @pool()
{
	test::eq(test_util::scalar("\"a\\\n   b\"")!!, "ab");
	test::eq(test_util::scalar("\"a \\\n\n b\"")!!, "a \nb");
}

fn void double_quoted_folding() @test => @pool()
{
	test::eq(test_util::scalar("\"a  \n  b\t\\t\n c\"")!!, "a b\t\t c");
}

fn void single_quoted_folding() @test => @pool()
{
	test::eq(test_util::scalar("'it''s\n\n  here '")!!, "it's\nhere ");
}

fn void literal_chomping() @test => @pool()
{
	test::eq(test_util::scalar("|\n a\n b\n\n")!!, "a\nb\n");
	test::eq(test_util::scalar("|-\n a\n b\n\n")!!, "a\nb");
	test::eq(test_util::scalar("|+\n a\n b\n\n")!!, "a\nb\n\n");
}

fn void folded_more_indented() @test => @pool()
{
	test::eq(test_util::scalar(">\n a\n b\n\n   c\n d\n")!!, "a b\n\n  c\nd\n");
}

fn void literal_explicit_indent() @test => @pool()
{
	test::eq(test_util::scalar("|2\n   a\n  b\n")!!, " a\nb\n");
}

fn void block_scalar_in_sequence() @test => @pool()
{
	test::eq(test_util::scalar("- >-\n  a\n  b\n# c\n")!!, "a b");
}

fn void invalid_escape() @test => @pool()
{
	test::@error(test_util::scalar(`"a\q"`), parser::INVALID_ESCAPE);
	test::@error(test_util::scalar(`"\x4"`), parser::INVALID_ESCAPE);
}

fn void unclosed_quote() @test => @pool()
{
	test::@error(test_util::scalar("\"a"), parser::UNCLOSED_QUOTE);
	test::@error(test_util::scalar("'a\n"), parser::UNCLOSED_QUOTE);
}

fn void invalid_block_header() @test => @pool()
{
	test::@error(test_util::scalar("|0\n a\n"), parser::INVALID_BLOCK_HEADER);
	test::@error(test_util::scalar("|#c\n a\n"), parser::INVALID_BLOCK_HEADER);
}

fn void quoted_trailing_text() @test => @pool()
{
	test::@error(test_util::scalar("\"a\" b\n"), parser::SYNTAX_ERROR);
}
