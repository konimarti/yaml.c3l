module yamlv;

import std::io, std::os;
import yaml;
import yaml::parser;
import yaml2::parser;

const String USAGE = "yamlv: YAML parser\n\nUsage: yamlv [OPTIONS]\n\nOptions:\n  -e  Output event stream\n  -j  Output as JSON\n  -h  Show this help\n";

// -e: print the events (also those before an error), -j: print JSON, none: validate.
// Errors are printed with their position by the parser; the exit code is 1 on error.
fn int main(String[] args)
{
	bool events;
	bool json;
	foreach (arg : args[1..])
	{
		switch (arg)
		{
			case "-h": io::printn(USAGE); return 0;
			case "-e": events = true;
			case "-j": json = true;
			default: io::eprintfn("unknown option: %s", arg); return 1;
		}
	}
	$if env::WIN32:
		os::win32::_setmode(0, 0x8000);   // _O_BINARY: no CRLF translation, no end of input at ^Z
		os::win32::_setmode(1, 0x8000);
	$endif
	@pool()
	{
		ByteWriter writer;
		writer.init(mem);
		defer (void)writer.destroy();
		if (catch err = io::copy_to(io::stdin(), &writer))
		{
			io::eprintfn("cannot read stdin: %s", err);
			return 1;
		}
		char[] input_bytes = writer.array_view();
		String input = writer.str_view();
		if (events)
		{
			yaml2::parser::Parser p;
			p.init_inplace(input_bytes, true);
			while (true)
			{
				yaml2::parser::Event? e = p.next();
				if (catch e) return 1;
				io::printn(p.view(e));
				if (e.type == STREAM_END) return 0;
			}
		}
		yaml::Yaml? data = yaml::from_string(input);
		if (catch data) return 1;
		defer data.free();
		if (json)
		{
			io::print(data);   // one JSON line per document
		}
		else
		{
			io::eprintn("\n  YAML is valid.");
		}
		return 0;
	};
}
