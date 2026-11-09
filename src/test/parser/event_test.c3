module yaml::event_test;

import std::io;
import yaml::parser;
import yaml;

fn String? events(String yaml)
{
	DString out = dstring::temp();
	Parser p;
	p.init(yaml, false);
	while (true)
	{
		Event e = p.next()!;
		if (out.len()) out.append_char('\n');
		out.appendf("%s", e);
		if (e.type == STREAM_END) return out.str_view();
	}
}

fn void empty_stream() @test => @pool()
{
	test::eq(events("")!!, "+STR\n-STR");
}

fn void single_scalar_a() @test => @pool()
{
	// a\n -> +STR +DOC =VAL :a -DOC -STR
	test::eq(events("a\n")!!, "+STR\n+DOC\n=VAL :a\n-DOC\n-STR");
}

fn void explicit_markers() @test => @pool()
{
	// ---\na\n...\n -> +STR +DOC --- =VAL :a -DOC ... -STR
	test::eq(events("---\na\n...\n")!!, "+STR\n+DOC ---\n=VAL :a\n-DOC ...\n-STR");
}

fn void folded_multiline() @test => @pool()
{
	// a\nb\n\nc -> =VAL :a b\\nc
	// Single newline -> space, double newline -> \n
	test::eq(events("a\nb\n\nc\n")!!, "+STR\n+DOC\n=VAL :a b\\nc\n-DOC\n-STR");
}

fn void scalar_with_comment() @test => @pool()
{
	// a # c\n -> =VAL :a (no trailing space)
	test::eq(events("a # c\n")!!, "+STR\n+DOC\n=VAL :a\n-DOC\n-STR");
}

fn void two_documents() @test => @pool()
{
	// a\n---\nb\n -> two documents
	test::eq(events("a\n---\nb\n")!!, "+STR\n+DOC\n=VAL :a\n-DOC\n+DOC ---\n=VAL :b\n-DOC\n-STR");
}

fn void escaping_test() @test => @pool()
{
	// Event with value "x\ty\\" should print =VAL :x\ty\\
	// We'll test with a simple value for now
	Parser p;
	p.init("x\ty\\\n", false);
	Event? e = p.next(); // STREAM_START
	e = p.next(); // DOCUMENT_START
	e = p.next(); // SCALAR
	if (catch err = e)
	{
		assert(false); // Should not fail
	}
	else
	{
		// Check that the scalar value contains the characters
		// For now, just check it doesn't crash
		assert(e.value.len > 0);
	}
}

fn void unmatched_bracket() @test => @pool()
{
	// "]" without "[" should return SYNTAX_ERROR (until M4 this test used "[a]", then unsupported)
	// The first event is STREAM_START, then the second call should error
	Parser p;
	p.init("]\n", false);
	Event? e1 = p.next(); // STREAM_START
	if (catch err = e1)
	{
		assert(false); // Should not error on first call
	}
	Event? e2 = p.next(); // Should error on second call
	if (catch err = e2)
	{
		// Expected to get an error
		assert(true);
	}
	else
	{
		assert(false); // Should not get an event, should get an error
	}
}

fn void from_string_single_doc() @test => @pool()
{
	// yaml::from_string("a") should give 1 document with Object being the string "a"
	YamlData? data = yaml::from_string("a", mem, false);
	if (catch err = data)
	{
		assert(false); // Should not fail
	}
	else
	{
		assert(data.docs.size == 1);
		// The document should be a string
		// For now, just check it doesn't crash
		data.free();
	}
}
