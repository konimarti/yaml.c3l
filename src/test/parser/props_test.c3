module yaml::props_test;

import std::io;
import yaml::parser;

// The events of the stream after +STR, without -STR, separated by spaces.
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
			case STREAM_START: break;
			case STREAM_END: return out.str_view();
			default:
				if (out.len()) out.append_char(' ');
				out.appendf("%s", e);
		}
	}
}

fn void tag_directive() @test => @pool()
{
	test::eq(body("%TAG !e! tag:example.com,2000:app/\n--- !e!foo a\n")!!,
		"+DOC --- =VAL <tag:example.com,2000:app/foo> :a -DOC");
}

fn void verbatim_tag() @test => @pool()
{
	test::eq(body("!<tag:x> a")!!, "+DOC =VAL <tag:x> :a -DOC");
}

fn void non_specific_tag() @test => @pool()
{
	test::eq(body("! a")!!, "+DOC =VAL <!> :a -DOC");
	test::eq(body("!local a")!!, "+DOC =VAL <!local> :a -DOC");
}

fn void secondary_tag() @test => @pool()
{
	test::eq(body("!!str a")!!, "+DOC =VAL <tag:yaml.org,2002:str> :a -DOC");
}

fn void tag_percent_escape() @test => @pool()
{
	test::eq(body("%TAG !e! tag:e/\n--- !e!tag%21 a\n")!!, "+DOC --- =VAL <tag:e/tag!> :a -DOC");
}

fn void anchor_and_alias() @test => @pool()
{
	test::eq(body("- &a [b]\n- *a\n")!!, "+DOC +SEQ +SEQ [] &a =VAL :b -SEQ =ALI *a -SEQ -DOC");
	test::eq(body("&a !!map {}")!!, "+DOC +MAP {} &a <tag:yaml.org,2002:map> -MAP -DOC");
}

fn void alias_as_key() @test => @pool()
{
	test::eq(body("a: &x b\n*x : c\n")!!, "+DOC +MAP =VAL :a =VAL &x :b =ALI *x =VAL :c -MAP -DOC");
}

fn void properties_without_node() @test => @pool()
{
	test::eq(body("- &a\n- !!str\n")!!, "+DOC +SEQ =VAL &a : =VAL <tag:yaml.org,2002:str> : -SEQ -DOC");
}

fn void undefined_tag_handle() @test => @pool()
{
	test::@error(body("!x!y a"), parser::UNDEFINED_TAG_HANDLE);
	// %TAG handles live for one document only
	test::@error(body("%TAG !x! t:\n--- !x!a a\n--- !x!b b\n"), parser::UNDEFINED_TAG_HANDLE);
}

fn void directive_errors() @test => @pool()
{
	test::@error(body("%YAML 1.2\n%YAML 1.2\n---\n"), parser::INVALID_DIRECTIVE);
	test::@error(body("%YAML 1.2\n"), parser::SYNTAX_ERROR);
	test::@error(body("a\n...\n%YAML 1.2 x\n---\n"), parser::SYNTAX_ERROR);
}

fn void double_property() @test => @pool()
{
	test::@error(body("&a &b c"), parser::SYNTAX_ERROR);
	test::@error(body("&a *b"), parser::SYNTAX_ERROR);
}
