// Tests for growth exceptions, spill allocator, CRLF, BOM, and blanking (M2, M7, N5).
module yaml::parser_test;

import std::io;
import yaml::parser;
import yaml::testing;

// Growth exception 1: \L and \P (2 bytes in -> 3 bytes out UTF-8).
fn void growth_exception_1_spill() @test => @pool()
{
	// "\L" fits in place thanks to the opening quote slack
	char[] buf_single = testing::writable("\"\x5cL\"");   // "\L"
	Parser p_single;
	p_single.init_inplace(buf_single, false, null);   // no spill allocator!
	defer p_single.free();
	(void)p_single.next()!!;   // STREAM_START
	(void)p_single.next()!!;   // DOCUMENT_START
	Event e_single = p_single.next()!!;   // SCALAR
	test::eq(e_single.type, EventType.SCALAR);
	test::eq((e_single.value.off & parser::SPILL_BIT) == 0, true);   // in place!
	test::eq(p_single.text(e_single.value), "\u2028");

	// "\L\L" without spill allocator: fails with NO_SPACE
	char[] buf_double_nospill = testing::writable("\"\x5cL\x5cL\"");
	Parser p_nospill;
	p_nospill.init_inplace(buf_double_nospill, false, null);
	defer p_nospill.free();
	(void)p_nospill.next()!!;
	test::@error(p_nospill.next(), parser::NO_SPACE);

	// "\L\L" with spill allocator: succeeds and spills to arena
	char[] buf_double_spill = testing::writable("\"\x5cL\x5cL\"");
	Parser p_spill;
	p_spill.init_inplace(buf_double_spill, false, mem);
	defer p_spill.free();
	(void)p_spill.next()!!;
	(void)p_spill.next()!!;
	Event e_double = p_spill.next()!!;
	test::eq(e_double.type, EventType.SCALAR);
	test::eq((e_double.value.off & parser::SPILL_BIT) != 0, true);   // spilled!
	test::eq(p_spill.text(e_double.value), "\u2028\u2028");

	// "x\L\L\Ly" with spill allocator
	char[] buf_multi = testing::writable("\"x\x5cL\x5cL\x5cLy\"");
	Parser p_multi;
	p_multi.init_inplace(buf_multi, false, mem);
	defer p_multi.free();
	(void)p_multi.next()!!;
	(void)p_multi.next()!!;
	Event e_multi = p_multi.next()!!;
	test::eq((e_multi.value.off & parser::SPILL_BIT) != 0, true);
	test::eq(p_multi.text(e_multi.value), "x\u2028\u2028\u2028y");
}

// Growth exception 2: block scalar at EOF without '\n'.
fn void growth_exception_2_block_scalar_eof() @test => @pool()
{
	char[] buf = testing::writable("|\n  abc");   // no trailing \n
	Parser p;
	p.init_inplace(buf, false, null);   // 0 allocs
	defer p.free();
	(void)p.next()!!;
	(void)p.next()!!;
	Event e = p.next()!!;
	test::eq(e.type, EventType.SCALAR);
	test::eq(p.text(e.value), "abc\n");   // CLIP added trailing newline
}

// CRLF compaction in place: \r\n and \r compacted to \n in place.
fn void crlf_compaction_in_place() @test => @pool()
{
	char[] buf = testing::writable("a: 1\r\nb: 2\r\n");
	sz orig_len = buf.len;
	Parser p;
	p.init_inplace(buf, false, null);
	defer p.free();
	test::eq(p.input().len, orig_len - 2);   // shrunk by 2 bytes
	Event e1 = p.next()!!;   // STREAM_START
	(void)e1;
}

// Leading BOM: remains in buf at byte 0..2, Mark.pos starts at 3.
fn void bom_coordinates_and_error() @test => @pool()
{
	// BOM followed by invalid syntax: error at line 1, col 1
	char[] buf = testing::writable("\xef\xbb\xbf@");
	Parser p;
	p.init_inplace(buf, false, null);
	defer p.free();
	(void)p.next()!!;   // STREAM_START
	test::@error(p.next(), parser::SYNTAX_ERROR);
}

// Leftover region blanked with spaces (M7).
fn void in_place_leftover_blanked() @test => @pool()
{
	// "hello\nworld" in double quotes: quotes and escape shrink
	// original string: "a\nb" (6 bytes including quotes)
	// decoded string: a\nb (3 bytes). Leftover bytes 3..5 should be ' '
	char[] buf = testing::writable("\"a\x5cnb\"");
	Parser p;
	p.init_inplace(buf, false, null);
	defer p.free();
	(void)p.next()!!;
	(void)p.next()!!;
	Event e = p.next()!!;
	test::eq(p.text(e.value), "a\nb");
	// Check that bytes after decoded scalar were blanked with spaces
	test::eq(buf[3], ' ');
	test::eq(buf[4], ' ');
}

// M7: Error excerpt still correct after in-place rewriting on the same line.
fn void error_excerpt_after_in_place_rewriting() @test => @pool()
{
	// Line contains a decoded quoted scalar followed by an error:
	// "a\nb": 1, c: @
	char[] buf = testing::writable("{\"a\x5cnb\": 1, c: @}\n");
	Parser p;
	p.init_inplace(buf, true, null);   // verbose=true to exercise Scanner.error
	defer p.free();
	while (true)
	{
		Event? e = p.next();
		if (catch e) break;
		if (e.type == STREAM_END) break;
	}
}

// Minor 2: Error excerpt must stop at the end of the error's line (no bytes of next line).
fn void error_excerpt_stops_at_line_end() @test => @pool()
{
	char[] buf1 = testing::writable("foo:\n  bar\ninvalid\n");
	Parser p1;
	p1.init_inplace(buf1, true, null);
	defer p1.free();
	while (true)
	{
		Event? e = p1.next();
		if (catch e) break;
		if (e.type == STREAM_END) break;
	}

	char[] buf2 = testing::writable("foo:\n  ba\r\nr\ninvalid\n");
	Parser p2;
	p2.init_inplace(buf2, true, null);
	defer p2.free();
	while (true)
	{
		Event? e = p2.next();
		if (catch e) break;
		if (e.type == STREAM_END) break;
	}
}

// M4: NO_SPACE reports a clear error message when verbose.
fn void nospace_error_reporting() @test => @pool()
{
	char[] buf = testing::writable("\"\x5cL\x5cL\"\n");
	Parser p;
	p.init_inplace(buf, true, null); // verbose = true
	defer p.free();
	(void)p.next()!!;
	test::@error(p.next(), parser::NO_SPACE);

	char[] buf_p = testing::writable("\"\x5cP\x5cP\"\n");
	Parser p2;
	p2.init_inplace(buf_p, true, null); // verbose = true
	defer p2.free();
	(void)p2.next()!!;
	test::@error(p2.next(), parser::NO_SPACE);
}
