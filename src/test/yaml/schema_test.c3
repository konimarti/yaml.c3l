module yaml::schema_test;

import std::io;
import yaml;

// The JSON output of yaml::from_string (one line per document).
fn String? json(String yaml)
{
	Yaml data = yaml::from_string(yaml, mem, false)!;
	defer data.free();
	return string::tformat("%s", data);
}

fn void core_ints() @test => @pool()
{
	test::eq(json("[0o17, 0x1F, -12, +3, 0]")!!, "[15,31,-12,3,0]\n");
}

fn void core_floats() @test => @pool()
{
	test::eq(json("[1e3, .5, 1., -2.5E-1, 0.1]")!!, "[1000.0,0.5,1.0,-0.25,0.1]\n");
	Yaml data = yaml::from_string("[-.Inf, .inf, .nan, .NaN]", mem, false)!!;
	defer data.free();
	test::eq(data.get("0")!!.f, -double::inf);
	test::eq(data.get("1")!!.f, double::inf);
	double nan = data.get("2")!!.f;
	assert(nan != nan);
	test::eq(json("[-.Inf, .nan]")!!, "[null,null]\n");   // no JSON form
}

fn void core_null_and_bool() @test => @pool()
{
	test::eq(json("[~, null, Null, NULL, true, True, FALSE]")!!, "[null,null,null,null,true,true,false]\n");
	test::eq(json("a:\nb: ''\n")!!.len, `{"a":null,"b":""}`.len + 1);
	test::eq(json("")!!, "");
	test::eq(json("---\n")!!, "null\n");
}

fn void not_resolved() @test => @pool()
{
	// quoted, block and tagged scalars stay strings, and so does anything that only looks like a number
	test::eq(json("- \"1\"\n- '2'\n- !!str 1\n- !foo 3\n- 0o8\n- 1x\n- yes\n- |\n  4\n")!!,
		`["1","2","1","3","0o8","1x","yes","4\n"]` "\n");
}

fn void forced_types() @test => @pool()
{
	test::eq(json(`[!!float 1, !!int "7", !!null "", !!bool "true", !!str ~]`)!!, "[1.0,7,null,true,\"~\"]\n");
	Yaml data = yaml::from_string("!!float 1", mem, false)!!;
	defer data.free();
	assert(data.get("")!!.is_float());
}

fn void tag_mismatch() @test => @pool()
{
	test::@error(json("!!int x"), yaml::INVALID_INPUT_FORMAT);
	test::@error(json("!!bool 1"), yaml::INVALID_INPUT_FORMAT);
	test::@error(json("!!null a"), yaml::INVALID_INPUT_FORMAT);
}

fn void int_overflow_is_float() @test => @pool()
{
	test::eq(json("123456789012345678901234567890123456789012")!!, "1.2345678901234568e+41\n");
}

fn void keys() @test => @pool()
{
	test::eq(json("1: a")!!, `{"1":"a"}` "\n");
	test::eq(json("[a]: b")!!, `{"[\"a\"]":"b"}` "\n");
	test::eq(json("~: c")!!, `{"":"c"}` "\n");
	test::eq(json("a: 1\na: 2\n")!!, `{"a":2}` "\n");   // last wins
}

fn void json_string_escapes() @test => @pool()
{
	test::eq(json(`"q\" b\\ n\n t\t c\x01 é"`)!!, `"q\" b\\ n\n t\t c\u0001 é"` "\n");
}

// Doubles near DBL_MAX print (the %.15g text does not read back)
fn void largest_floats() @test => @pool()
{
	test::eq(json("[1.7976931348623157e308, -1.7976931348623157e308]")!!, "[1.7976931348623157e+308,-1.7976931348623157e+308]\n");
}

// Floats out of range are ±inf, not an error
fn void float_out_of_range() @test => @pool()
{
	Yaml data = yaml::from_string("a: 1e400\nb: !!float -1e400\nc: 1" "0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000" "0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000" "0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000" "0000000000\nd: 1e-400\n", mem, false)!!;
	defer data.free();
	test::eq(data.get("a")!!.f, double::inf);
	test::eq(data.get("b")!!.f, -double::inf);
	test::eq(data.get("c")!!.f, double::inf);
	test::eq(data.get("d")!!.f, 0.0);
	test::eq(json("a: 1e400")!!, `{"a":null}` "\n");
}
