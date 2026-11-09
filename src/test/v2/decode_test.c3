// Tests for yaml2::decode{T}, decode_node, decode_borrowed, and Node.decode.
module yaml2::decode_test;

import std::io;
import yaml2;

enum Level { LOW, MID, HIGH }

struct Db
{
	String host;
	int[3] ports;
	Level level;
}

struct Config
{
	String name;
	bool on;
	double ratio;
	int retries;
	Db db;
	String[] tags;
	Db[] replicas;
}

struct Ints
{
	ichar a; short b; int c; long d; int128 e;
	char f; ushort g; uint h; ulong i; uint128 j;
	float k;
}

fn Yaml parse(String s) => yaml2::tparse(s, false)!!;

fn void scalars_and_nesting() @test => @pool()
{
	Yaml y = parse("name: app\non: true\nratio: 2\ndb:\n  host: h\n  ports: [1, 2]\n  level: HIGH\ntags: [a, b]\nreplicas:\n  - host: r1\n  - {host: r2, level: MID}\n");
	Config c = yaml2::decode{Config}(y, tmem, false)!!;
	test::eq(c.name, "app");
	assert(c.on);
	test::eq(c.ratio, 2.0);
	test::eq(c.db.host, "h");
	test::eq(c.db.ports, (int[3]){ 1, 2, 0 });
	assert(c.db.level == HIGH);
	test::eq(c.tags.len, 2);
	test::eq(c.tags[1], "b");
	test::eq(c.replicas.len, 2);
	test::eq(c.replicas[1].host, "r2");
	assert(c.replicas[1].level == MID);

	// Test Node.decode macro method
	Config c2 = y.doc(0).decode(Config, tmem, false)!!;
	test::eq(c2.name, "app");
	test::eq(c2.db.host, "h");

	// Test decode_node free function
	Config c3 = yaml2::decode_node{Config}(y.doc(0), tmem, false)!!;
	test::eq(c3.name, "app");
	test::eq(c3.db.host, "h");
}

fn void all_integer_types() @test => @pool()
{
	Yaml y = parse("a: -128\nb: -32768\nc: -2147483648\nd: -9223372036854775808\ne: -170141183460469231731687303715884105728\nf: 255\ng: 65535\nh: 4294967295\ni: 18446744073709551615\nj: 5\nk: 1.5\n");
	Ints v = yaml2::decode{Ints}(y, tmem, false)!!;
	test::eq(v.a, -128);
	test::eq(v.b, -32768);
	test::eq(v.c, -2147483648);
	test::eq(v.d, -9223372036854775807 - 1);
	test::eq(v.f, 255);
	test::eq(v.g, 65535);
	test::eq(v.h, 4294967295);
	test::eq(v.i, 18446744073709551615);
	assert(v.j == (uint128)5);
	test::eq(v.k, 1.5f);
}

fn void defaults_and_unknown_keys() @test => @pool()
{
	Yaml y = parse("name: x\nunknown: [1, {a: b}]\nretries: ~\n");
	Config c = yaml2::decode{Config}(y, tmem, false)!!;
	test::eq(c.name, "x");
	test::eq(c.retries, 0);        // missing and null keep the zero value
	test::eq(c.ratio, 0.0);
	test::eq(c.db.host, "");
	test::eq(c.tags.len, 0);
	Config empty = yaml2::decode{Config}(parse("{}\n"), tmem, false)!!;
	test::eq(empty.retries, 0);
	test::@error(yaml2::decode{Config}(parse(""), tmem, false), NOT_FOUND);   // no document
}

fn void range_errors() @test => @pool()
{
	test::@error(yaml2::decode{Ints}(parse("a: 128\n"), tmem, false), yaml2::DECODE_ERROR);
	test::@error(yaml2::decode{Ints}(parse("a: -129\n"), tmem, false), yaml2::DECODE_ERROR);
	test::@error(yaml2::decode{Ints}(parse("f: -1\n"), tmem, false), yaml2::DECODE_ERROR);
	test::@error(yaml2::decode{Ints}(parse("f: 256\n"), tmem, false), yaml2::DECODE_ERROR);
	test::@error(yaml2::decode{Ints}(parse("i: 18446744073709551616\n"), tmem, false), yaml2::DECODE_ERROR);
	test::@error(yaml2::decode{Ints}(parse("j: -1\n"), tmem, false), yaml2::DECODE_ERROR);
}

fn void type_errors() @test => @pool()
{
	test::@error(yaml2::decode{Config}(parse("name: 5\n"), tmem, false), yaml2::DECODE_ERROR);
	test::@error(yaml2::decode{Config}(parse("on: yes please\n"), tmem, false), yaml2::DECODE_ERROR);
	test::@error(yaml2::decode{Config}(parse("retries: x\n"), tmem, false), yaml2::DECODE_ERROR);
	test::@error(yaml2::decode{Config}(parse("retries: 1.5\n"), tmem, false), yaml2::DECODE_ERROR);
	test::@error(yaml2::decode{Config}(parse("db: [1]\n"), tmem, false), yaml2::DECODE_ERROR);
	test::@error(yaml2::decode{Config}(parse("db: {level: NOPE}\n"), tmem, false), yaml2::DECODE_ERROR);
	test::@error(yaml2::decode{Config}(parse("db: {ports: [1, 2, 3, 4]}\n"), tmem, false), yaml2::DECODE_ERROR);
	test::@error(yaml2::decode{Config}(parse("db: {ports: [1, a]}\n"), tmem, false), yaml2::DECODE_ERROR);
	test::@error(yaml2::decode{Config}(parse("tags: x\n"), tmem, false), yaml2::DECODE_ERROR);
	test::@error(yaml2::decode{Config}(parse("tags: [a, 1]\n"), tmem, false), yaml2::DECODE_ERROR);
	test::@error(yaml2::decode{Config}(parse("- a\n"), tmem, false), yaml2::DECODE_ERROR);
	test::@error(yaml2::decode_in{Config}(parse("a: 1\n"), 1, tmem, false), NOT_FOUND);
}

