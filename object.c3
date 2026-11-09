// Conversion to std::collections::object::Object.
module yaml;

import std::io;
import std::collections::object;
import yaml::parser;

// The old builder's semantics: core schema, duplicates keep the last, the null key is "",
// a collection key is its compact JSON text (MAX_KEY_TEXT budget). Free with Object.free.
fn Object*? Node.to_object(self, Allocator allocator = mem)
{
	sz key_budget = 0;
	sz max_budget = parser::MAX_KEY_TEXT + (self.tree ? parser::KEY_TEXT_PER_BYTE * self.tree.input.len : 0);
	return to_object_budget(self, allocator, &key_budget, max_budget);
}

fn Object*? to_object_budget(Node self, Allocator allocator, sz* key_budget, sz max_budget) @private
{
	if (!self.exists()) return object::new_null();
	Kind k = self.kind();
	switch (k)
	{
		case MISSING:
		case NULL:
			return object::new_null();
		case BOOL:
			return object::new_bool(self.as_bool()!);
		case INT:
			return object::new_int(allocator, self.as_int128()!);
		case FLOAT:
			return object::new_float(allocator, self.as_float()!);
		case STRING:
			return object::new_string(allocator, self.text());
		case SEQUENCE:
			Object* arr = object::new_array(allocator);
			defer catch arr.free();
			foreach (item : self.items())
			{
				arr.push_object(to_object_budget(item, allocator, key_budget, max_budget)!);
			}
			return arr;
		case MAPPING:
			Object* obj = object::new_obj(allocator);
			defer catch obj.free();
			foreach (e : self.entries())
			{
				String ktext = e.key;
				if (e.key_node.exists() && (e.key_node.is_seq() || e.key_node.is_map()))
				{
					KeyWriter kw = { .ds = dstring::new(mem), .budget = key_budget, .max_budget = max_budget };
					defer kw.ds.free();
					Formatter kf;
					kf.init(&append_key_char, &kw);
					write_node_json_budget(&kf, e.key_node, key_budget, max_budget)!;
					ktext = kw.ds.str_view();
				}
				if (obj.has_key(ktext))
				{
					Object* old = obj.get(ktext)!!;
					old.free();
					obj.map.remove(ktext);
				}
				Object* val = to_object_budget(e.value, allocator, key_budget, max_budget)!;
				obj.set(ktext, val);
			}
			return obj;
	}
}
