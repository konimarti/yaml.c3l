// Card 0 checks: the fixtures, the tree primitives and the M1 shim agree with the old code.
module yaml2::contract_test;

import yaml2, yaml2::parser, yaml2::testing;
import yaml::test_util;

fn void node_is_36_bytes() @test
{
	test::eq((int)NodeData::size, 36);
	test::eq((int)Props::size, 56);
	test::eq((int)Span::size, 8);
}

fn void sample_tree_shape() @test
{
	yaml2::Yaml y = testing::sample();
	defer y.free();
	Tree* t = y.tree;
	test::eq((int)t.ndocs, 2);
	uint root = t.nodes[0].first;
	test::eq((int)t.nodes[root].val.len, 11);   // 12 entries, one shadowed
	assert(t.nodes[t.nodes[root].next].kind == NodeKind.SCALAR);
	uint n = t.nodes[root].first;
	test::eq(t.text(t.nodes[n].key), "name");
	test::eq(t.text(t.nodes[n].val), "x");
	test::eq(t.text(t.nodes[t.nodes[n].next].val), "8080");
}

fn void spans() @test
{
	Arena a;
	a.init(mem);
	defer a.free();
	Span s = a.put("hello")!!;
	Span e = a.put("")!!;
	test::eq(parser::resolve({}, &a, s), "hello");
	test::eq(parser::resolve({}, &a, e), "");
	test::eq(parser::resolve({}, &a, parser::const_span(parser::CONST_TAG_YAML)), "tag:yaml.org,2002:");
	test::eq(parser::resolve({}, &a, parser::const_span(parser::CONST_TAG_PRIMARY)), "!");
	char[3] buf = { 'a', 'b', 'c' };
	test::eq(parser::resolve(&buf, &a, { 1, 2 }), "bc");
}

// The shim prints the same event lines as the old parser.
fn void shim_events_match_the_old_parser() @test => @pool()
{
	foreach (s : (String[]){
		"a: 1\nb: [x, 'y', \"z\\n\"]\n", "--- !!str &a text\n...\n", "%TAG !e! tag:example.com,2000:\n---\n!e!foo bar\n",
		"- &x [1, 2]\n- *x\n- |\n  lit\n", "? [a, b]\n: c\n", "" })
	{
		test::eq(testing::events(s)!!, test_util::events(s)!!);
	}
	test::@error(testing::events("a: [b\n"), parser::UNCLOSED_FLOW);
}
