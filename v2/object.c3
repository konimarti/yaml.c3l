// v2 contract. Card (c) owns this file; the only file that imports std::collections::object.
module yaml2;

import std::collections::object;

// The old builder's semantics: core schema, duplicates keep the last, the null key is "",
// a collection key is its compact JSON text (MAX_KEY_TEXT budget). Free with Object.free.
fn Object*? Node.to_object(self, Allocator allocator = mem) => unreachable("card (c)");
