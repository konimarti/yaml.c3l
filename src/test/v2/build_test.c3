module yaml2::build_test;

import std::io;
import yaml2;
import yaml2::parser;
import yaml::test_util;

fn void self_referencing_alias() @test => @pool()
{
	// &a [*a] must fail with UNDEFINED_ALIAS because anchors register on node completion
	test::@error(yaml2::from_string("&a [*a]", mem, false), yaml2::UNDEFINED_ALIAS);
	test::@error(yaml2::from_string("&a {k: *a}", mem, false), yaml2::UNDEFINED_ALIAS);
}

fn void tag_mismatch_at_parse() @test => @pool()
{
	test::@error(yaml2::from_string("!!int abc", mem, false), yaml2::INVALID_INPUT_FORMAT);
	test::@error(yaml2::from_string("!!bool 123", mem, false), yaml2::INVALID_INPUT_FORMAT);
	test::@error(yaml2::from_string("!!null not_null", mem, false), yaml2::INVALID_INPUT_FORMAT);
	test::@error(yaml2::from_string("!!float xyz", mem, false), yaml2::INVALID_INPUT_FORMAT);
}

fn void null_value_duplicate_key() @test => @pool()
{
	String input = "a: null\na: 1\n";
	yaml2::Yaml y = yaml2::from_string(input, mem, false)!!;
	defer y.free();
	test::eq(y.get("a")!!.as_int()!!, 1);
	test::eq(y.doc(0).len(), 1);
}

fn void anchors_on_scalar_keys() @test => @pool()
{
	String input = "&k a: 1\nb: *k\n";
	yaml2::Yaml y = yaml2::from_string(input, mem, false)!!;
	defer y.free();
	test::eq(y.get("b")!!.as_string()!!, "a");

	// Key shadowed, anchor should still resolve to key
	String input2 = "&k a: 1\na: 2\nb: *k\n";
	yaml2::Yaml y2 = yaml2::from_string(input2, mem, false)!!;
	defer y2.free();
	test::eq(y2.get("b")!!.as_string()!!, "a");
	test::eq(y2.get("a")!!.as_int()!!, 2);
}

fn void nested_maps_dup_tables_realloc() @test => @pool()
{
	// 12 levels of nested maps, each with multiple duplicate keys
	DString s = dstring::temp();
	for (int i = 0; i < 12; i++)
	{
		s.append_repeat(' ', (sz)(i * 2));
		s.appendf("level_%d:\n", i);
		s.append_repeat(' ', (sz)((i + 1) * 2));
		s.append("dup: 1\n");
		s.append_repeat(' ', (sz)((i + 1) * 2));
		s.append("dup: 2\n");
	}
	s.append_repeat(' ', 24);
	s.append("leaf: done\n");

	yaml2::Yaml y = yaml2::from_string(s.str_view(), mem, false)!!;
	defer y.free();
	test::eq(y.get("level_0.dup")!!.as_int()!!, 2);
}

fn void tparse_lifetime() @test => @pool()
{
	yaml2::Yaml y = yaml2::tparse("a: 1\nb: [2, 3]\n", false)!!;
	test::eq(y.get("a")!!.as_int()!!, 1);
	test::eq(y.get("b")!!.len(), 2);
}

fn void alias_bomb() @test => @pool()
{
	// Exponential alias structure that exceeds MAX_ALIAS_NODES
	DString s = dstring::temp();
	s.append("a0: &a0 [x, y]\n");
	for (int i = 1; i <= 22; i++)
	{
		s.appendf("a%d: &a%d [*a%d, *a%d]\n", i, i, i - 1, i - 1);
	}
	test::@error(yaml2::from_string(s.str_view(), mem, false), parser::LIMIT_EXCEEDED);
}

fn void alias_bomb_in_mapping_key() @test => @pool()
{
	DString s = dstring::temp();
	s.append("a0: &a0 [x, y]\n");
	for (int i = 1; i <= 22; i++)
	{
		s.appendf("a%d: &a%d [*a%d, *a%d]\n", i, i, i - 1, i - 1);
	}
	s.append("? *a22\n: val\n");
	test::@error(yaml2::from_string(s.str_view(), mem, false), parser::LIMIT_EXCEEDED);
}

fn void alias_bytes_limit_1mb() @test => @pool()
{
	// 1 MB string aliased 100 times exceeds MAX_ALIAS_BYTES (64 MiB)
	DString s = dstring::temp();
	s.append("base: &base \"");
	s.append_repeat('a', 1_000_000);
	s.append("\"\nlist:\n");
	for (int i = 0; i < 100; i++)
	{
		s.append("  - *base\n");
	}
	test::@error(yaml2::from_string(s.str_view(), mem, false), parser::LIMIT_EXCEEDED);
}

