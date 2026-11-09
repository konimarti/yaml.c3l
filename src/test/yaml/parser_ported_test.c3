// Ported parser tests from src/test/parser/ running on yaml::parser::Parser.
module yaml::parser_test;

import std::io;
import yaml::parser;
import yaml::testing;

// ---- block_test ported ----

fn void block_sequence_simple() @test => @pool()
{
	test::eq(parse_events("- a\n- b\n")!!, "+STR\n+DOC\n+SEQ\n=VAL :a\n=VAL :b\n-SEQ\n-DOC\n-STR");
}

fn void nested_block_sequence() @test => @pool()
{
	test::eq(parse_events("-\n  - a\n")!!, "+STR\n+DOC\n+SEQ\n+SEQ\n=VAL :a\n-SEQ\n-SEQ\n-DOC\n-STR");
}

fn void block_mapping_simple() @test => @pool()
{
	test::eq(parse_events("a: b\nc: d\n")!!, "+STR\n+DOC\n+MAP\n=VAL :a\n=VAL :b\n=VAL :c\n=VAL :d\n-MAP\n-DOC\n-STR");
}

fn void sequence_in_mapping() @test => @pool()
{
	test::eq(parse_events("key:\n- a\n- b\n")!!, "+STR\n+DOC\n+MAP\n=VAL :key\n+SEQ\n=VAL :a\n=VAL :b\n-SEQ\n-MAP\n-DOC\n-STR");
}

fn void mapping_in_sequence() @test => @pool()
{
	test::eq(parse_events("- a: b\n  c: d\n")!!, "+STR\n+DOC\n+SEQ\n+MAP\n=VAL :a\n=VAL :b\n=VAL :c\n=VAL :d\n-MAP\n-SEQ\n-DOC\n-STR");
}

fn void explicit_keys() @test => @pool()
{
	test::eq(parse_events("? a\n: b\n? c\n")!!, "+STR\n+DOC\n+MAP\n=VAL :a\n=VAL :b\n=VAL :c\n=VAL :\n-MAP\n-DOC\n-STR");
}

fn void inline_sequence_not_allowed() @test => @pool()
{
	test::@error(parse_events("key: - a\n"), parser::SYNTAX_ERROR);
}

fn void missing_colon() @test => @pool()
{
	test::@error(parse_events("top:\n  a: 1\nbad\n"), parser::MISSING_COLON);
}

fn void plain_blank_lines() @test => @pool()
{
	test::eq(parse_events("a\n\n\nb\n")!!, "+STR\n+DOC\n=VAL :a\\n\\nb\n-DOC\n-STR");
}

fn void plain_whitespace_lines() @test => @pool()
{
	test::eq(parse_events("a\n  \n  \nb\n")!!, "+STR\n+DOC\n=VAL :a\\n\\nb\n-DOC\n-STR");
}

fn void plain_crlf() @test => @pool()
{
	test::eq(parse_events("a\r\nb\r\n")!!, "+STR\n+DOC\n=VAL :a b\n-DOC\n-STR");
}

fn void error_line_after_blank_lines() @test => @pool()
{
	test::@error(parse_events("top:\n  a: 1\n\n\n\nbad\n"), parser::MISSING_COLON);
	Parser p;
	p.init_inplace(testing::writable("top:\n  a: 1\n\n\n\nbad: x\n"), false, mem);
	defer p.free();
	while (true)
	{
		Event e = p.next()!!;
		assert(e.type != STREAM_END, "no scalar 'bad'");
		if (e.type == SCALAR && p.text(e.value) == "bad")
		{
			test::eq(e.start.line, 6);
			return;
		}
	}
}

fn void tab_is_not_indentation() @test => @pool()
{
	test::@error(parse_events("k: a\n\tb\n"), parser::SYNTAX_ERROR);
	test::@error(parse_events("- a\n\tb\n"), parser::SYNTAX_ERROR);
	test::@error(parse_events("k: [a\n\tb]\n"), parser::INVALID_INDENTATION);
	test::eq(parse_events("k: a\n \tb\n")!!, "+STR\n+DOC\n+MAP\n=VAL :k\n=VAL :a b\n-MAP\n-DOC\n-STR");
}

// ---- event_test ported ----

fn void empty_stream() @test => @pool()
{
	test::eq(parse_events("")!!, "+STR\n-STR");
}

fn void single_scalar_a() @test => @pool()
{
	test::eq(parse_events("a\n")!!, "+STR\n+DOC\n=VAL :a\n-DOC\n-STR");
}

