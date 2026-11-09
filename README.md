yaml.c3l — YAML 1.2.2 Parser for C3

A minimal YAML 1.2.2 parser for the C3 language, designed to produce exact
yaml-test-suite event streams.

Status: M1 (plain scalars, comments, markers) — in progress

Build
-----

    c3c build yamlv

CLI (build/yamlv)
-------------------

    -e             output event stream
    -j             output JSON (M6)
    -h             help
    (no flag)      validate only

    printf 'a\n' | build/yamlv -e
    +STR
    +DOC
    =VAL :a
    -DOC
    -STR

Test
----

    c3c test              # unit tests
    ./test/run-suite.sh   # yaml-test-suite

Files
-----

    yaml.c3           public API, fault propagation
    event.c3          Event struct + Printable
    scanner.c3        tokeniser (module yaml::parser)
    parser.c3         state machine on scanner
    builder.c3        events → Object tree
    src/yamlv/main.c3  CLI
    src/test/parser/event_test.c3  unit tests
    test/run-suite.sh  yaml-test-suite runner

See DESIGN.md for language restrictions and implementation notes.