fn void ten_k_dup_map() @test => @pool()
{
	// 10,000 duplicate keys in a single map, executed in O(n)
	DString s = dstring::temp();
	s.append("m:\n");
	for (int i = 1; i <= 10_000; i++)
	{
		s.appendf("  dup: %d\n", i);
	}
	yaml2::Yaml y = yaml2::from_string(s.str_view(), mem, false)!!;
	defer y.free();
	test::eq(y.get("m.dup")!!.as_int()!!, 10_000);
	test::eq(y.get("m")!!.len(), 1);
}

fn void crafted_hash_collisions() @test => @pool()
{
	// Multiple entries in a map with keys designed to test open-addressing linear probing
	DString s = dstring::temp();
	s.append("map:\n");
	for (int i = 0; i < 50; i++)
	{
		s.appendf("  col_%d: %d\n", i, i);
	}
	s.append("  col_10: 999\n");   // duplicate collision

	yaml2::Yaml y = yaml2::from_string(s.str_view(), mem, false)!!;
	defer y.free();
	test::eq(y.get("map.col_10")!!.as_int()!!, 999);
	test::eq(y.get("map.col_0")!!.as_int()!!, 0);
	test::eq(y.get("map.col_49")!!.as_int()!!, 49);
}

fn void complex_and_alias_keys() @test => @pool()
{
	String input =
		"a: &x foo\n"
		"*x : val4\n"
		"? [a, b]\n"
		": val5\n";

	yaml2::Yaml y = yaml2::from_string(input, mem, false)!!;
	defer y.free();

	Node root = y.doc(0);
	test::eq(root.is_map(), true);

	sz count = 0;
	foreach (e : root.entries())
	{
		count++;
		if (e.key == "foo")
		{
			test::eq(e.value.as_string()!!, "val4");
		}
	}
	test::eq(count, 3);
}

fn void check_leak(String input, fault expected = {}) @private
{
	TrackingAllocator tracker;
	tracker.init(mem);
	defer tracker.free();

	yaml2::Yaml? data = yaml2::from_string(input, &tracker, false);
	if (catch err = data)
	{
		assert(expected && err == expected, "expected error %s, got %s", expected, err);
	}
	else
	{
		assert(!expected, "expected error %s for: %s", expected, input);
		data.free();
	}
	assert(!tracker.has_leaks(), "leak detected for: %s (allocs left: %d)", input, tracker.allocation_count());
}

fn void tracking_allocator_clean_on_all_paths() @test => @pool()
{
	// Success paths
	check_leak("a: 1\nb: [2, 3]\nc: {k: v}\n");
	check_leak("- &a [1, 2]\n- *a\n");
	check_leak("dup: 1\ndup: 2\n");
	check_leak("? [a, b]\n: c\n");
	check_leak("---\n");
	check_leak("");

	// Error paths
	check_leak("&a [*a]", yaml2::UNDEFINED_ALIAS);
	check_leak("!!int abc", yaml2::INVALID_INPUT_FORMAT);
	check_leak("!!bool 123", yaml2::INVALID_INPUT_FORMAT);
	check_leak("!!null nope", yaml2::INVALID_INPUT_FORMAT);
	check_leak("unclosed: [1, 2\n", parser::UNCLOSED_FLOW);
	check_leak("a: 1\nb: [x, y]\nbad\n", parser::MISSING_COLON);
}

fn void allocation_count_bounded() @test => @pool()
{
	// Sequence of 50,000 items
	DString s = dstring::temp();
	for (int i = 0; i < 50_000; i++)
	{
		s.append("- item\n");
	}

	TrackingAllocator tracker;
	tracker.init(mem);
	defer tracker.free();

	yaml2::Yaml y = yaml2::from_string(s.str_view(), &tracker, false)!!;
	defer y.free();

	sz total_allocs = tracker.total_allocation_count();
	assert(total_allocs <= 20, "expected <= 20 allocations, got %d", total_allocs);
	test::eq(y.doc(0).len(), 50_000);
}

fn void spilled_keys_duplicate_table() @test => @pool()
{
	// Regression test: DupTable holds Spans, not dangling Strings into spill arena.
	// Build map with >= 9 spilled keys and > 256 bytes of spill, then re-assign some keys.
	DString s = dstring::temp();
	s.append("map:\n");
	for (int i = 0; i < 20; i++)
	{
		s.appendf("  \"\\L\\Lkey_%d_padded_string_with_extra_payload_to_exceed_spill_threshold\": %d\n", i, i);
	}
	for (int i = 0; i < 5; i++)
	{
		s.appendf("  \"\\L\\Lkey_%d_padded_string_with_extra_payload_to_exceed_spill_threshold\": %d\n", i, i + 1000);
	}

	yaml2::Yaml y = yaml2::from_string(s.str_view(), mem, false)!!;
	defer y.free();

	yaml2::Node map = y["map"];
	test::eq(map.len(), 20);

	sz count = 0;
	foreach (e : map.entries())
	{
		count++;
		if (e.value.as_int()!! >= 1000)
		{
			assert(e.value.as_int()!! >= 1000 && e.value.as_int()!! < 1005, "shadowed value updated");
		}
	}
	test::eq(count, 20);
}
