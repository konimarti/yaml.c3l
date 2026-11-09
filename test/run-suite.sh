#!/usr/bin/env bash
# Run the yaml-test-suite (data branch, in test-suite/) against build/yamlv.
# usage: test/run-suite.sh [-v] [-j] [case-dir]
# Exit status: 0 if every case passes, 1 if one fails, 2 on a setup error.
# Runs under bash 3.2 (macOS) and Git Bash (Windows).
cd "$(dirname "$0")/.." || exit 2
verbose=0; json=0; one=""
for arg in "$@"; do
	case "$arg" in
		-v) verbose=1 ;;
		-j) json=1 ;;
		*) one="$arg" ;;
	esac
done

c3c build yamlv >/dev/null || { echo "build failed"; exit 2; }
bin=build/yamlv
[ -x "$bin" ] || bin=build/yamlv.exe

# a per-case timeout where the platform has one (not on stock macOS)
tmo=""
if command -v timeout >/dev/null 2>&1; then tmo="timeout 10"
elif command -v gtimeout >/dev/null 2>&1; then tmo="gtimeout 10"; fi

# the expected files may have been checked out with CRLF; so may the output on Windows
nocr() { tr -d '\r'; }

if [ -n "$one" ]; then
	$tmo "$bin" -e < "$one/in.yaml" | nocr | diff -u <(nocr < "$one/test.event") -
	exit $?
fi

cases=$(find test-suite -name in.yaml -not -path '*/tags/*' -not -path '*/name/*' | sort)
[ -n "$cases" ] || { echo "no cases in test-suite/"; exit 2; }

vp=0; vf=0; ep=0; ef=0; failed=()
while read -r f; do
	dir=${f%/in.yaml}; id=${dir#test-suite/}
	out=$($tmo "$bin" -e < "$f" 2>/dev/null | nocr; exit "${PIPESTATUS[0]}"); rc=$?   # 1: a parse error; a crash or timeout is not
	if [ -f "$dir/error" ]; then
		if [ $rc -eq 1 ]; then ep=$((ep+1)); else ef=$((ef+1)); failed+=("error $id"); fi
	elif [ $rc -eq 0 ] && [ "$out" == "$(nocr < "$dir/test.event")" ]; then
		vp=$((vp+1))
	else
		vf=$((vf+1)); failed+=("valid $id")
	fi
done <<< "$cases"

status=0
echo "valid PASS $vp/$((vp+vf))  error PASS $ep/$((ep+ef))"
echo "PASS $((vp+ep)) / FAIL $((vf+ef)) / $((vp+vf+ep+ef))"
[ $((vf+ef)) -eq 0 ] || status=1
[ $verbose -eq 1 ] && [ ${#failed[@]} -gt 0 ] && printf '%s\n' "${failed[@]}"
if [ $json -eq 1 ]; then
	py=""
	for p in python3 python; do
		if "$p" -c 'import json' >/dev/null 2>&1; then py=$p; break; fi
	done
	if [ -z "$py" ]; then
		echo "json: skipped (python not found)"
		exit $status
	fi
	mkdir -p build; tmp=build/suite.$$; mkdir "$tmp" || exit 2
	trap 'rm -rf "$tmp"' EXIT
	# semantic comparison of two streams of concatenated JSON documents
	cat > "$tmp/cmp.py" <<'PY'
import json, sys
def docs(path):
    text = open(path, encoding='utf-8').read()
    dec, i, out = json.JSONDecoder(), 0, []
    while True:
        while i < len(text) and text[i].isspace(): i += 1
        if i >= len(text): return out
        v, i = dec.raw_decode(text, i)
        out.append(v)
sys.exit(0 if docs(sys.argv[1]) == docs(sys.argv[2]) else 1)
PY
	jp=0; jt=0; jfailed=()
	while read -r f; do
		dir=${f%/in.yaml}
		{ [ -f "$dir/error" ] || [ ! -f "$dir/in.json" ]; } && continue
		jt=$((jt+1))
		if $tmo "$bin" -j < "$f" > "$tmp/out.json" 2>/dev/null &&
			"$py" -I "$tmp/cmp.py" "$dir/in.json" "$tmp/out.json" 2>/dev/null; then
			jp=$((jp+1))
		else
			jfailed+=("json ${dir#test-suite/}")
		fi
	done <<< "$cases"
	echo "json PASS $jp/$jt"
	[ $jp -eq $jt ] || status=1
	[ $verbose -eq 1 ] && [ ${#jfailed[@]} -gt 0 ] && printf '%s\n' "${jfailed[@]}"
fi
exit $status
