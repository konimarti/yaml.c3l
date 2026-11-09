module yaml::api_test;

import std::io, std::time, libc;
import yaml;

fn void get_path() @test => @pool()
{
	YamlData data = yaml::from_string("a:\n  b: [x, y]\n  c: 1\n", mem, false)!!;
	defer data.free();
	test::eq(data.get("a.b.0")!!.s, "x");
	test::eq(data["a.b.1"]!!.s, "y");
	test::eq(data.get("a.c")!!.i, 1);
	test::@error(data.get("a.d"), NOT_FOUND);
	test::@error(data.get("a.b.2"), NOT_FOUND);
	test::@error(data.get("a.b.x"), NOT_FOUND);
	test::@error(data.get("a.c.0"), NOT_FOUND);
}

fn void documents() @test => @pool()
{
	YamlData data = yaml::from_string("a\n---\nx: 1\n---\nc\n", mem, false)!!;
	defer data.free();
	test::eq(data.len(), 3);
	test::eq(data.get_in(1, "x")!!.i, 1);
	test::eq(data.get("")!!.s, "a");
	test::@error(data.get_in(3, "x"), NOT_FOUND);
	test::eq(string::tformat("%s", data), "\"a\"\n{\"x\":1}\n\"c\"\n");
	YamlData empty = yaml::from_string("", mem, false)!!;
	test::eq(empty.len(), 0);
	empty.free();
}

fn void alias_copies() @test => @pool()
{
	YamlData data = yaml::from_string("a: &x {k: [1, 2]}\nb: *x\n", mem, false)!!;
	test::eq(data.get("b.k.1")!!.i, 2);
	assert(data.get("a")!! != data.get("b")!!, "an alias must be a copy");
	assert(data.get("a.k")!! != data.get("b.k")!!);
	data.free();   // no double free
}

fn void alias_after_duplicate_key() @test => @pool()
{
	// the anchored node is replaced (and freed) by the duplicate key; the alias still works
	YamlData data = yaml::from_string("a: &x [1]\na: 2\nb: *x\n", mem, false)!!;
	defer data.free();
	test::eq(data.get("b.0")!!.i, 1);
	test::eq(data.get("a")!!.i, 2);
}

fn void undefined_alias() @test => @pool()
{
	test::@error(yaml::from_string("a: *x\n", mem, false), yaml::UNDEFINED_ALIAS);
	test::@error(yaml::from_string("&x [*x]\n", mem, false), yaml::UNDEFINED_ALIAS);
}

// Bytes written to io::stderr() by from_string(yaml, verbose).
fn long stderr_bytes(String yaml, bool verbose)
{
	CFile tmp = libc::tmpfile();
	defer libc::fclose(tmp);
	File saved = *io::stderr();
	*io::stderr() = file::from_handle(tmp);
	YamlData? data = yaml::from_string(yaml, mem, verbose);
	*io::stderr() = saved;
	if (try data) data.free();
	return libc::ftell(tmp);
}

fn void quiet_errors() @test => @pool()
{
	test::eq(stderr_bytes("a: [b\n", false), 0);
	test::eq(stderr_bytes("a: *x\n", false), 0);
	assert(stderr_bytes("a: [b\n", true) > 0, "verbose errors are printed");
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
	// The test runner's leak-tracking allocator makes each of the ~2 million allocations before
	// the limit slow (seconds in total), so this test uses the plain libc heap, like yamlv.
	Clock start = clock::now();
	test::@error(yaml::from_string(yaml, &allocators::LIBC_ALLOCATOR, false), yaml::LIMIT_EXCEEDED);
	assert(start.to_now() < (NanoDuration)1_000_000_000, "the limit must be hit in < 1 s");
}

fn void nesting_limit() @test => @pool()
{
	DString deep = dstring::temp();
	deep.append_repeat('[', 600);
	deep.append_repeat(']', 600);
	test::@error(yaml::from_string(deep.str_view(), mem, false), yaml::LIMIT_EXCEEDED);
	DString ok = dstring::temp();
	ok.append_repeat('[', yaml::MAX_DEPTH);
	ok.append_repeat(']', yaml::MAX_DEPTH);
	YamlData data = yaml::from_string(ok.str_view(), mem, false)!!;
	data.free();
}

fn void deep_alias_limit() @test => @pool()
{
	// an alias may not push the tree beyond MAX_DEPTH either
	DString s = dstring::temp();
	s.append("a: &a ");
	s.append_repeat('[', 400);
	s.append_repeat(']', 400);
	s.append("\nb: ");
	s.append_repeat('[', 200);
	s.append("*a");
	s.append_repeat(']', 200);
	test::@error(yaml::from_string(s.str_view(), mem, false), yaml::LIMIT_EXCEEDED);
}
