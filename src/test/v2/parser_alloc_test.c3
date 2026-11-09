// Allocation test: next() loop over the whole suite makes 0 allocations and 0 tmem allocations.
module yaml2::parser_test;

import std::io, std::io::path, std::core::mem::allocators;
import yaml2::parser;
import yaml2::testing;

struct AllocTestState
{
	TrackingAllocator* tracker;
	int count;
}

fn bool? check_alloc_file(Path p, bool is_dir, any data)
{
	if (is_dir) return false;
	String s = (String)p;
	if (!s.ends_with("/in.yaml") || s.contains("/tags/") || s.contains("/name/")) return false;

	AllocTestState* state = (AllocTestState*)data;

	// Read input file into temporary memory outside the monitored block
	char[]? content = file::load_temp(s);
	if (catch content) return false;
	char[] buf = content;

	sz alloc_start = state.tracker.total_allocation_count();
	sz tmem_start = allocators::top_temp.used;

	Parser parser;
	parser.init_inplace(buf, false, null);
	while (true)
	{
		Event? e = parser.next();
		if (catch e) break;
		if (e.type == STREAM_END) break;
	}
	parser.free();

	sz alloc_end = state.tracker.total_allocation_count();
	sz tmem_end = allocators::top_temp.used;

	test::eq(alloc_end, alloc_start);
	test::eq(tmem_end, tmem_start);

	state.count++;
	return false;
}

fn void zero_allocation_across_suite() @test => @pool()
{
	TrackingAllocator tracker;
	tracker.init(mem);
	defer tracker.free();

	AllocTestState state = { .tracker = &tracker };
	Path p = path::tnew("test-suite")!!;
	path::traverse(p, &check_alloc_file, &state)!!;

	// Verify all 402 suite cases were checked
	test::eq(state.count, 402);
	test::eq(tracker.total_allocation_count(), 0);
}