fn void explicit_markers() @test => @pool()
{
	test::eq(parse_events("---\na\n...\n")!!, "+STR\n+DOC ---\n=VAL :a\n-DOC ...\n-STR");
}

fn void folded_multiline() @test => @pool()
{
	test::eq(parse_events("a\nb\n\nc\n")!!, "+STR\n+DOC\n=VAL :a b\\nc\n-DOC\n-STR");
}

fn void scalar_with_comment() @test => @pool()
{
	test::eq(parse_events("a # c\n")!!, "+STR\n+DOC\n=VAL :a\n-DOC\n-STR");
}

fn void two_documents() @test => @pool()
{
	test::eq(parse_events("a\n---\nb\n")!!, "+STR\n+DOC\n=VAL :a\n-DOC\n+DOC ---\n=VAL :b\n-DOC\n-STR");
}

fn void escaping_test() @test => @pool()
{
	test::eq(parse_scalar("x\ty\\\n")!!, "x\ty\\");
	test::eq(parse_events("x\ty\\\n", stream: false, docs: false)!!, "=VAL :x\\ty\\\\");
}

fn void unmatched_bracket() @test => @pool()
{
	test::@error(parse_events("]\n"), parser::SYNTAX_ERROR);
}

// ---- flow_test ported ----

fn void flow_sequence() @test => @pool()
{
	test::eq(parse_events("[a, b]", " ", false, false)!!, "+SEQ [] =VAL :a =VAL :b -SEQ");
	test::eq(parse_events("[a, b, ]", " ", false, false)!!, "+SEQ [] =VAL :a =VAL :b -SEQ");
}

fn void nested_flow_sequence() @test => @pool()
{
	test::eq(parse_events("[a, [b]]", " ", false, false)!!, "+SEQ [] =VAL :a +SEQ [] =VAL :b -SEQ -SEQ");
}

fn void flow_mapping_missing_value() @test => @pool()
{
	test::eq(parse_events("{a: 1, b}", " ", false, false)!!, "+MAP {} =VAL :a =VAL :1 =VAL :b =VAL : -MAP");
	test::eq(parse_events("{: c}", " ", false, false)!!, "+MAP {} =VAL : =VAL :c -MAP");
}

fn void single_pair_in_sequence() @test => @pool()
{
	test::eq(parse_events("[a: b]", " ", false, false)!!, "+SEQ [] +MAP {} =VAL :a =VAL :b -MAP -SEQ");
	test::eq(parse_events("[? a : b]", " ", false, false)!!, "+SEQ [] +MAP {} =VAL :a =VAL :b -MAP -SEQ");
}

fn void json_like_key() @test => @pool()
{
	test::eq(parse_events(`{"a":b}`, " ", false, false)!!, `+MAP {} =VAL "a =VAL :b -MAP`);
}

fn void flow_map_as_block_value() @test => @pool()
{
	test::eq(parse_events("k: {a: 1,\n  b: 2}\nn: x\n", " ", false, false)!!,
		"+MAP =VAL :k +MAP {} =VAL :a =VAL :1 =VAL :b =VAL :2 -MAP =VAL :n =VAL :x -MAP");
}

fn void flow_collection_as_key() @test => @pool()
{
	test::eq(parse_events("[a]: b\n", " ", false, false)!!, "+MAP +SEQ [] =VAL :a -SEQ =VAL :b -MAP");
}

fn void multi_line_key_in_flow_map() @test => @pool()
{
	test::eq(parse_events("{a\n b: c}", " ", false, false)!!, "+MAP {} =VAL :a b =VAL :c -MAP");
}

fn void doubled_comma() @test => @pool()
{
	test::@error(parse_events("[a, , b]", " ", false, false), parser::SYNTAX_ERROR);
	test::@error(parse_events("[a,,]", " ", false, false), parser::SYNTAX_ERROR);
	test::@error(parse_events("[, a]", " ", false, false), parser::SYNTAX_ERROR);
}

fn void unclosed_flow() @test => @pool()
{
	test::@error(parse_events("[a", " ", false, false), parser::UNCLOSED_FLOW);
	test::@error(parse_events("{a: [b}", " ", false, false), parser::SYNTAX_ERROR);
	test::@error(parse_events("[a]]", " ", false, false), parser::SYNTAX_ERROR);
}

