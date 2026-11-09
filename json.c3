// v2 contract. Card (c) owns this file: compact JSON (the writers of the old yaml.c3, moved).
// Source order, shadowed entries skipped, collection keys as compact JSON text (counted against
// MAX_KEY_TEXT + KEY_TEXT_PER_BYTE * input: LIMIT_EXCEEDED), floats as before.
module yaml;

import std::io;
import yaml::parser;

struct KeyWriter @private
{
	DString ds;
	sz* budget;
	sz max_budget;
}

fn void? append_key_char(void* data, char c) @private
{
	KeyWriter* kw = (KeyWriter*)data;
	(*kw.budget)++;
	if (*kw.budget > kw.max_budget) return parser::LIMIT_EXCEEDED~;
	kw.ds.append_char(c);
}

fn sz? write_node_json(Formatter* f, Node n)
{
	sz key_budget = 0;
	sz max_budget = parser::MAX_KEY_TEXT + (n.tree ? parser::KEY_TEXT_PER_BYTE * n.tree.input.len : 0);
	return write_node_json_budget(f, n, &key_budget, max_budget);
}

fn sz? write_yaml_json(Formatter* f, Yaml* y)
{
	sz n = 0;
	if (!y.tree) return 0;
	sz key_budget = y.tree.budget.key_text;
	sz max_budget = parser::MAX_KEY_TEXT + (y.tree.input.len ? parser::KEY_TEXT_PER_BYTE * y.tree.input.len : 0);
	uint child = y.tree.nodes[0].first;
	while (child != 0)
	{
		Node doc = (Node){ y.tree, child };
		n += write_node_json_budget(f, doc, &key_budget, max_budget)! + f.print("\n")!;
		child = y.tree.nodes[child].next;
	}
	return n;
}

struct KeyTextCounter @private
{
	sz* budget;
	sz max_budget;
}

fn void? key_counter_char(void* data, char c) @private
{
	KeyTextCounter* kc = (KeyTextCounter*)data;
	(*kc.budget)++;
	if (*kc.budget > kc.max_budget) return parser::LIMIT_EXCEEDED~;
}

fn void? measure_key_json(Tree* tree, uint key_node_id, sz max_budget)
{
	KeyTextCounter kc = { .budget = &tree.budget.key_text, .max_budget = max_budget };
	Formatter f;
	f.init(&key_counter_char, &kc);
	Node n = (Node){ tree, key_node_id };
	write_node_json_budget(&f, n, &tree.budget.key_text, max_budget)!;
}

fn void? stream_write_char(void* data, char c) @private
{
	OutStream* stream = (OutStream*)data;
	return (*stream).write_byte(c);
}

fn sz? Yaml.write_json(&self, OutStream out)
{
	Formatter f;
	f.init(&stream_write_char, &out);
	return write_yaml_json(&f, self);
}

fn String? Yaml.to_json(&self, Allocator allocator = mem)
{
	ByteWriter bw;
	bw.init(allocator);
	defer catch (void)bw.destroy();
	self.write_json(&bw)!;
	return bw.str_view();
}

fn sz? write_node_json_budget(Formatter* f, Node n, sz* key_budget, sz max_budget) @private
{
	Kind k = n.kind();
	switch (k)
	{
		case MISSING:
		case NULL:
			return f.print("null");
		case BOOL:
			return f.print(n.as_bool()! ? "true" : "false");
		case INT:
			return f.printf("%d", n.as_int128()!);
		case FLOAT:
			return write_float(f, n.as_float()!);
		case STRING:
			return write_string(f, n.text());
		case SEQUENCE:
			sz total = f.print("[")!;
			bool first = true;
			foreach (item : n.items())
			{
				if (!first) total += f.print(",")!;
				first = false;
				total += write_node_json_budget(f, item, key_budget, max_budget)!;
			}
			return total + f.print("]")!;
		case MAPPING:
			sz total = f.print("{")!;
			bool first = true;
			foreach (e : n.entries())
			{
				if (!first) total += f.print(",")!;
				first = false;

				if (e.key_node.exists() && (e.key_node.is_seq() || e.key_node.is_map()))
				{
					KeyWriter kw = { .ds = dstring::new(mem), .budget = key_budget, .max_budget = max_budget };
					defer kw.ds.free();
					Formatter kf;
					kf.init(&append_key_char, &kw);
					write_node_json_budget(&kf, e.key_node, key_budget, max_budget)!;
					total += write_string(f, kw.ds.str_view())! + f.print(":")!;
				}
				else
				{
					total += write_string(f, e.key)! + f.print(":")!;
				}
				total += write_node_json_budget(f, e.value, key_budget, max_budget)!;
			}
			return total + f.print("}")!;
	}
}

fn sz? write_float(Formatter* f, double d) @private
{
	if (d != d || d == double::inf || d == -double::inf) return f.print("null");
	String s;
	foreach (format : (String[]){ "%.15g", "%.16g", "%.17g" })
	{
		s = string::tformat(format, d);
		double? back = s.to_double();
		if (try back && back == d) break;
	}
	if (s.contains_char('.') || s.contains_char('e')) return f.print(s);
	return f.print(s)! + f.print(".0")!;
}

fn sz? write_string(Formatter* f, String s) @private
{
	sz n = f.print("\"")!;
	foreach (c : s)
	{
		switch (c)
		{
			case '"': n += f.print(`\"`)!;
			case '\\': n += f.print(`\\`)!;
			case '\n': n += f.print(`\n`)!;
			case '\t': n += f.print(`\t`)!;
			case '\r': n += f.print(`\r`)!;
			case '\b': n += f.print(`\b`)!;
			case '\f': n += f.print(`\f`)!;
			default: n += c < 0x20 ? f.printf("\\u%04x", c)! : f.print_char(c)!;
		}
	}
	return n + f.print("\"")!;
}
