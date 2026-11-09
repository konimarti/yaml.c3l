// v2 contract. Card (c) owns this file: compact JSON (the writers of the old yaml.c3, moved).
// Source order, shadowed entries skipped, collection keys as compact JSON text (counted against
// MAX_KEY_TEXT + KEY_TEXT_PER_BYTE * input: LIMIT_EXCEEDED), floats as before.
module yaml2;

import std::io;

fn sz? write_node_json(Formatter* f, Node n) => unreachable("card (c)");
fn sz? write_yaml_json(Formatter* f, Yaml* y) => unreachable("card (c)");   // one document per line
