// Tests for parser limits (M2, M3).
// MAX_DEPTH = 256 for collections and block indents; 257 => LIMIT_EXCEEDED.
// MAX_TAG_DIRECTIVES = 16; 17th => LIMIT_EXCEEDED.
module yaml2::parser_test;

import std::io;
import yaml2::parser;
import yaml2::testing;

fn void depth_256_and_257_flow() @test => @pool()
{
	// Flow nesting 256: passes
	DString s256 = dstring::temp();
	s256.append_repeat('[', parser::MAX_DEPTH);
	s256.append("a");
	s256.append_repeat(']', parser::MAX_DEPTH);
	(void)parse_events(s256.str_view())!!;

	// Flow nesting 257: fails LIMIT_EXCEEDED
	DString s257 = dstring::temp();
	s257.append_repeat('[', parser::MAX_DEPTH + 1);
	s257.append("a");
	s257.append_repeat(']', parser::MAX_DEPTH + 1);
	test::@error(parse_events(s257.str_view()), parser::LIMIT_EXCEEDED);
}

fn void depth_256_and_257_block_indents() @test => @pool()
{
	// Block indents 256: passes
	DString s256 = dstring::temp();
	for (int i = 0; i < parser::MAX_DEPTH; i++)
	{
		s256.append_repeat(' ', (sz)(i * 2));
		s256.append("a:\n");
	}
	s256.append_repeat(' ', (sz)(parser::MAX_DEPTH * 2));
	s256.append("1\n");
	(void)parse_events(s256.str_view())!!;

	// Block indents 257: fails LIMIT_EXCEEDED
	DString s257 = dstring::temp();
	for (int i = 0; i < parser::MAX_DEPTH + 1; i++)
	{
		s257.append_repeat(' ', (sz)(i * 2));
		s257.append("a:\n");
	}
	s257.append_repeat(' ', (sz)((parser::MAX_DEPTH + 1) * 2));
	s257.append("1\n");
	test::@error(parse_events(s257.str_view()), parser::LIMIT_EXCEEDED);
}

fn void depth_256_and_257_indentless_sequence() @test => @pool()
{
	DString s257 = dstring::temp();
	for (int i = 0; i < parser::MAX_DEPTH + 1; i++)
	{
		s257.append_repeat(' ', (sz)(i * 2));
		s257.append("k:\n");
		s257.append_repeat(' ', (sz)(i * 2));
		s257.append("-\n");
	}
	s257.append_repeat(' ', (sz)((parser::MAX_DEPTH + 1) * 2));
	s257.append("1\n");
	test::@error(parse_events(s257.str_view()), parser::LIMIT_EXCEEDED);
}

fn void tag_directives_limit() @test => @pool()
{
	// 16 %TAG directives: passes
	DString s16 = dstring::temp();
	for (int i = 0; i < parser::MAX_TAG_DIRECTIVES; i++)
	{
		s16.appendf("%%TAG !t%d! tag:example.com,2000:t%d/\n", i, i);
	}
	s16.append("---\n!t0!foo\n");
	(void)parse_events(s16.str_view())!!;

	// 17 %TAG directives: fails LIMIT_EXCEEDED
	DString s17 = dstring::temp();
	for (int i = 0; i < parser::MAX_TAG_DIRECTIVES + 1; i++)
	{
		s17.appendf("%%TAG !t%d! tag:example.com,2000:t%d/\n", i, i);
	}
	s17.append("---\n!t0!foo\n");
	test::@error(parse_events(s17.str_view()), parser::LIMIT_EXCEEDED);
}
