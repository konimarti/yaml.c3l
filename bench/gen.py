#!/usr/bin/env python3
"""Generates the benchmark corpus into bench/data/ (reproducible: fixed seed, stdlib only).

usage: python3 bench/gen.py [target-megabytes]   (default 10)
"""
import json, os, random, sys

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "data")
SUITE = os.path.join(HERE, "..", "test-suite")
MB = 1 << 20
rnd = random.Random(12345)
WORDS = "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi omicron pi rho sigma tau".split()


def word():
    return rnd.choice(WORDS)


def scalar():
    k = rnd.randrange(8)
    if k == 0: return str(rnd.randrange(-10**6, 10**6))
    if k == 1: return "%.4f" % rnd.uniform(-1000, 1000)
    if k == 2: return rnd.choice(["true", "false", "null", "~"])
    if k == 3: return '"%s %s"' % (word(), word())
    if k == 4: return "'%s''s %s'" % (word(), word())
    return "%s-%s%d" % (word(), word(), rnd.randrange(1000))


def block(depth, ind, out):
    """A block mapping with nested maps and sequences."""
    pad = " " * ind
    for _ in range(rnd.randrange(3, 7)):
        key = "%s_%s" % (word(), word())
        c = rnd.randrange(10) if depth > 0 else 0
        if c < 5:
            out.append("%s%s: %s\n" % (pad, key, scalar()))
        elif c < 7:
            out.append("%s%s:\n" % (pad, key))
            block(depth - 1, ind + 2, out)
        elif c < 9:
            out.append("%s%s:\n" % (pad, key))
            for _ in range(rnd.randrange(2, 6)):
                if rnd.randrange(4) == 0:
                    out.append("%s- {id: %d, name: %s}\n" % (pad, rnd.randrange(10**4), word()))
                else:
                    out.append("%s- %s\n" % (pad, scalar()))
        else:
            out.append("%s%s: [%s, %s, %s]\n" % (pad, key, scalar(), scalar(), scalar()))


def config(size):
    out, n, i = [], 0, 0
    while n < size:
        chunk = ["# section %d\n" % i, "section_%d:\n" % i]
        block(4, 2, chunk)
        s = "".join(chunk)
        out.append(s)
        n += len(s)
        i += 1
    return "".join(out)


def servers(size):
    """A config that fits the Config struct of bench.c3 (the decode{T} benchmark)."""
    out, n, i = ["name: bench\nservers:\n"], 0, 0
    while n < size:
        s = "  - name: srv%d\n    host: %s.%s.example.org\n    port: %d\n    tls: %s\n    weight: %.2f\n    tags: [%s, %s, %s]\n" % (
            i, word(), word(), rnd.randrange(1, 65536), rnd.choice(["true", "false"]),
            rnd.uniform(0, 10), word(), word(), word())
        out.append(s)
        n += len(s)
        i += 1
    return "".join(out)


def small_docs(size):
    out, n = [], 0
    while n < size:
        s = "---\nid: %d\nname: %s\ntags: [%s, %s]\nowner:\n  user: %s\n  active: %s\n" % (
            rnd.randrange(10**6), word(), word(), word(), word(), rnd.choice(["true", "false"]))
        out.append(s)
        n += len(s)
    return "".join(out)


def esc_text(n):
    return " ".join(word() for _ in range(n))


def long_strings(size):
    out, n, i = [], 0, 0
    while n < size:
        k = i % 4
        if k == 0:    # double quoted, with escapes and a folded line break
            s = 'dq%d: "%s\\n\\t%s \\u00e9 \\x41 \\"q\\"\n  %s"\n' % (i, esc_text(40), esc_text(20), esc_text(40))
        elif k == 1:  # single quoted
            s = "sq%d: '%s it''s\n  %s'\n" % (i, esc_text(40), esc_text(40))
        elif k == 2:  # literal block
            s = "lit%d: |\n%s" % (i, "".join("  %s\n" % esc_text(12) for _ in range(20)))
        else:         # folded block, keep chomping
            s = "fold%d: >+\n%s\n" % (i, "".join("  %s\n" % esc_text(12) for _ in range(20)))
        out.append(s)
        n += len(s)
        i += 1
    return "".join(out)


def deep(size):
    """Many documents nested 200 levels deep (the limit is 256), block maps and flow."""
    out, n = [], 0
    while n < size:
        s = "".join("%sk%d:\n" % ("  " * d, d) for d in range(200)) + "  " * 200 + "leaf: 1\n"
        s += "---\n" + "[" * 200 + "x" + "]" * 200 + "\n---\n"
        s += "".join("%s- \n" % ("  " * d) for d in range(100)).replace("- \n", "-\n") + "  " * 100 + "- end\n---\n"
        out.append(s)
        n += len(s)
    return "".join(out)


def jsonish(size):
    def val(d):
        c = rnd.randrange(8) if d else rnd.randrange(5)
        if c == 0: return rnd.randrange(-10**6, 10**6)
        if c == 1: return round(rnd.uniform(-1000, 1000), 4)
        if c == 2: return rnd.choice([True, False, None])
        if c in (3, 4): return "%s %s" % (word(), word())
        if c < 7: return [val(d - 1) for _ in range(rnd.randrange(1, 6))]
        return {"%s_%d" % (word(), i): val(d - 1) for i in range(rnd.randrange(1, 6))}
    out, n = [], 0
    while n < size:
        s = json.dumps({"id": len(out), "items": [val(4) for _ in range(10)]}) + "\n---\n"
        out.append(s)
        n += len(s)
    return "".join(out)


