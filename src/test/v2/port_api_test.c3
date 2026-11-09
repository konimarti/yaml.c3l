module yaml2::port_api_test;

import std::io, libc;
import yaml2, yaml2::parser;
import yaml2::port_test_util;

fn void get_path() @test => @pool()
{
	Yaml data = yaml2::from_string("a:\n  b: [x, y]\n  c: 1\n", mem, false)!!;
	defer data.free();
	test::eq(data.get("a.b.0")!!.as_string()!!, "x");
	test::eq(data["a.b.1"].as_string()!!, "y");
	test::eq(data.get("a.c")!!.as_int()!!, 1);
	test::@error(data.get("a.d"), NOT_FOUND);
	test::@error(data.get("a.b.2"), NOT_FOUND);
	test::@error(data.get("a.b.x"), NOT_FOUND);
	test::@error(data.get("a.c.0"), NOT_FOUND);
}

fn void documents() @test => @pool()
{
	Yaml data = yaml2::from_string("a\n---\nx: 1\n---\nc\n", mem, false)!!;
	defer data.free();
	test::eq(data.len(), 3);
	test::eq(data.get_in(1, "x")!!.as_int()!!, 1);
	test::eq(data.get("")!!.as_string()!!, "a");
	test::@error(data.get_in(3, "x"), NOT_FOUND);
	test::eq(string::tformat("%s", data), "\"a\"\n{\"x\":1}\n\"c\"\n");
	Yaml empty = yaml2::from_string("", mem, false)!!;
	test::eq(empty.len(), 0);
	empty.free();
}

fn void alias_copies() @test => @pool()
{
	Yaml data = yaml2::from_string("a: &x {k: [1, 2]}\nb: *x\n", mem, false)!!;
	defer data.free();
	test::eq(data.get("b.k.1")!!.as_int()!!, 2);
	// In v2, an alias has its own node ID, but shares the subtree of its target without deep copying
	assert(data.get("a")!!.id != data.get("b")!!.id, "an alias must have distinct node id");
	assert(data.get("a.k")!!.id == data.get("b.k")!!.id, "in v2, alias child lookups resolve to target subtree");
}

fn void alias_after_duplicate_key() @test => @pool()
{
	// the anchored node is shadowed by the duplicate key; the alias still works
	Yaml data = yaml2::from_string("a: &x [1]\na: 2\nb: *x\n", mem, false)!!;
	defer data.free();
	test::eq(data.get("b.0")!!.as_int()!!, 1);
	test::eq(data.get("a")!!.as_int()!!, 2);
}

fn void undefined_alias() @test => @pool()
{
	test::@error(yaml2::from_string("a: *x\n", mem, false), yaml2::UNDEFINED_ALIAS);
	test::@error(yaml2::from_string("&x [*x]\n", mem, false), yaml2::UNDEFINED_ALIAS);
}

fn void quiet_errors() @test => @pool()
{
	test::eq(port_test_util::stderr_of("a: [b\n", false).len, 0);
	test::eq(port_test_util::stderr_of("a: *x\n", false).len, 0);
	assert(port_test_util::stderr_of("a: [b\n", true).len > 0, "verbose errors are printed");
}

fn void error_report_format() @test => @pool()
{
	fault f;
	test::eq(port_test_util::stderr_of("k: v\na: \"x\\q\"\nz: 1\n", true, &f),
		"YAML ERROR -- Line 2, Col 6: invalid escape sequence\na: xx\\q\"\n     ^\n");
	test::eq(f, parser::INVALID_ESCAPE);
}

fn void every_fault_is_reported() @test => @pool()
{
	String[*] inputs = { "\"a", "!x!y a", "!!int x", "a: *x", "[a", "|0\n", "- a\nb", "%YAML 2.0\n---\n" };
	fault[*] faults = { parser::UNCLOSED_QUOTE, parser::UNDEFINED_TAG_HANDLE, yaml2::INVALID_INPUT_FORMAT,
		yaml2::UNDEFINED_ALIAS, parser::UNCLOSED_FLOW, parser::INVALID_BLOCK_HEADER, parser::MISSING_COLON,
		parser::INVALID_DIRECTIVE };
	foreach (i, input : inputs)
	{
		fault f;
		test::eq(port_test_util::stderr_of(input, false, &f).len, 0);
		test::eq(f, faults[i]);
		assert(port_test_util::stderr_of(input, true).starts_with("YAML ERROR -- Line "), "the error is printed with its position");
	}
}