fn void long_flow_map_key() @test => @pool()
{
	DString k = dstring::temp();
	k.append_repeat('a', 1100);
	String key = k.str_view();
	test::eq(parse_events(string::tformat("{%s: b}", key), " ", false, false)!!, string::tformat("+MAP {} =VAL :%s =VAL :b -MAP", key));
	test::eq(parse_events(string::tformat(`{"%s": b}`, key), " ", false, false)!!, string::tformat(`+MAP {} =VAL "%s =VAL :b -MAP`, key));
	test::@error(parse_events(string::tformat("[%s: b]", key), " ", false, false), parser::SYNTAX_ERROR);
}

// ---- props_test ported ----

fn void tag_directive() @test => @pool()
{
	test::eq(parse_events("%TAG !e! tag:example.com,2000:app/\n--- !e!foo a\n", " ", false)!!,
		"+DOC --- =VAL <tag:example.com,2000:app/foo> :a -DOC");
}

fn void verbatim_tag() @test => @pool()
{
	test::eq(parse_events("!<tag:x> a", " ", false)!!, "+DOC =VAL <tag:x> :a -DOC");
}

fn void non_specific_tag() @test => @pool()
{
	test::eq(parse_events("! a", " ", false)!!, "+DOC =VAL <!> :a -DOC");
	test::eq(parse_events("!local a", " ", false)!!, "+DOC =VAL <!local> :a -DOC");
}

fn void secondary_tag() @test => @pool()
{
	test::eq(parse_events("!!str a", " ", false)!!, "+DOC =VAL <tag:yaml.org,2002:str> :a -DOC");
}

fn void tag_percent_escape() @test => @pool()
{
	test::eq(parse_events("%TAG !e! tag:e/\n--- !e!tag%21 a\n", " ", false)!!, "+DOC --- =VAL <tag:e/tag!> :a -DOC");
}

fn void anchor_and_alias() @test => @pool()
{
	test::eq(parse_events("- &a [b]\n- *a\n", " ", false)!!, "+DOC +SEQ +SEQ [] &a =VAL :b -SEQ =ALI *a -SEQ -DOC");
	test::eq(parse_events("&a !!map {}", " ", false)!!, "+DOC +MAP {} &a <tag:yaml.org,2002:map> -MAP -DOC");
}

fn void alias_as_key() @test => @pool()
{
	test::eq(parse_events("a: &x b\n*x : c\n", " ", false)!!, "+DOC +MAP =VAL :a =VAL &x :b =ALI *x =VAL :c -MAP -DOC");
}

fn void properties_without_node() @test => @pool()
{
	test::eq(parse_events("- &a\n- !!str\n", " ", false)!!, "+DOC +SEQ =VAL &a : =VAL <tag:yaml.org,2002:str> : -SEQ -DOC");
}

fn void undefined_tag_handle() @test => @pool()
{
	test::@error(parse_events("!x!y a", " ", false), parser::UNDEFINED_TAG_HANDLE);
	test::@error(parse_events("%TAG !x! t:\n--- !x!a a\n--- !x!b b\n", " ", false), parser::UNDEFINED_TAG_HANDLE);
}

fn void directive_errors() @test => @pool()
{
	test::@error(parse_events("%YAML 1.2\n%YAML 1.2\n---\n", " ", false), parser::INVALID_DIRECTIVE);
	test::@error(parse_events("%YAML 1.2\n", " ", false), parser::SYNTAX_ERROR);
	test::@error(parse_events("a\n...\n%YAML 1.2 x\n---\n", " ", false), parser::SYNTAX_ERROR);
}

fn void double_property() @test => @pool()
{
	test::@error(parse_events("&a &b c", " ", false), parser::SYNTAX_ERROR);
	test::@error(parse_events("&a *b", " ", false), parser::SYNTAX_ERROR);
}

fn void reserved_directive() @test => @pool()
{
	test::eq(parse_events("%FOO bar\n--- a\n", " ", false)!!, "+DOC --- =VAL :a -DOC");
	test::@error(parse_events("k: v\n%x: y\n", " ", false), parser::SYNTAX_ERROR);
	test::@error(parse_events("|\n %a\n%b\n", " ", false), parser::SYNTAX_ERROR);
	test::@error(parse_events("%FOO bar\na\n", " ", false), parser::SYNTAX_ERROR);
	test::@error(parse_events("a\n...\n%FOO\nb\n", " ", false), parser::SYNTAX_ERROR);
}