def wide_flow_seq(size):
    """1 MB wide flow sequence: [item0, item1, ...]"""
    items = []
    n = 2  # '[' and ']'
    i = 0
    while n < size:
        item = "val_%d" % i
        items.append(item)
        n += len(item) + 2
        i += 1
    # lines stay below the 65535-column limit of the scanner: break after every 1000 items
    rows = [", ".join(items[k:k + 1000]) for k in range(0, len(items), 1000)]
    return "[" + ",\n".join(rows) + "]\n"


def map_100k():
    """100 k-entry map with duplicate keys."""
    out = ["map_100k:\n"]
    for i in range(100_000):
        out.append("  k_%d: %d\n" % (i, i))
    # Some duplicates
    for i in range(100):
        out.append("  k_%d: %d\n" % (i * 10, i * 1000))
    return "".join(out)


def alias_heavy():
    """10 k anchors, ~900 k aliases within budget."""
    out = ["# 10k anchors\nanchors:\n"]
    for i in range(10_000):
        out.append("  a%d: &a%d %d\n" % (i, i, i))
    out.append("aliases:\n")
    # 90 sequence items each expanding 10k aliases = 900k alias nodes (< 1M budget)
    for row in range(90):
        out.append("  - [")
        out.append(",\n    ".join(", ".join("*a%d" % i for i in range(k, k + 1000)) for k in range(0, 10_000, 1000)))
        out.append("]\n")
    return "".join(out)


def escape_heavy(size):
    """Escape-heavy double-quoted strings including \\L, \\P, escapes and unicodes."""
    out, n, i = [], 0, 0
    escapes = ["\\L", "\\P", "\\n", "\\t", "\\r", "\\0", '\\"', "\\\\", "\\x41", "\\u00e9", "\\U0001F600"]
    while n < size:
        esc_sample = " ".join(rnd.choice(escapes) + word() for _ in range(15))
        s = 'esc_%d: "%s \\L %s \\P %s"\n' % (i, esc_sample, word(), esc_sample)
        out.append(s)
        n += len(s)
        i += 1
    return "".join(out)


def depth_256():
    """Nesting at depth 256 (within MAX_DEPTH limit)."""
    return "[" * 256 + "leaf" + "]" * 256 + "\n"


def depth_257():
    """Nesting at depth 257 (exceeds MAX_DEPTH limit, expected to reject)."""
    return "[" * 257 + "leaf" + "]" * 257 + "\n"


def many_tags():
    """Many %TAG directives across multiple documents (<=16 per doc)."""
    out = []
    for doc in range(100):
        for i in range(10):
            out.append("%%TAG !h%d! tag:example.org,%d,%d:\n" % (i, doc, i))
        out.append("--- [!h0!v 1, !h1!v 2, !h2!v 3]\n...\n")
    return "".join(out)


def flow_key_2040():
    """A flow-map key of exactly 2040 tokens (within QUEUE_SIZE limit)."""
    return "{[" + "a," * 1018 + "a]: 1}\n"


def flow_key_2041():
    """A flow-map key of 2041 tokens (exceeds QUEUE_SIZE limit, expected to reject)."""
    return "{[" + "a," * 1019 + "a]: 1}\n"


def block_eof():
    """Block scalars at EOF without trailing newline."""
    return "key: |\n  first line\n  second line without trailing newline"


def suite():
    """The valid inputs of the yaml-test-suite (cases without an `error` file), one document
    stream after the other; "..." ends the previous stream (directives need it)."""
    parts = []
    for name in sorted(os.listdir(SUITE)):
        d = os.path.join(SUITE, name)
        # multi-test cases have numbered subdirectories
        dirs = [d] + [os.path.join(d, s) for s in sorted(os.listdir(d)) if s.isdigit()] if os.path.isdir(d) else []
        for c in dirs:
            f = os.path.join(c, "in.yaml")
            if os.path.isfile(f) and not os.path.exists(os.path.join(c, "error")):
                with open(f, "rb") as fh:
                    parts.append(fh.read().decode("utf-8"))
    return "\n...\n".join(p if p.endswith("\n") else p + "\n" for p in parts)


def main():
    target = int(float(sys.argv[1]) * MB) if len(sys.argv) > 1 else 10 * MB
    os.makedirs(OUT, exist_ok=True)
    files = {
        "config.yaml": config(target),
        "servers.yaml": servers(target // 2),
        "small-docs.yaml": small_docs(target),
        "long-strings.yaml": long_strings(target // 2),
        "deep.yaml": deep(target // 5),
        "flow.yaml": jsonish(target),
        "wide-seq.yaml": wide_flow_seq(1 * MB),
        "map-100k.yaml": map_100k(),
        "alias-heavy.yaml": alias_heavy(),
        "escape-heavy.yaml": escape_heavy(target // 4),
        "depth-256.yaml": depth_256(),
        "depth-257.yaml": depth_257(),
        "tags.yaml": many_tags(),
        "flow-key-2040.yaml": flow_key_2040(),
        "flow-key-2041.yaml": flow_key_2041(),
        "block-eof.yaml": block_eof(),
    }
    if os.path.isdir(SUITE):
        files["suite.yaml"] = suite()
    else:
        print("note: test-suite/ is missing, suite.yaml skipped", file=sys.stderr)
    for name, text in files.items():
        with open(os.path.join(OUT, name), "w", encoding="utf-8", newline="\n") as f:
            f.write(text)
        print("%-20s %10d bytes" % (name, len(text.encode("utf-8"))))


if __name__ == "__main__":
    main()
