module yaml::props_test;

import std::io;
import yaml::parser, yaml::test_util;

fn void tag_directive() @test => @pool()
{
	test::eq(test_util::events("%TAG !e! tag:example.com,2000:app/\n--- !e!foo a\n", " ", false)!!,
		"+DOC --- =VAL <tag:example.com,2000:app/foo> :a -DOC");
}

fn void verbatim_tag() @test => @pool()
{
	test::eq(test_util::events("!<tag:x> a", " ", false)!!, "+DOC =VAL <tag:x> :a -DOC");
}

fn void non_specific_tag() @test => @pool()
{
	test::eq(test_util::events("! a", " ", false)!!, "+DOC =VAL <!> :a -DOC");
	test::eq(test_util::events("!local a", " ", false)!!, "+DOC =VAL <!local> :a -DOC");
}

fn void secondary_tag() @test => @pool()
{
	test::eq(test_util::events("!!str a", " ", false)!!, "+DOC =VAL <tag:yaml.org,2002:str> :a -DOC");
}

fn void tag_percent_escape() @test => @pool()
{
	test::eq(test_util::events("%TAG !e! tag:e/\n--- !e!tag%21 a\n", " ", false)!!, "+DOC --- =VAL <tag:e/tag!> :a -DOC");
}

fn void anchor_and_alias() @test => @pool()
{
	test::eq(test_util::events("- &a [b]\n- *a\n", " ", false)!!, "+DOC +SEQ +SEQ [] &a =VAL :b -SEQ =ALI *a -SEQ -DOC");
	test::eq(test_util::events("&a !!map {}", " ", false)!!, "+DOC +MAP {} &a <tag:yaml.org,2002:map> -MAP -DOC");
}

fn void alias_as_key() @test => @pool()
{
	test::eq(test_util::events("a: &x b\n*x : c\n", " ", false)!!, "+DOC +MAP =VAL :a =VAL &x :b =ALI *x =VAL :c -MAP -DOC");
}

fn void properties_without_node() @test => @pool()
{
	test::eq(test_util::events("- &a\n- !!str\n", " ", false)!!, "+DOC +SEQ =VAL &a : =VAL <tag:yaml.org,2002:str> : -SEQ -DOC");
}

fn void undefined_tag_handle() @test => @pool()
{
	test::@error(test_util::events("!x!y a", " ", false), parser::UNDEFINED_TAG_HANDLE);
	// %TAG handles live for one document only
	test::@error(test_util::events("%TAG !x! t:\n--- !x!a a\n--- !x!b b\n", " ", false), parser::UNDEFINED_TAG_HANDLE);
}

fn void directive_errors() @test => @pool()
{
	test::@error(test_util::events("%YAML 1.2\n%YAML 1.2\n---\n", " ", false), parser::INVALID_DIRECTIVE);
	test::@error(test_util::events("%YAML 1.2\n", " ", false), parser::SYNTAX_ERROR);
	test::@error(test_util::events("a\n...\n%YAML 1.2 x\n---\n", " ", false), parser::SYNTAX_ERROR);
}

fn void double_property() @test => @pool()
{
	test::@error(test_util::events("&a &b c", " ", false), parser::SYNTAX_ERROR);
	test::@error(test_util::events("&a *b", " ", false), parser::SYNTAX_ERROR);
}

// M5 review item 1: reserved directives follow the same document rules as %YAML and %TAG
fn void reserved_directive() @test => @pool()
{
	test::eq(test_util::events("%FOO bar\n--- a\n", " ", false)!!, "+DOC --- =VAL :a -DOC");
	test::@error(test_util::events("k: v\n%x: y\n", " ", false), parser::SYNTAX_ERROR);
	test::@error(test_util::events("|\n %a\n%b\n", " ", false), parser::SYNTAX_ERROR);
	test::@error(test_util::events("%FOO bar\na\n", " ", false), parser::SYNTAX_ERROR);
	test::@error(test_util::events("a\n...\n%FOO\nb\n", " ", false), parser::SYNTAX_ERROR);
}

// M5 review item 2: only YAML 1.x is accepted
fn void yaml_major_version() @test => @pool()
{
	test::eq(test_util::events("%YAML 1.3\n--- a\n", " ", false)!!, "+DOC --- =VAL :a -DOC");
	test::@error(test_util::events("%YAML 2.0\n--- a\n", " ", false), parser::INVALID_DIRECTIVE);
}

// M5 review item 3: a %TAG prefix is a URI ('%XX' decoded) that does not start with a flow indicator
fn void tag_prefix_uri() @test => @pool()
{
	test::eq(test_util::events("%TAG !e! tag:a%21/\n--- !e!x a\n", " ", false)!!, "+DOC --- =VAL <tag:a!/x> :a -DOC");
	test::eq(test_util::events("%TAG ! !foo-\n--- !x a\n", " ", false)!!, "+DOC --- =VAL <!foo-x> :a -DOC");
	test::@error(test_util::events("%TAG !e! ,x\n--- !e!y a\n", " ", false), parser::INVALID_DIRECTIVE);
	test::@error(test_util::events("%TAG !e! {x}\n--- !e!y a\n", " ", false), parser::INVALID_DIRECTIVE);
}
