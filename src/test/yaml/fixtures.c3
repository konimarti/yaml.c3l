// Shared fixtures for the v2 cards (a)-(e): hand-made trees, writable buffers, event listings.
module yaml::testing;

import yaml, yaml::parser;

// Two documents:
//   name: x            port: 8080     ratio: 1.5     on: true     none: ~
//   list: [1, two]     nested: {a: {b: c}}           dup: 1       dup: 2 (the first is shadowed)
//   (null key): v      copy: *name (scalar alias)     again: *list (collection alias)
//   --- second
const String SAMPLE_JSON =
	`{"name":"x","port":8080,"ratio":1.5,"on":true,"none":null,"list":[1,"two"],"nested":{"a":{"b":"c"}},"dup":2,"":"v","copy":"x","again":[1,"two"]}` "\n"
	`"second"` "\n";

fn Yaml sample()
{
	Tree* t = yaml::new_tree(mem);
	uint root = t.add_collection(0, "", MAP);
	uint name = t.add_scalar(root, "name", "x");
	t.props_of(name).anchor = t.put("name");
	t.add_scalar(root, "port", "8080", INT);
	t.add_scalar(root, "ratio", "1.5", FLOAT);
	t.add_scalar(root, "on", "true", BOOL);
	t.add_scalar(root, "none", "~", NULL);
	uint list = t.add_collection(root, "list", SEQ);
	t.props_of(list).anchor = t.put("list");
	t.add_scalar(list, "", "1", INT);
	t.add_scalar(list, "", "two");
	uint nested = t.add_collection(root, "nested", MAP);
	uint a = t.add_collection(nested, "a", MAP);
	t.add_scalar(a, "b", "c");
	uint dup1 = t.add_scalar(root, "dup", "1", INT);
	t.add_scalar(root, "dup", "2", INT);
	t.shadow(dup1);
	t.add_scalar(root, "", "v");   // the null key: the empty span
	// aliases: a scalar alias copies the target's text, style and schema; a collection alias points at it
	uint copy = t.add_scalar(root, "copy", "x");
	t.nodes[copy].val = t.nodes[name].val;
	t.nodes[copy].flags |= yaml::F_ALIAS;
	uint again = t.add_collection(root, "again", SEQ);
	t.nodes[again].flags |= yaml::F_ALIAS;
	t.nodes[again].first = list;
	t.nodes[again].val.len = t.nodes[list].val.len;
	t.add_scalar(0, "", "second");
	return { t };
}

// A writable copy of `s` (a String literal must never be passed to an in-place API).
fn char[] writable(String s) => (char[])s.tcopy();

// The events of `input` parsed in place, one test.event line each, joined by `sep`.
fn String? events(String input, String sep = "\n")
{
	DString out = dstring::temp();
	Parser p;
	p.init_inplace(writable(input), false, mem);
	defer p.free();
	while (true)
	{
		Event e = p.next()!;
		if (out.len()) out.append(sep);
		out.appendf("%s", p.view(e));
		if (e.type == STREAM_END) return out.str_view();
	}
}
