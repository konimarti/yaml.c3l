// In-place scalar writer for zero-allocation parsing (M2).
// Maintains write cursor w <= read cursor r (limit) in the buffer.
// Spills to Arena on growth overflow (\L, \P) when a spill allocator is present.
// Blanks leftover [w, orig_end) with spaces upon completion (M7).
module yaml::parser;

import std::io;

struct InPlaceWriter
{
	char[] buf;
	uint orig_start;
	uint w;
	Arena* arena;
	Allocator spill;
	bool spilled;
	uint arena_start;
}

fn void InPlaceWriter.init(&self, char[] buf, uint orig_start, Arena* arena, Allocator spill)
{
	*self = {
		.buf = buf,
		.orig_start = orig_start,
		.w = orig_start,
		.arena = arena,
		.spill = spill,
	};
}

fn void? InPlaceWriter.start_spill(&self, uint needed)
{
	if (!self.spill || !self.arena) return NO_SPACE~;
	self.spilled = true;
	self.arena_start = self.arena.len;
	uint prefix_len = self.w - self.orig_start;
	self.arena.ensure_cap(prefix_len + needed)!;
	if (prefix_len > 0)
	{
		self.arena.append_bytes(self.buf.ptr + self.orig_start, prefix_len);
	}
}

fn void? InPlaceWriter.append_char(&self, char c, uint limit)
{
	if (self.spilled)
	{
		self.arena.ensure_cap(1)!;
		self.arena.append_char(c);
		return;
	}
	if (self.w + 1 <= limit)
	{
		self.buf[self.w++] = c;
		return;
	}
	self.start_spill(1)!;
	self.arena.append_char(c);
}

fn void? InPlaceWriter.append_slice(&self, char[] s, uint limit)
{
	if (!s.len) return;
	uint slen = (uint)s.len;
	if (self.spilled)
	{
		self.arena.ensure_cap(slen)!;
		self.arena.append_bytes(s.ptr, slen);
		return;
	}
	if (self.w + slen <= limit)
	{
		mem::move(self.buf.ptr + self.w, s.ptr, slen);
		self.w += slen;
		return;
	}
	self.start_spill(slen)!;
	self.arena.append_bytes(s.ptr, slen);
}

fn void? InPlaceWriter.append_char32(&self, Char32 c, uint limit)
{
	char[4] enc;
	sz len = conv::char32_to_utf8(c, &enc)!;
	uint ulen = (uint)len;
	if (self.spilled)
	{
		self.arena.ensure_cap(ulen)!;
		self.arena.append_bytes(&enc, ulen);
		return;
	}
	if (self.w + ulen <= limit)
	{
		mem::copy(self.buf.ptr + self.w, &enc, ulen);
		self.w += ulen;
		return;
	}
	self.start_spill(ulen)!;
	self.arena.append_bytes(&enc, ulen);
}

fn Span InPlaceWriter.finish(&self, uint orig_end)
{
	if (self.spilled)
	{
		// Blank the entire original region in buffer with spaces
		if (orig_end > self.orig_start)
		{
			mem::set(self.buf.ptr + self.orig_start, ' ', (sz)(orig_end - self.orig_start));
		}
		return { SPILL_BIT | self.arena_start, self.arena.len - self.arena_start };
	}
	// Blank leftover [w, orig_end) with spaces
	if (orig_end > self.w)
	{
		mem::set(self.buf.ptr + self.w, ' ', (sz)(orig_end - self.w));
	}
	return { self.orig_start, self.w - self.orig_start };
}

fn void? Arena.ensure_cap(&self, uint extra)
{
	if ((sz)self.len + extra > MAX_INPUT) return LIMIT_EXCEEDED~;
	uint need = self.len + extra;
	if (need > self.cap)
	{
		uint cap = self.cap ? self.cap : 256;
		while (cap < need) cap *= 2;
		self.ptr = alloc::realloc_array(self.allocator, self.ptr, char, cap).ptr;
		self.cap = cap;
	}
}

fn void Arena.append_bytes(&self, char* src, uint len)
{
	mem::copy(self.ptr + self.len, src, len);
	self.len += len;
}

fn void Arena.append_char(&self, char c)
{
	self.ptr[self.len++] = c;
}
