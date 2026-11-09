// Regression tests for the JSON output and the path lookup.
module yaml::port_output_test;

import std::io;
import yaml;

// A float stays a float in JSON
fn void json_keeps_floats() @test => @pool()
{
	Yaml data = yaml::from_string("[1.0, 5., 1e3, !!float 2, 1.5, 1e300, 1e-7, -0.0, 12]", mem, false)!!;
	defer data.free();
	test::eq(string::tformat("%s", data), "[1.0,5.0,1000.0,2.0,1.5,1e+300,1e-07,-0.0,12]\n");
}

// Empty path segments and array indexes with a leading zero are NOT_FOUND
fn void path_segments() @test => @pool()
{
	Yaml data = yaml::from_string("a: {b: [10, 20], '': e, '01': z, 'x.y': 1}\n~: n\n", mem, false)!!;
	defer data.free();
	test::eq(data.get("a.b.0")!!.as_int()!!, 10);
	test::eq(data.get("a.b.1")!!.as_int()!!, 20);
	test::eq(data.get("a.01")!!.as_string()!!, "z");   // a map key, not an index
	foreach (path : (String[]){ "a.", "a..b", ".a", ".", "a.b.01", "a.b.00", "a.x.y" })
	{
		test::@error(data.get(path), NOT_FOUND);
	}
	Node root = data.get("")!!;
	assert(root["a"].exists(), "the empty path is the whole document");
}

fn void checked_json_writer() @test => @pool()
{
	Yaml data = yaml::from_string("hello: world\nnumber: 42\n", mem, false)!!;
	defer data.free();

	// to_json
	String json_str = data.to_json(tmem)!!;
	test::eq(json_str, "{\"hello\":\"world\",\"number\":42}\n");

	// write_json
	ByteWriter bw;
	bw.tinit();
	sz written = data.write_json(&bw)!!;
	test::eq(bw.str_view(), "{\"hello\":\"world\",\"number\":42}\n");
	test::eq(written, json_str.len);
}
