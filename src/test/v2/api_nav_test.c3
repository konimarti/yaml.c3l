module yaml2::api_nav_test;

import std::collections::object;
import std::io;
import yaml;
import yaml2;
import yaml2::parser;
import yaml2::testing;
import yaml::test_util;

fn void sample_json_output() @test => @pool()
{
	yaml2::Yaml y = testing::sample();
	defer y.free();
	DString out = dstring::temp();
	out.appendf("%s", y);
	test::eq(out.str_view(), testing::SAMPLE_JSON);
}

fn void hop_test_seq() @test
{
	Tree* t = yaml2::new_tree(mem);
	defer t.free();
	uint seq_id = t.add_collection(0, "", SEQ);
	uint prev = 0;
	for (sz i = 0; i < 200_000; i++)
	{
		uint child = t.new_node(SCALAR, flags: 0, val: t.put("1"));
		t.append_after(seq_id, prev, child);
		prev = child;
	}
	Node seq_node = (Node){ t, seq_id };
	t.hops = 0;
	sz count = 0;
	foreach (x : seq_node.items())
	{
		count++;
	}
	test::eq(count, 200_000);
	assert(t.hops <= 400_000, "hops <= 2*n for sequence items()");
}

fn void hop_test_map() @test
{
	Tree* tm = yaml2::new_tree(mem);
	defer tm.free();
	uint map_id = tm.add_collection(0, "", MAP);
	uint mprev = 0;
	for (sz i = 0; i < 200_000; i++)
	{
		uint child = tm.new_node(SCALAR, flags: yaml2::F_KEY, key: tm.put("k"), val: tm.put("v"));
		tm.append_after(map_id, mprev, child);
		mprev = child;
	}
	Node map_node = (Node){ tm, map_id };
	tm.hops = 0;
	sz mcount = 0;
	foreach (e : map_node.entries())
	{
		mcount++;
	}
	test::eq(mcount, 200_000);
	assert(tm.hops <= 400_000, "hops <= 2*n for map entries()");
}

fn void default_coalescing_operator() @test
{
	yaml2::Yaml y = testing::sample();
	defer y.free();
	long port = y["port"].as_int() ?? 9000;
	test::eq(port, 8080);
	long missing_port = y["missing"].as_int() ?? 9000;
	test::eq(missing_port, 9000);
}

fn void as_int_or_behavior() @test
{
	yaml2::Yaml y = testing::sample();
	defer y.free();

	// On missing: gives default
	long d_missing = y["missing"].as_int_or(42)!!;
	test::eq(d_missing, 42);

	// On null ("none" in sample is ~): gives default
	long d_null = y["none"].as_int_or(42)!!;
	test::eq(d_null, 42);

	// On "abc" (in sample, "name" is "x", a string): faults WRONG_KIND
	test::@error(y["name"].as_int_or(42), yaml2::WRONG_KIND);
}

fn void assert_objects_equal(Object* a, Object* b)
{
	test::eq(a.type, b.type);
	if (a.is_null()) return;
	if (a.is_bool())
	{
		test::eq(a.b, b.b);
		return;
	}
	if (a.is_int())
	{
		test::eq(a.i, b.i);
		return;
	}
	if (a.is_float())
	{
		test::eq(a.f, b.f);
		return;
	}
	if (a.is_string())
	{
		test::eq(a.s, b.s);
		return;
	}
	if (a.is_array())
	{
		test::eq(a.get_len(), b.get_len());
		for (sz i = 0; i < a.get_len(); i++)
		{
			assert_objects_equal(a.get_at(i), b.get_at(i));
		}
		return;
	}
	if (a.is_map())
	{
		test::eq(a.map.len(), b.map.len());
		a.@each_entry(; String key, Object* val)
		{
			assert(b.has_key(key), "key missing in b");
			assert_objects_equal(val, b.get(key)!!);
		};
		return;
	}
}

fn void to_object_sample() @test => @pool()
{
	yaml2::Yaml y = testing::sample();
	defer y.free();

	// Parse the equivalent YAML using the old builder:
	String yaml_source =
		"name: &name x\n"
		"port: 8080\n"
		"ratio: 1.5\n"
		"on: true\n"
		"none: ~\n"
		"list: &list [1, two]\n"
		"nested: {a: {b: c}}\n"
		"dup: 1\n"
		"dup: 2\n"
		"\"\": v\n"
		"copy: *name\n"
		"again: *list\n"
		"---\n"
		"second\n";

	yaml::Yaml old_y = yaml::from_string(yaml_source, mem)!!;
	defer old_y.free();

	Object* obj0 = y.doc(0).to_object()!!;
	defer obj0.free();
	assert_objects_equal(obj0, old_y.docs[0]);

	Object* obj1 = y.doc(1).to_object()!!;
	defer obj1.free();
	assert_objects_equal(obj1, old_y.docs[1]);
}

