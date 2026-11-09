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
