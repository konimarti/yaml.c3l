module yaml::api_test;

import std::io, std::time, libc;
import yaml, yaml::parser;

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

// What from_string(yaml, verbose) writes to io::stderr() (in tmem); `f` gets its fault.
fn String stderr_of(String yaml, bool verbose, fault* f = null)
{
	CFile tmp = libc::tmpfile();
	defer libc::fclose(tmp);
	File saved = *io::stderr();
	*io::stderr() = file::from_handle(tmp);
	YamlData? data = yaml::from_string(yaml, mem, verbose);
	*io::stderr() = saved;
	if (catch err = data)
	{
		if (f) *f = err;
	}
	else
	{
		data.free();
	}
	sz len = libc::ftell(tmp);
	char[] buf = mem::talloc_array(char, len);
	libc::rewind(tmp);
	libc::fread(buf.ptr, 1, (usz)len, tmp);
	return (String)buf;
}

fn void quiet_errors() @test => @pool()
{
	test::eq(stderr_of("a: [b\n", false).len, 0);
	test::eq(stderr_of("a: *x\n", false).len, 0);
	assert(stderr_of("a: [b\n", true).len > 0, "verbose errors are printed");
}

fn void error_report_format() @test => @pool()
{
	fault f;
	test::eq(stderr_of("k: v\na: \"x\\q\"\nz: 1\n", true, &f),
		"YAML ERROR -- Line 2, Col 6: invalid escape sequence\na: \"x\\q\"\n     ^\n");
	test::eq(f, parser::INVALID_ESCAPE);
}

fn void every_fault_is_reported() @test => @pool()
{
	String[*] inputs = { "\"a", "!x!y a", "!!int x", "a: *x", "[a", "|0\n", "- a\nb", "%YAML 2.0\n---\n" };
	fault[*] faults = { parser::UNCLOSED_QUOTE, parser::UNDEFINED_TAG_HANDLE, yaml::INVALID_INPUT_FORMAT,
		yaml::UNDEFINED_ALIAS, parser::UNCLOSED_FLOW, parser::INVALID_BLOCK_HEADER, parser::MISSING_COLON,
		parser::INVALID_DIRECTIVE };
	foreach (i, input : inputs)
	{
		fault f;
		test::eq(stderr_of(input, false, &f).len, 0);
		test::eq(f, faults[i]);
		assert(stderr_of(input, true).starts_with("YAML ERROR -- Line "), "the error is printed with its position");
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
	// The test runner's leak-tracking allocator makes each of the ~2 million allocations before
	// the limit slow (seconds in total), so this test uses the plain libc heap, like yamlv.
	Clock start = clock::now();
	test::@error(yaml::from_string(yaml, &allocators::LIBC_ALLOCATOR, false), parser::LIMIT_EXCEEDED);
	assert(start.to_now() < (NanoDuration)1_000_000_000, "the limit must be hit in < 1 s");
}

fn void nesting_limit() @test => @pool()
{
	DString deep = dstring::temp();
	deep.append_repeat('[', 600);
	deep.append_repeat(']', 600);
	test::@error(yaml::from_string(deep.str_view(), mem, false), parser::LIMIT_EXCEEDED);
	DString ok = dstring::temp();
	ok.append_repeat('[', parser::MAX_DEPTH);
	ok.append_repeat(']', parser::MAX_DEPTH);
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
	test::@error(yaml::from_string(s.str_view(), mem, false), parser::LIMIT_EXCEEDED);
}

// M6 review item 1: anchored nodes are not copied, so nested anchors stay linear in the input
// (before: one copy per enclosing anchor, about 3 million nodes and seconds for this input)
fn void nested_anchors_are_not_copied() @test => @pool()
{
	DString s = dstring::temp();
	for (int i = 0; i < 300; i++) s.appendf("&a%d [", i);
	for (int i = 0; i < 10_000; i++) s.append(i ? ",x" : "x");
	s.append_repeat(']', 300);
	Clock start = clock::now();
	YamlData data = yaml::from_string(s.str_view(), mem, false)!!;
	defer data.free();
	assert(start.to_now() < (NanoDuration)500_000_000, "nested anchors must not be copied");
	DString path = dstring::temp();
	for (int i = 0; i < 300; i++) path.append(i ? ".0" : "0");
	test::eq(data.get(path.str_view())!!.s, "x");
}

// M6 review item 1: an anchored key and an anchored replaced value can still be aliased
fn void anchors_outside_the_tree() @test => @pool()
{
	YamlData data = yaml::from_string("&k a: 1\nb: *k\nc: &v [1]\nc: 2\nd: *v\n", mem, false)!!;
	defer data.free();
	test::eq(data.get("b")!!.s, "a");
	test::eq(data.get("c")!!.i, 2);
	test::eq(data.get("d.0")!!.i, 1);
}

// M6 review item 5: an array index is plain digits
fn void index_segments() @test => @pool()
{
	YamlData data = yaml::from_string("a: [x, y, z]\n", mem, false)!!;
	defer data.free();
	test::eq(data.get("a.1")!!.s, "y");
	foreach (path : (String[]){ "a.0x1", "a.+1", "a. 1", "a.", "a.-1", "a.3" }) test::@error(data.get(path), NOT_FOUND);
}
