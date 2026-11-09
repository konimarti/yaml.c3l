module yamlv;

import std::io;
import yaml;
import yaml::parser;

const String USAGE = "yamlv: YAML parser\n\nUsage: yamlv [OPTIONS]\n\nOptions:\n  -e  Output event stream\n  -j  Output as JSON\n  -h  Show this help\n";

fn int main(String[] args)
{
	bool events = false;
	bool json = false;
	
	foreach (arg : args[1..])
	{
		switch (arg)
		{
			case "-h": io::printn(USAGE); return 0;
			case "-e": events = true; break;
			case "-j": json = true; break;
			default: io::eprintfn("unknown option: %s", arg); return 1;
		}
	}
	
	@pool()
	{
		ByteWriter writer;
		if (catch err = io::copy_to(io::stdin(), writer.tinit()))
		{
			io::eprintfn("cannot read stdin: %s", err);
			return 1;
		}
		String input = writer.str_view();
		
		if (events)
		{
			Parser p;
			p.init(input);
			while (true)
			{
				Event? e = p.next();
				if (catch err = e)
				{
					return 1;
				}
				io::printn(e);
				if (e.type == STREAM_END) return 0;
			}
		}
		
		if (json)
		{
			YamlData? data = yaml::from_string(input, mem, false);
			if (catch err = data)
			{
				io::eprintfn("Invalid YAML: %s", err);
				return 1;
			}
			io::printn(data);
			data.free();
			return 0;
		}
		
		// Default: validate
		YamlData? data = yaml::from_string(input, mem, true);
		if (catch err = data)
		{
			return 1;
		}
		io::eprintn("\n  YAML is valid.");
		data.free();
		return 0;
	};
}
