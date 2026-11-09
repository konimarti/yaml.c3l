// v2 contract. Card (d) owns this file. Same rules, messages and ownership as the old decode.c3
// (README "Decoding into a struct"); integers go through Node.as_int128 / schema::int_of.
module yaml2;

import std::io;

// A method cannot be generic (verified on 0.8.6), so: a free generic function and a macro method.
//   Config c = yaml2::decode{Config}(data)!!;      Config c = node.decode(Config)!!;
fn Type? decode_node(Node n, Allocator allocator = mem, bool verbose = true) <Type> => unreachable("card (d)");
macro Node.decode(self, $Type, Allocator allocator = mem, bool verbose = true) => decode_node{$Type}(self, allocator, verbose);

fn Type? decode_in(Yaml yaml, sz doc, Allocator allocator = mem, bool verbose = true) <Type> => unreachable("card (d)");
fn Type? decode(Yaml yaml, Allocator allocator = mem, bool verbose = true) <Type> => decode_in{Type}(yaml, 0, allocator, verbose);

// Zero string allocations: the Strings of the result are views into the tree (valid while the
// Yaml lives). Slices of the result are still allocated with `allocator`.
fn Type? decode_borrowed(Node n, Allocator allocator = mem, bool verbose = true) <Type> => unreachable("card (d)");