fn void second_document() @test => @pool()
{
	Yaml y = parse("name: one\n---\nname: two\n");
	test::eq(yaml2::decode{Config}(y, tmem, false)!!.name, "one");
	test::eq(yaml2::decode_in{Config}(y, 1, tmem, false)!!.name, "two");
}

fn void free(Allocator a, void* p) @private => alloc::free(a, p);

// Success: everything allocated is the caller's (here freed one by one); failure: nothing is left.
fn void no_leaks() @test => @pool()
{
	String good = "name: app\ndb: {host: h, level: LOW}\ntags: [a, b]\nreplicas: [{host: r1}, {host: r2}]\n";
	TrackingAllocator t;
	t.init(mem);
	defer t.free();
	Yaml y = yaml2::from_string(good, mem, false)!!;
	defer y.free();
	Config c = yaml2::decode{Config}(y, &t, false)!!;
	assert(t.allocation_count() > 0);
	free(&t, c.name.ptr);
	free(&t, c.db.host.ptr);
	foreach (s : c.tags) free(&t, s.ptr);
	free(&t, c.tags.ptr);
	foreach (r : c.replicas) free(&t, r.host.ptr);
	free(&t, c.replicas.ptr);
	test::eq(t.allocation_count(), 0);

	String[] bad = {
		"name: app\ndb: {host: h}\ntags: [a, b]\nreplicas: [{host: r1}, {host: 5}]\n",
		"name: app\ntags: [a, b, 3]\n",
		"name: app\ndb: {level: NOPE}\n",
		"name: app\nretries: 99999999999\n",
		"name: app\ndb: {ports: [1, 2, 3, 4]}\n",
		"name: app\ndb: {ports: [1, x]}\n",
		"name: app\ndb: [1, 2]\n",
		"name: app\non: invalid_bool\n",
		"name: 12345\n",
		"- a\n",
	};
	foreach (b : bad)
	{
		Yaml yb = yaml2::from_string(b, mem, false)!!;
		defer yb.free();
		test::@error(yaml2::decode{Config}(yb, &t, false), yaml2::DECODE_ERROR);
		test::eq(t.allocation_count(), 0);
	}
}

struct Simple
{
	String title;
	int count;
	String desc;
}

fn void decode_borrowed_test() @test => @pool()
{
	TrackingAllocator t;
	t.init(mem);
	defer t.free();

	// 1. A struct with strings and scalars makes EXACTLY 0 allocations in decode_borrowed
	Yaml y_simple = yaml2::from_string("title: hello\ncount: 42\ndesc: world\n", mem, false)!!;
	defer y_simple.free();
	Simple s = yaml2::decode_borrowed{Simple}(y_simple.doc(0), &t, false)!!;
	test::eq(s.title, "hello");
	test::eq(s.count, 42);
	test::eq(s.desc, "world");
	test::eq(t.allocation_count(), 0);

	// Also verify Node.decode_borrowed macro
	Simple s_macro = y_simple.doc(0).decode_borrowed(Simple, &t, false)!!;
	test::eq(s_macro.title, "hello");
	test::eq(s_macro.count, 42);
	test::eq(s_macro.desc, "world");
	test::eq(t.allocation_count(), 0);

	// 2. A struct with slices allocates only the slice buffers, 0 string allocations
	String good = "name: app\ndb: {host: h, level: LOW}\ntags: [a, b]\nreplicas: [{host: r1}, {host: r2}]\n";
	Yaml y_complex = yaml2::from_string(good, mem, false)!!;
	defer y_complex.free();
	Config c = yaml2::decode_borrowed{Config}(y_complex.doc(0), &t, false)!!;
	// Allocations: tags slice buffer (1) + replicas slice buffer (1) = 2 allocations
	test::eq(t.allocation_count(), 2);
	test::eq(c.name, "app");
	test::eq(c.db.host, "h");
	test::eq(c.tags.len, 2);
	test::eq(c.tags[0], "a");
	test::eq(c.tags[1], "b");
	test::eq(c.replicas.len, 2);
	test::eq(c.replicas[0].host, "r1");
	test::eq(c.replicas[1].host, "r2");

	// Free the two slice buffers:
	free(&t, c.tags.ptr);
	free(&t, c.replicas.ptr);
	test::eq(t.allocation_count(), 0);

	// 3. Error path unwinding with decode_borrowed leaves 0 allocations
	String[] bad = {
		"name: app\ndb: {host: h}\ntags: [a, b]\nreplicas: [{host: r1}, {host: 5}]\n",
		"name: app\ntags: [a, b, 3]\n",
		"name: app\ndb: {level: NOPE}\n",
		"name: app\nretries: 99999999999\n",
	};
	foreach (b : bad)
	{
		Yaml yb = yaml2::from_string(b, mem, false)!!;
		defer yb.free();
		test::@error(yaml2::decode_borrowed{Config}(yb.doc(0), &t, false), yaml2::DECODE_ERROR);
		test::eq(t.allocation_count(), 0);
	}
}
