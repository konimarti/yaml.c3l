// Benchmark: parse a file N times with the tree API, the event API, decode, find, foreach, json, free.
// usage: bench <mode> <file> [iterations]
// Prints one CSV line (see bench/README.md); bench/run.sh runs it once per file and mode.
module bench;

import std::io, std::time, std::sort, std::collections::list, std::collections::object;
import yaml;
import yaml::parser;

struct Server
{
	String name;
	String host;
	int port;
	bool tls;
	double weight;
	String[] tags;
}

struct Config
{
	String name;
	Server[] servers;
}

// ---- the library API ----


// Tree: parse via from_string, return number of documents, free.
fn sz run_tree(String input, Allocator a, bool expect_reject = false)
{
	yaml::Yaml? data = yaml::from_string(input, a, false);
	if (catch err = data) return (expect_reject && err == yaml::parser::LIMIT_EXCEEDED) ? 0 : -1;
	defer data.free();
	return expect_reject ? -1 : data.len();
}

// Tree: parse via from_buffer in-place, return number of documents, free.
fn sz run_from_buffer(char[] buf, Allocator a, bool expect_reject = false)
{
	yaml::Yaml? data = yaml::from_buffer(buf, a, false);
	if (catch err = data) return (expect_reject && err == yaml::parser::LIMIT_EXCEEDED) ? 0 : -1;
	defer data.free();
	return expect_reject ? -1 : data.len();
}


// Events only: no tree, in-place scanner.
fn sz run_events(char[] buf, bool expect_reject = false) => @pool()
{
	yaml::parser::Parser p;
	p.init_inplace(buf, false, mem);
	defer p.free();
	sz n;
	while (true)
	{
		yaml::parser::Event? e = p.next();
		if (catch err = e) return (expect_reject && err == yaml::parser::LIMIT_EXCEEDED) ? 0 : -1;
		n++;
		if (e.type == STREAM_END) return expect_reject ? -1 : n;
	}
}


// New load tree.
fn yaml::Yaml? load_tree(String input) => yaml::from_string(input, mem, false);


// New decode{Config}
fn sz run_decode(yaml::Yaml tree, Allocator a)
{
	Config? c = yaml::decode{Config}(tree, a, false);
	if (catch c) return -1;
	return c.servers.len;
}


// New JSON serialization
fn sz run_json(yaml::Yaml tree) => @pool()
{
	String s = string::tformat("%s", tree);
	return s.len;
}


// New find: look up 1,000 keys
fn sz run_find(yaml::Yaml tree)
{
	sz found = 0;
	for (int i = 0; i < 1000; i++)
	{
		String key = string::tformat("map_100k.k_%d", i * 100);
		if (try tree.get(key)) found++;
	}
	assert(found == 1000, "find must locate all keys");
	return found;
}


fn sz count_nodes(yaml::Node n)
{
	if (!n.exists()) return 0;
	sz n_count = 1;
	if (n.is_map())
	{
		foreach (e : n.entries())
		{
			n_count += count_nodes(e.value);
		}
	}
	else if (n.is_seq())
	{
		foreach (x : n.items())
		{
			n_count += count_nodes(x);
		}
	}
	return n_count;
}

// New foreach: iterate all collection elements recursively
fn sz run_foreach(yaml::Yaml tree)
{
	sz n = 0;
	if (!tree.tree) return 0;
	uint child = tree.tree.nodes[0].first;
	while (child != 0)
	{
		yaml::Node doc = (yaml::Node){ tree.tree, child };
		n += count_nodes(doc);
		child = tree.tree.nodes[child].next;
	}
	return n;
}

// ---- measuring ----

fn double ms_since(Clock t) => (double)t.to_now() / 1.0e6;

// Peak resident set size (VmHWM) in KiB, -1 where /proc is not available.
fn double rss_kb() => @pool()
{
	$if env::LINUX:
		File? f = io::file::open("/proc/self/status", "r");
		if (catch f) return -1;
		defer (void)f.close();
		ByteWriter w;
		if (catch io::copy_to(&f, w.tinit())) return -1;
		foreach (line : ((String)w.str_view()).tsplit("\n"))
		{
			if (!line.starts_with("VmHWM:")) continue;
			String? kb = line[6..].trim().tsplit(" ")[0];
			return (double)kb.to_long()!!;
		}
	$endif
	return -1;
}

fn void fmt_kb(double kb, DString* out)
{
	if (kb < 0)
	{
		out.append("n/a");
		return;
	}
	out.appendf("%.0f", kb);
}

