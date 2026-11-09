// Memory: every allocation of from_string is released, after a success and after an error.
module yaml2::port_leak_test;

import std::io, std::core::mem::allocators;
import yaml2, yaml2::parser;

fn void check(String input, fault expected = {}) @private
{
	TrackingAllocator tracker;
	tracker.init(mem);
	defer tracker.free();
	Yaml? data = yaml2::from_string(input, &tracker, false);
	if (catch err = data)
	{
		assert(expected && err == expected, "unexpected result for %s: %s", input, err);
	}
	else
	{
		assert(!expected, "expected an error for %s", input);
		data.free();
		data.free();
	}
	assert(tracker.allocation_count() == 0, "leak: %d allocations left for %s", tracker.allocation_count(), input);
}

fn void all_node_kinds() @test => @pool()
{
	check("a: 1\nb: 1.5\nc: true\nd: null\ne: ~\nf: text\ng: 'single'\nh: \"double\\n\"\ni: 0x1F\nj: .inf\nk: !!str 5\n");
	check("- [1, 2, {a: b}]\n- {k: [x, y], \"q\": z}\n- - nested\n  - seq\n- ? [a, b]\n  : c\n");
	check("lit: |\n  one\n  two\nfold: >\n  a\n  b\nempty:\n");
	check("");
	check("a");
	check("[]");
	check("{}");
}

fn void anchors_aliases_and_duplicates() @test => @pool()
{
	check("a: &x [1, 2]\nb: *x\nc: &y {k: v}\nd: [*x, *y, *x]\n");
	check("&k key: 1\nother: *k\n");
	check("a: 1\na: 2\nb: &v [1]\nb: 3\nc: *v\n");
}

fn void multiple_documents() @test => @pool()
{
	check("a: 1\n---\n- b\n---\n&x [c]\n...\n--- {k: &y v, l: *y}\n");
	check("%YAML 1.2\n---\na\n...\n%TAG !e! tag:e,2000:\n--- !e!t b\n");
}

fn void errors_during_the_build() @test => @pool()
{
	check("a: [1, 2\n", parser::UNCLOSED_FLOW);
	check("a: *nope\n", yaml2::UNDEFINED_ALIAS);
	check("&a [*a]\n", yaml2::UNDEFINED_ALIAS);
	check("a: &x 1\n---\nb: *x\n", yaml2::UNDEFINED_ALIAS);
	check("a: 1\nb: [x, *nope]\n", yaml2::UNDEFINED_ALIAS);
	check("a: 1\nb: [x, {y: 2}]\nc: - d\n", parser::SYNTAX_ERROR);
	check("a: 1\nb: [x, y]\nbad\n", parser::MISSING_COLON);
	check("- a\n- &x [b]\n---\n- *y\n", yaml2::UNDEFINED_ALIAS);
	DString deep = dstring::temp();
	deep.append_repeat('[', parser::MAX_DEPTH + 1);
	check(deep.str_view(), parser::LIMIT_EXCEEDED);
	DString ok_then_bad = dstring::temp();
	ok_then_bad.append("a: &x [1, 2]\nb:\n");
	for (int i = 0; i < 40; i++) ok_then_bad.appendf("%*c- [*x, *x]\n", 2, ' ');
	ok_then_bad.append("c: *missing\n");
	check(ok_then_bad.str_view(), yaml2::UNDEFINED_ALIAS);
}
