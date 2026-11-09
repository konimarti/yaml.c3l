// Benchmark: parse a file N times with the tree API, the event API and decode{T}.
// usage: bench <tree|events|decode> <file> [iterations]
// Prints one CSV line (see bench/README.md); bench/run.sh runs it once per file and mode.
module bench;

import std::io, std::time, std::sort, std::collections::list;
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

// ---- the library API: one function per mode, the only code to port ----

// The tree: parse, return the number of documents, free.
fn sz run_tree(String input, Allocator a)
{
	Yaml? data = yaml::from_string(input, a, false);
	if (catch data) return -1;
	defer data.free();
	return data.len();
}

// The events only: no tree. Returns the number of events, -1 on an error.
fn sz run_events(String input) => @pool()
{
	Parser p;
	p.init(input, false);
	sz n;
	while (true)
	{
		Event? e = p.next();
		if (catch e) return -1;
		n++;
		if (e.type == STREAM_END) return n;
	}
}

// The tree of the input, built once, outside the measurement.
fn Yaml? load_tree(String input) => yaml::from_string(input, mem, false);

// decode{Config} of an already built tree; everything it allocates comes from `a`.
fn sz run_decode(Yaml tree, Allocator a)
{
	Config? c = yaml::decode{Config}(tree, a, false);
	if (catch c) return -1;
	return c.servers.len;
}

// ---- measuring ----

struct Sample
{
	double ms;
	sz result;
}

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
		io::eprintn("usage: bench <tree|events|decode> <file> [iterations]");
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
	double rss_base = rss_kb();   // the process with the input loaded, before any parse

	Yaml tree;
	if (mode == "decode")
	{
		Yaml? t = load_tree(input);
		if (catch t)
		{
			io::eprintfn("%s: does not parse", path);
			return 1;
		}
		tree = t;
	}
	else if (mode != "tree" && mode != "events")
	{
		io::eprintfn("unknown mode %s", mode);
		return 2;
	}

	// Timed runs, plain allocator, the free is outside the clock. (decode: a throw-away arena.)
	DynamicArenaAllocator arena;
	arena.init(mem, 1024 * 1024);
	double[] times = mem::new_array(double, iters);
	for (int i = 0; i < iters; i++)
	{
		Clock t = clock::now();
		switch (mode)
		{
			case "tree": run_tree(input, mem);
			case "events": run_events(input);
			default: run_decode(tree, &arena);
		}
		times[i] = ms_since(t);
		arena.reset();
	}
	double rss_peak = rss_kb();   // before the tracked run below, whose bookkeeping is large

	// Allocation counts, after the RSS is read (the tracker's own map is large): one run through a TrackingAllocator (it is slow, so not the timed runs).
	// Only the library allocator is counted; the temporary allocator (tmem, used by the scanner
	// and parser for their working memory) is not, but it is part of the peak RSS.
	// tree: from_string + free; decode: decode{Config} into a throw-away arena.
	TrackingAllocator tracker;
	Allocator inner = mem;
	if (mode == "decode") inner = &arena;
	tracker.init(inner);
	sz result;
	switch (mode)
	{
		case "tree": result = run_tree(input, &tracker);
		case "events": result = run_events(input);
		default: result = run_decode(tree, &tracker);
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
	double mbps = (double)input.len / (1024.0 * 1024.0) / (min / 1000.0);

	DString rss;
	DString base;
	fmt_kb(rss_peak, &rss);
	fmt_kb(rss_base, &base);
	// mode,file,bytes,iters,min_ms,median_ms,mb_per_s,allocs,alloc_bytes,peak_live_bytes,rss_base_kb,rss_peak_kb
	io::printfn("%s,%s,%d,%d,%.2f,%.2f,%.1f,%d,%d,%d,%s,%s", mode, path, input.len, iters, min, median, mbps,
		allocs, bytes, peak, base.str_view(), rss.str_view());
	return 0;
}
