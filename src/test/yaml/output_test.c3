// Regression tests for the JSON output and the path lookup (review items L3, L4).
module yaml::output_test;

import std::io;
import yaml;

// L3: a float stays a float in JSON (before: 1.0, 5. and 1e3 were printed as 1, 5 and 1000)
fn void json_keeps_floats() @test => @pool()
{
	YamlData data = yaml::from_string("[1.0, 5., 1e3, !!float 2, 1.5, 1e300, 1e-7, -0.0, 12]", mem, false)!!;
	defer data.free();
	test::eq(string::tformat("%s", data), "[1.0,5.0,1000.0,2.0,1.5,1e+300,1e-07,-0.0,12]\n");
}

// L4: empty path segments and array indexes with a leading zero are NOT_FOUND (before: "a."
// returned the value of the key "" or of the null key, and "a.b.01" was index 1)
fn void path_segments() @test => @pool()
{
	YamlData data = yaml::from_string("a: {b: [10, 20], '': e, '01': z, 'x.y': 1}\n~: n\n", mem, false)!!;
	defer data.free();
	test::eq(data.get("a.b.0")!!.i, 10);
	test::eq(data.get("a.b.1")!!.i, 20);
	test::eq(data.get("a.01")!!.s, "z");   // a map key, not an index
	foreach (path : (String[]){ "a.", "a..b", ".a", ".", "a.b.01", "a.b.00", "a.x.y" })
	{
		test::@error(data.get(path), NOT_FOUND);
	}
	assert(data.get("")!!.has_key("a"), "the empty path is the whole document");
}