fn void billion_laughs() @test => @pool()
{
	String yaml = `a: &a ["x","x","x","x","x","x","x","x","x","x"]
b: &b [*a,*a,*a,*a,*a,*a,*a,*a,*a,*a]
c: &c [*b,*b,*b,*b,*b,*b,*b,*b,*b,*b]
d: &d [*c,*c,*c,*c,*c,*c,*c,*c,*c,*c]
e: &e [*d,*d,*d,*d,*d,*d,*d,*d,*d,*d]
f: &f [*e,*e,*e,*e,*e,*e,*e,*e,*e,*e]
g: &g [*f,*f,*f,*f,*f,*f,*f,*f,*f,*f]
h: &h [*g,*g,*g,*g,*g,*g,*g,*g,*g,*g]
i: &i [*h,*h,*h,*h,*h,*h,*h,*h,*h,*h]
`;
	test::@error(yaml2::from_string(yaml, &allocators::LIBC_ALLOCATOR, false), parser::LIMIT_EXCEEDED);
}

fn void nesting_limit() @test => @pool()
{
	DString deep = dstring::temp();
	deep.append_repeat('[', 600);
	deep.append_repeat(']', 600);
	test::@error(yaml2::from_string(deep.str_view(), mem, false), parser::LIMIT_EXCEEDED);
	DString ok = dstring::temp();
	ok.append_repeat('[', parser::MAX_DEPTH);
	ok.append_repeat(']', parser::MAX_DEPTH);
	Yaml data = yaml2::from_string(ok.str_view(), mem, false)!!;
	data.free();
}

fn void deep_alias_limit() @test => @pool()
{
	// an alias may not push the tree beyond MAX_DEPTH: each part alone is deep, but allowed
	foreach (int depth : { 100, 150 })
	{
		DString s = dstring::temp();
		s.append("a: &a ");
		s.append_repeat('[', depth);
		s.append_repeat(']', depth);
		s.append("\nb: ");
		s.append_repeat('[', depth);
		s.append("*a");
		s.append_repeat(']', depth);
		s.append("\n");
		if (depth * 2 > parser::MAX_DEPTH)
		{
			test::@error(yaml2::from_string(s.str_view(), mem, false), parser::LIMIT_EXCEEDED);
		}
		else
		{
			Yaml data = yaml2::from_string(s.str_view(), mem, false)!!;   // 100 + 100 levels fit
			data.free();
		}
	}
}

fn void nested_anchors_are_not_copied() @test => @pool()
{
	DString s = dstring::temp();
	for (int i = 0; i < 200; i++) s.appendf("&a%d [", i);
	for (int i = 0; i < 10_000; i++) s.append(i ? ",x" : "x");
	s.append_repeat(']', 200);
	TrackingAllocator tracker;
	tracker.init(mem);
	defer tracker.free();
	Yaml data = yaml2::from_string(s.str_view(), &tracker, false)!!;
	defer data.free();
	assert(tracker.total_allocation_count() < 100_000, "nested anchors must not be copied");
	DString path = dstring::temp();
	for (int i = 0; i < 200; i++) path.append(i ? ".0" : "0");
	test::eq(data.get(path.str_view())!!.as_string()!!, "x");
}

fn void anchors_outside_the_tree() @test => @pool()
{
	Yaml data = yaml2::from_string("&k a: 1\nb: *k\nc: &v [1]\nc: 2\nd: *v\n", mem, false)!!;
	defer data.free();
	test::eq(data.get("b")!!.as_string()!!, "a");
	test::eq(data.get("c")!!.as_int()!!, 2);
	test::eq(data.get("d.0")!!.as_int()!!, 1);
}

fn void index_segments() @test => @pool()
{
	Yaml data = yaml2::from_string("a: [x, y, z]\n", mem, false)!!;
	defer data.free();
	test::eq(data.get("a.1")!!.as_string()!!, "y");
	foreach (path : (String[]){ "a.0x1", "a.+1", "a. 1", "a.", "a.-1", "a.3" }) test::@error(data.get(path), NOT_FOUND);
}

fn void parse_by_input_type() @test => @pool()
{
	Yaml a = yaml2::parse("a: 1\n", mem, false)!!;
	defer a.free();
	test::eq(a.get("a")!!.as_int()!!, 1);
	char[] bytes = "a: 2\n";
	Yaml b = yaml2::parse(bytes, mem, false)!!;
	defer b.free();
	test::eq(b.get("a")!!.as_int()!!, 2);
	DString ds = dstring::temp();
	ds.append("a: 3\n");
	Yaml c = yaml2::parse(ds, mem, false)!!;
	defer c.free();
	test::eq(c.get("a")!!.as_int()!!, 3);
	ByteReader reader;
	reader.init("a: 4\n");
	Yaml d = yaml2::parse(&reader, mem, false)!!;
	defer d.free();
	test::eq(d.get("a")!!.as_int()!!, 4);
	test::@error(yaml2::parse("a: [1\n", mem, false), parser::UNCLOSED_FLOW);
}

fn void tparse_uses_tmem() @test => @pool()
{
	Yaml a = yaml2::tparse("k: v\n", false)!!;
	test::eq(a.get("k")!!.as_string()!!, "v");
	test::@error(yaml2::tparse("k: [", false), parser::UNCLOSED_FLOW);
}
