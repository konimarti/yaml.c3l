module yaml;

import std::io;
import std::collections::object @public;
import std::collections::list;

import yaml::parser;

faultdef INVALID_INPUT_FORMAT, UNDEFINED_ALIAS;

struct YamlData (Printable)
{
	List {Object*} docs;
	Allocator allocator;
}

fn sz? YamlData.to_format(&self, Formatter* formatter) @dynamic
{
	sz n = 0;
	foreach (obj : self.docs)
	{
		if (obj != null)
		{
			n += obj.to_format(formatter)!;
		}
		else
		{
			n += formatter.printf("null")!;
		}
		n += formatter.printf("\n")!;
	}
	return n;
}

fn Object*? build_node(Parser* p, Event e, Allocator a)
{
	switch (e.type)
	{
		case SCALAR: return object::new_string(a, e.value);
		case SEQUENCE_START:
			Object* seq = object::new_array(a);
			defer catch seq.free();
			while (true)
			{
				Event n = p.next()!;
				if (n.type == SEQUENCE_END) return seq;
				seq.push_object(build_node(p, n, a)!);
			}
		case MAPPING_START:
			Object* map = object::new_obj(a);
			defer catch map.free();
			while (true)
			{
				Event key_ev = p.next()!;
				if (key_ev.type == MAPPING_END) return map;
				if (key_ev.type != SCALAR) return parser::SYNTAX_ERROR~;
				Event val_ev = p.next()!;
				if (val_ev.type == MAPPING_END)
				{
					map.set(key_ev.value, object::new_null());
					return map;
				}
				Object* val = build_node(p, val_ev, a)!;
				map.set(key_ev.value, val);
			}
		default: return parser::SYNTAX_ERROR~;
	}
}

fn YamlData? from_string(String s, Allocator allocator = mem, bool verbose = true) => @pool()
{
	Parser p;
	p.init(s, verbose);
	
	YamlData data;
	data.docs.init(allocator, 16);
	data.allocator = allocator;
	
	Object* current_doc = null;
	
	while (true)
	{
		Event? ev = p.next();
		if (catch err = ev)
		{
			defer catch data.free();
			return err~;
		}
		
		switch (ev.type)
		{
			case STREAM_START: break;
			case STREAM_END:
				if (current_doc != null) data.docs.push(current_doc);
				return data;
			case DOCUMENT_START:
				if (ev.explicit)
				{
					if (current_doc != null)
					{
						data.docs.push(current_doc);
						current_doc = null;
					}
				}
				break;
			case DOCUMENT_END:
				if (current_doc == null) current_doc = object::new_null();
				data.docs.push(current_doc);
				current_doc = null;
				break;
			case SCALAR:
			case SEQUENCE_START:
			case MAPPING_START:
				if (current_doc != null) current_doc.free();
				current_doc = build_node(&p, ev, allocator)!!;
				break;
			default: defer catch data.free(); return parser::SYNTAX_ERROR~;
		}
	}
}

fn YamlData? from_stream(InStream reader, Allocator allocator = mem, bool verbose = true) => @pool()
{
	ByteWriter writer;
	io::copy_to(reader, writer.tinit())!;
	String s = writer.str_view().copy(allocator);
	return from_string(s, allocator, verbose);
}

fn YamlData? from_file(String filename, Allocator allocator = mem, bool verbose = true)
{
	File f = io::file::open(filename, "r")!;
	defer (void)f.close();
	return from_stream(&f, allocator, verbose)!;
}

fn Object*? YamlData.get(&self, String path) @operator([])
{
	if (self.docs.size == 0) return NOT_FOUND~;
	return self.docs[0].get(path);
}

fn Object*? YamlData.get_in(&self, sz doc, String path)
{
	if (doc >= self.docs.size) return NOT_FOUND~;
	return self.docs[doc].get(path);
}

fn sz YamlData.len(&self) @operator(len)
{
	return self.docs.size;
}

fn void YamlData.free(&self)
{
	foreach (obj : self.docs) obj.free();
	self.docs.free();
}