fn void? discard_char(void* data, char c) => (void)0;

fn void budget_limit_exceeded() @test => @pool()
{
	Tree* t = yaml2::new_tree(mem);
	defer t.free();

	uint map_id = t.add_collection(0, "", MAP);

	// Create a detached sequence as collection key
	uint detached_seq = t.new_node(SEQ);
	// Allocate a large string of 5 MiB to exceed MAX_KEY_TEXT (4 MiB)
	char[] big = alloc::alloc_array(mem, char, 5 * 1024 * 1024);
	defer alloc::free(mem, big.ptr);
	for (sz i = 0; i < big.len; i++) big[i] = 'a';
	uint big_scalar = t.add_scalar(detached_seq, "", (String)big);

	// Link into map as entry with F_KEY_NODE
	Span key_span = { detached_seq, 0 };
	uint entry_id = t.new_node(SCALAR, flags: yaml2::F_KEY | yaml2::F_KEY_NODE, key: key_span, val: t.put("val"));
	t.append(map_id, entry_id);

	Node n = (Node){ t, map_id };

	Formatter f;
	f.init(&discard_char, null);
	test::@error(yaml2::write_node_json(&f, n), parser::LIMIT_EXCEEDED);
	test::@error(n.to_object(), parser::LIMIT_EXCEEDED);
}

fn void old_get_rules() @test
{
	yaml2::Yaml y = testing::sample();
	defer y.free();

	// Root path ""
	test::eq(y.get("")!!.kind(), Kind.MAPPING);
	test::eq(y.doc(0).get("")!!.kind(), Kind.MAPPING);

	// Normal path
	test::eq(y.get("name")!!.as_string()!!, "x");
	test::eq(y.get("port")!!.as_int()!!, 8080);
	test::eq(y.get("ratio")!!.as_float()!!, 1.5);
	test::eq(y.get("on")!!.as_bool()!!, true);
	test::eq(y.get("none")!!.is_null(), true);
	test::eq(y.get("nested.a.b")!!.as_string()!!, "c");

	// Sequences
	test::eq(y.get("list.0")!!.as_int()!!, 1);
	test::eq(y.get("list.1")!!.as_string()!!, "two");

	// Aliases followed
	test::eq(y.get("copy")!!.as_string()!!, "x");
	test::eq(y.get("again.0")!!.as_int()!!, 1);
	test::eq(y.get("again.1")!!.as_string()!!, "two");

	// Last duplicate wins & shadowed skipped
	test::eq(y.get("dup")!!.as_int()!!, 2);

	// Null key
	test::eq(y.get("")!!.kind(), Kind.MAPPING);

	// Empty segment fails
	test::@error(y.get("a."), NOT_FOUND);
	test::@error(y.get(".a"), NOT_FOUND);
	test::@error(y.get("nested..a"), NOT_FOUND);

	// Leading zero sequence index fails
	test::@error(y.get("list.01"), NOT_FOUND);

	// Non-digit sequence index fails
	test::@error(y.get("list.abc"), NOT_FOUND);

	// Missing keys fail
	test::@error(y.get("missing"), NOT_FOUND);
	test::@error(y.get("list.5"), NOT_FOUND);

	// Document 1
	test::eq(y.get_in(1, "")!!.as_string()!!, "second");
	test::@error(y.get_in(2, ""), NOT_FOUND);
}

fn void node_properties_and_parent() @test
{
	yaml2::Yaml y = testing::sample();
	defer y.free();

	Node name = y["name"];
	test::eq(name.anchor(), "name");

	Node list = y["list"];
	test::eq(list.anchor(), "list");

	// Parent navigation
	Node root = y.doc(0);
	test::eq(name.parent().id, root.id);
	test::eq(list.parent().id, root.id);

	// Sequence item parent is target collection
	Node item0 = list.at(0);
	test::eq(item0.parent().id, list.id);

	Node again = y["again"];
	Node again_item0 = again.at(0);
	// Item through alias has target collection as parent (N3)
	test::eq(again_item0.parent().id, list.id);
}