fn void yaml_major_version() @test => @pool()
{
	test::eq(parse_events("%YAML 1.3\n--- a\n", " ", false)!!, "+DOC --- =VAL :a -DOC");
	test::@error(parse_events("%YAML 2.0\n--- a\n", " ", false), parser::INVALID_DIRECTIVE);
}

fn void tag_prefix_uri() @test => @pool()
{
	test::eq(parse_events("%TAG !e! tag:a%21/\n--- !e!x a\n", " ", false)!!, "+DOC --- =VAL <tag:a!/x> :a -DOC");
	test::eq(parse_events("%TAG ! !foo-\n--- !x a\n", " ", false)!!, "+DOC --- =VAL <!foo-x> :a -DOC");
	test::@error(parse_events("%TAG !e! ,x\n--- !e!y a\n", " ", false), parser::INVALID_DIRECTIVE);
	test::@error(parse_events("%TAG !e! {x}\n--- !e!y a\n", " ", false), parser::INVALID_DIRECTIVE);
}

fn void tag_prefix_escaped_first_char() @test => @pool()
{
	test::eq(parse_events("%TAG !e! %2Cx\n--- !e!y a\n", " ", false)!!, "+DOC --- =VAL <,xy> :a -DOC");
}

// ---- scalar_test ported ----

fn void double_quoted_escapes() @test => @pool()
{
	String[2][*] cases = {
		{ `"\0"`, "\0" }, { `"\a"`, "\a" }, { `"\b"`, "\b" }, { `"\t"`, "\t" }, { "\"\\\t\"", "\t" },
		{ `"\n"`, "\n" }, { `"\v"`, "\v" }, { `"\f"`, "\f" }, { `"\r"`, "\r" }, { `"\e"`, "\e" },
		{ `"\ "`, " " }, { `"\""`, "\"" }, { `"\/"`, "/" }, { `"\\"`, "\\" },
		{ `"\N"`, "\u0085" }, { `"\_"`, "\u00A0" }, { `"\L"`, "\u2028" }, { `"\P"`, "\u2029" },
		{ `"\x41"`, "A" }, { `"\u00e9"`, "é" }, { `"\U0001F600"`, "😀" },
	};
	foreach (c : cases) test::eq(parse_scalar(c[0])!!, c[1]);
}

fn void double_quoted_line_continuation() @test => @pool()
{
	test::eq(parse_scalar("\"a\\\n   b\"")!!, "ab");
	test::eq(parse_scalar("\"a \\\n\n b\"")!!, "a \nb");
}

fn void double_quoted_folding() @test => @pool()
{
	test::eq(parse_scalar("\"a  \n  b\t\\t\n c\"")!!, "a b\t\t c");
}

fn void single_quoted_folding() @test => @pool()
{
	test::eq(parse_scalar("'it''s\n\n  here '")!!, "it's\nhere ");
}

fn void literal_chomping() @test => @pool()
{
	test::eq(parse_scalar("|\n a\n b\n\n")!!, "a\nb\n");
	test::eq(parse_scalar("|-\n a\n b\n\n")!!, "a\nb");
	test::eq(parse_scalar("|+\n a\n b\n\n")!!, "a\nb\n\n");
}

fn void folded_more_indented() @test => @pool()
{
	test::eq(parse_scalar(">\n a\n b\n\n   c\n d\n")!!, "a b\n\n  c\nd\n");
}

fn void literal_explicit_indent() @test => @pool()
{
	test::eq(parse_scalar("|2\n   a\n  b\n")!!, " a\nb\n");
}

fn void block_scalar_in_sequence() @test => @pool()
{
	test::eq(parse_scalar("- >-\n  a\n  b\n# c\n")!!, "a b");
}

fn void invalid_escape() @test => @pool()
{
	test::@error(parse_scalar(`"a\q"`), parser::INVALID_ESCAPE);
	test::@error(parse_scalar(`"\x4"`), parser::INVALID_ESCAPE);
}

fn void unclosed_quote() @test => @pool()
{
	test::@error(parse_scalar("\"a"), parser::UNCLOSED_QUOTE);
	test::@error(parse_scalar("'a\n"), parser::UNCLOSED_QUOTE);
}

fn void invalid_block_header() @test => @pool()
{
	test::@error(parse_scalar("|0\n a\n"), parser::INVALID_BLOCK_HEADER);
	test::@error(parse_scalar("|#c\n a\n"), parser::INVALID_BLOCK_HEADER);
}

fn void quoted_trailing_text() @test => @pool()
{
	test::@error(parse_scalar("\"a\" b\n"), parser::SYNTAX_ERROR);
}