fn int main(String[] args)
{
	if (args.len < 3)
	{
		io::eprintn("usage: bench <mode> <file> [iterations]");
		return 2;
	}
	String mode = args[1];
	String path = args[2];
	int iters = args.len > 3 ? (int)args[3].to_int()!! : 5;
	char[]? raw = io::file::load(mem, path);
	if (catch raw)
	{
		io::eprintfn("cannot read %s", path);
		return 1;
	}
	String input = (String)raw;
	bool expect_reject = path.contains("257") || path.contains("2041");
	double rss_base = rss_kb();

	yaml::Yaml new_tree;
	bool has_new_tree = false;

	if (mode == "decode" || mode == "json" || mode == "find" || mode == "foreach")
	{
		yaml::Yaml? t = load_tree(input);
		if (catch t)
		{
			io::eprintfn("%s: does not parse", path);
			return 1;
		}
		new_tree = t;
		has_new_tree = true;
	}

	defer
	{
		if (has_new_tree) new_tree.free();
	}

	// Buffer for in-place modes (re-copied before each run outside the clock)
	char[] buf = {};
	bool needs_buf = (mode == "from_buffer" || mode == "events");
	if (needs_buf)
	{
		buf = alloc::alloc_array(mem, char, input.len);
	}
	defer
	{
		if (needs_buf) alloc::free(mem, buf.ptr);
	}

	// Timed runs, plain allocator, the free is outside the clock (unless measuring free)
	DynamicArenaAllocator arena;
	arena.init(mem, 1024 * 1024);
	defer arena.free();
	double[] times = mem::new_array(double, iters);

	for (int i = 0; i < iters; i++)
	{
		if (needs_buf)
		{
			mem::copy(buf.ptr, input.ptr, input.len);
		}

		Clock t;
		if (mode == "free")
		{
			yaml::Yaml d = yaml::from_string(input, mem, false)!!;
			t = clock::now();
			d.free();
		}
		else
		{
			t = clock::now();
			switch (mode)
			{
				case "tree": run_tree(input, mem, expect_reject);
				case "from_buffer": run_from_buffer(buf, mem, expect_reject);
				case "events": run_events(buf, expect_reject);
				case "decode": run_decode(new_tree, &arena);
				case "json": run_json(new_tree);
				case "find": run_find(new_tree);
				case "foreach": run_foreach(new_tree);
				default:
					io::eprintfn("unknown mode %s", mode);
					return 2;
			}
		}
		times[i] = ms_since(t);
		arena.reset();
	}
	double rss_peak = rss_kb();

	// Allocation counts through TrackingAllocator
	TrackingAllocator tracker;
	Allocator inner = mem;
	if (mode == "decode") inner = &arena;
	tracker.init(inner);
	sz result = 0;

	if (needs_buf)
	{
		mem::copy(buf.ptr, input.ptr, input.len);
	}

	switch (mode)
	{
		case "tree": result = run_tree(input, &tracker, expect_reject);
		case "from_buffer": result = run_from_buffer(buf, &tracker, expect_reject);
		case "events": result = run_events(buf, expect_reject);
		case "decode": result = run_decode(new_tree, &tracker);
		case "json": result = run_json(new_tree);
		case "find": result = run_find(new_tree);
		case "foreach": result = run_foreach(new_tree);
		case "free":
			yaml::Yaml d = yaml::from_string(input, &tracker, false)!!;
			d.free();
	}

	sz allocs = tracker.total_allocation_count();
	sz bytes = tracker.total_allocated();
	sz peak = tracker.max_allocated();
	tracker.free();
	arena.reset();

	if (result < 0)
	{
		io::eprintfn("%s: the %s run failed", path, mode);
		return 1;
	}

	quicksort(times);
	double min = times[0];
	double median = times[iters / 2];
	double mbps = (min > 0.0001) ? ((double)input.len / (1024.0 * 1024.0) / (min / 1000.0)) : 0.0;

	DString rss;
	DString base;
	fmt_kb(rss_peak, &rss);
	fmt_kb(rss_base, &base);
	// mode,file,bytes,iters,min_ms,median_ms,mb_per_s,allocs,alloc_bytes,peak_live_bytes,rss_base_kb,rss_peak_kb
	io::printfn("%s,%s,%d,%d,%.2f,%.2f,%.1f,%d,%d,%d,%s,%s", mode, path, input.len, iters, min, median, mbps,
		allocs, bytes, peak, base.str_view(), rss.str_view());
	return 0;
}
