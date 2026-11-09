module yaml::scalar_test;

import std::io;
import yaml::parser;

// The value of the first scalar event of `yaml`.
fn String? scalar(String yaml)
{
	Parser p;
	p.init(yaml, false);
	while (true)
	{
		Event e = p.next()!;
		if (e.type == SCALAR) return e.value;
		if (e.type == STREAM_END) return NOT_FOUND~;
	}
}

fn void double_quoted_escapes() @test => @pool()
{
	String[2][*] cases = {
		{ `"\0"`, "\0" }, { `"\a"`, "\a" }, { `"\b"`, "\b" }, { `"\t"`, "\t" }, { "\"\\\t\"", "\t" },
		{ `"\n"`, "\n" }, { `"\v"`, "\v" }, { `"\f"`, "\f" }, { `"\r"`, "\r" }, { `"\e"`, "\e" },
		{ `"\ "`, " " }, { `"\""`, "\"" }, { `"\/"`, "/" }, { `"\\"`, "\\" },
		{ `"\N"`, "\u0085" }, { `"\_"`, "\u00A0" }, { `"\L"`, "\u2028" }, { `"\P"`, "\u2029" },
		{ `"\x41"`, "A" }, { `"\u00e9"`, "é" }, { `"\U0001F600"`, "😀" },
	};
	foreach (c : cases) test::eq(scalar(c[0])!!, c[1]);
}

fn void double_quoted_line_continuation() @test => @pool()
{
	test::eq(scalar("\"a\\\n   b\"")!!, "ab");
	test::eq(scalar("\"a \\\n\n b\"")!!, "a \nb");
}

fn void double_quoted_folding() @test => @pool()
{
	test::eq(scalar("\"a  \n  b\t\\t\n c\"")!!, "a b\t\t c");
}

fn void single_quoted_folding() @test => @pool()
{
	test::eq(scalar("'it''s\n\n  here '")!!, "it's\nhere ");
}

fn void literal_chomping() @test => @pool()
{
	test::eq(scalar("|\n a\n b\n\n")!!, "a\nb\n");
	test::eq(scalar("|-\n a\n b\n\n")!!, "a\nb");
	test::eq(scalar("|+\n a\n b\n\n")!!, "a\nb\n\n");
}

fn void folded_more_indented() @test => @pool()
{
	test::eq(scalar(">\n a\n b\n\n   c\n d\n")!!, "a b\n\n  c\nd\n");
}

fn void literal_explicit_indent() @test => @pool()
{
	test::eq(scalar("|2\n   a\n  b\n")!!, " a\nb\n");
}

fn void block_scalar_in_sequence() @test => @pool()
{
	test::eq(scalar("- >-\n  a\n  b\n# c\n")!!, "a b");
}

fn void invalid_escape() @test => @pool()
{
	test::@error(scalar(`"a\q"`), parser::INVALID_ESCAPE);
	test::@error(scalar(`"\x4"`), parser::INVALID_ESCAPE);
}

fn void unclosed_quote() @test => @pool()
{
	test::@error(scalar("\"a"), parser::UNCLOSED_QUOTE);
	test::@error(scalar("'a\n"), parser::UNCLOSED_QUOTE);
}

fn void invalid_block_header() @test => @pool()
{
	test::@error(scalar("|0\n a\n"), parser::INVALID_BLOCK_HEADER);
	test::@error(scalar("|#c\n a\n"), parser::INVALID_BLOCK_HEADER);
}

fn void quoted_trailing_text() @test => @pool()
{
	test::@error(scalar("\"a\" b\n"), parser::SYNTAX_ERROR);
}
