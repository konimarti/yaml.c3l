module yaml::api_nav_test;

import std::collections::object;
import std::io;
import yaml;
import yaml::parser;
import yaml::testing;

fn void sample_json_output() @test => @pool()
{
	yaml::Yaml y = testing::sample();
	defer y.free();
	DString out = dstring::temp();
	out.appendf("%s", y);
	test::eq(out.str_view(), testing::SAMPLE_JSON);
}

fn void hop_test_seq() @test
{
	Tree* t = yaml::new_tree(mem);
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
	Tree* tm = yaml::new_tree(mem);
	defer tm.free();
	uint map_id = tm.add_collection(0, "", MAP);
	uint mprev = 0;
	for (sz i = 0; i < 200_000; i++)
	{
		uint child = tm.new_node(SCALAR, flags: yaml::F_KEY, key: tm.put("k"), val: tm.put("v"));
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

fn void hop_test_docs() @test => @pool()
{
	DString s = dstring::temp();
	for (int i = 0; i < 100_000; i++)
	{
		s.append("--- a\n");
	}
	yaml::Yaml y = yaml::from_string(s.str_view(), mem, false)!!;
	defer y.free();
	test::eq(y.len(), 100_000);

	// Test 1: sequential doc(i) access is O(1) (0 hops)
	y.tree.hops = 0;
	for (sz i = 0; i < y.len(); i++)
	{
		Node d = y.doc(i);
		assert(d.exists(), "document exists");
	}
	assert(y.tree.hops == 0, "hops == 0 for sequential doc(i)");

	// Test 2: docs() cursor iteration is O(1) (0 hops)
	y.tree.hops = 0;
	sz count = 0;
	foreach (d : y.docs())
	{
		assert(d.exists(), "document exists");
		count++;
	}
	test::eq(count, 100_000);
	assert(y.tree.hops == 0, "hops == 0 for docs() cursor");

	// Test 3: non-monotonic / random doc(i) access is O(1) (0 hops)
	y.tree.hops = 0;
	for (sz i = y.len(); i > 0; i--)
	{
		Node d = y.doc(i - 1);
		assert(d.exists(), "document exists");
	}
	assert(y.tree.hops == 0, "hops == 0 for backward doc(i)");

	sz idx = 0;
	for (sz step = 0; step < 100_000; step++)
	{
		idx = (idx + 37997) % y.len();
		Node d = y.doc(idx);
		assert(d.exists(), "document exists");
	}
	assert(y.tree.hops == 0, "hops == 0 for random doc(i)");
}

fn void large_map_lookup_index() @test => @pool()
{
	DString s = dstring::temp();
	s.append("map:\n");
	for (int i = 0; i < 200; i++)
	{
		s.appendf("  k_%d: v_%d\n", i, i);
	}
	s.append("  k_10: shadowed\n");
	yaml::Yaml y = yaml::from_string(s.str_view(), mem, false)!!;
	defer y.free();

	for (int i = 0; i < 200; i++)
	{
		if (i == 10) continue;
		String path = string::tformat("map.k_%d", i);
		Node n = y.get(path)!!;
		test::eq(n.as_string()!!, string::tformat("v_%d", i));
	}
	Node n10 = y.get("map.k_10")!!;
	test::eq(n10.as_string()!!, "shadowed");
	test::@error(y.get("map.non_existent"), NOT_FOUND);
}

fn void default_coalescing_operator() @test
{
	yaml::Yaml y = testing::sample();
	defer y.free();
	long port = y["port"].as_int() ?? 9000;
	test::eq(port, 8080);
	long missing_port = y["missing"].as_int() ?? 9000;
	test::eq(missing_port, 9000);
}

fn void as_int_or_behavior() @test
{
	yaml::Yaml y = testing::sample();
	defer y.free();

	// On missing: gives default
	long d_missing = y["missing"].as_int_or(42)!!;
	test::eq(d_missing, 42);

	// On null ("none" in sample is ~): gives default
	long d_null = y["none"].as_int_or(42)!!;
	test::eq(d_null, 42);

	// On "abc" (in sample, "name" is "x", a string): faults WRONG_KIND
	test::@error(y["name"].as_int_or(42), yaml::WRONG_KIND);
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
	yaml::Yaml y = testing::sample();
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

	Object* obj0 = y.doc(0).to_object()!!;
	defer obj0.free();
	test::eq(obj0.get("dup")!!.i, 2);
	test::eq(obj0.get("copy")!!.s, "x");

	Object* obj1 = y.doc(1).to_object()!!;
	defer obj1.free();
	test::eq(obj1.s, "second");
}

fn void? discard_char(void* data, char c) => (void)0;

fn void budget_limit_exceeded() @test => @pool()
{
	Tree* t = yaml::new_tree(mem);
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
	uint entry_id = t.new_node(SCALAR, flags: yaml::F_KEY | yaml::F_KEY_NODE, key: key_span, val: t.put("val"));
	t.append(map_id, entry_id);

	Node n = (Node){ t, map_id };

	Formatter f;
	f.init(&discard_char, null);
	test::@error(yaml::write_node_json(&f, n), parser::LIMIT_EXCEEDED);
	test::@error(n.to_object(), parser::LIMIT_EXCEEDED);
}

fn void old_get_rules() @test
{
	yaml::Yaml y = testing::sample();
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
	yaml::Yaml y = testing::sample();
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
	// Item through alias has target collection as parent
	test::eq(again_item0.parent().id, list.id);
}

fn void from_file_procfs_and_regular() @test
{
	$if env::LINUX:
		Yaml? yp = yaml::from_file("/proc/self/status", mem, false);
		if (try y = yp)
		{
			defer y.free();
			test::eq(y.len(), 1);
			test::eq(y.doc(0).is_map(), true);
		}
	$endif

	// Regular file
	Yaml y_reg = yaml::from_file("project.json", mem, false)!!;
	defer y_reg.free();
	test::eq(y_reg.len(), 1);
	test::eq(y_reg["version"].as_string()!!, "0.2.0");
}
