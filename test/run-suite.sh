#!/usr/bin/env bash
# Run the yaml-test-suite against build/yamlv.
# usage: test/run-suite.sh [-v] [-j] [case-dir]
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

if [ -n "$one" ]; then
	"$bin" -e < "$one/in.yaml" | diff -u "$one/test.event" -
	exit $?
fi

vp=0; vf=0; ep=0; ef=0; failed=()
while read -r dir; do
	id=${dir#test-suite/}
	out=$(timeout 10 "$bin" -e < "$dir/in.yaml" 2>/dev/null); rc=$?
	if [ -f "$dir/error" ]; then
		if [ $rc -ne 0 ] && [ $rc -ne 124 ]; then ep=$((ep+1)); else ef=$((ef+1)); failed+=("error $id"); fi
	elif [ $rc -eq 0 ] && [ "$out" == "$(< "$dir/test.event")" ]; then
		vp=$((vp+1))
	else
		vf=$((vf+1)); failed+=("valid $id")
	fi
done < <(find test-suite/ -name in.yaml -not -path '*/tags/*' -not -path '*/name/*' -printf '%h\n' | sort)

echo "valid PASS $vp/$((vp+vf))  error PASS $ep/$((ep+ef))"
echo "PASS $((vp+ep)) / FAIL $((vf+ef)) / $((vp+vf+ep+ef))"
[ $verbose -eq 1 ] && [ ${#failed[@]} -gt 0 ] && printf '%s\n' "${failed[@]}"
if [ $json -eq 1 ]; then
	if ! command -v python3 >/dev/null; then
		echo "json: skipped (python3 not found)"
		exit 0
	fi
	tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
	# semantic comparison of two streams of concatenated JSON documents
	cat > "$tmp/cmp.py" <<'PY'
import json, sys
def docs(text):
    dec, i, out = json.JSONDecoder(), 0, []
    while True:
        while i < len(text) and text[i].isspace(): i += 1
        if i >= len(text): return out
        v, i = dec.raw_decode(text, i)
        out.append(v)
sys.exit(0 if docs(open(sys.argv[1]).read()) == docs(open(sys.argv[2]).read()) else 1)
PY
	jp=0; jt=0; jfailed=()
	while read -r dir; do
		[ -f "$dir/error" ] || [ ! -f "$dir/in.json" ] && continue
		jt=$((jt+1))
		if timeout 10 "$bin" -j < "$dir/in.yaml" > "$tmp/out.json" 2>/dev/null &&
			python3 -I "$tmp/cmp.py" "$dir/in.json" "$tmp/out.json" 2>/dev/null; then
			jp=$((jp+1))
		else
			jfailed+=("json ${dir#test-suite/}")
		fi
	done < <(find test-suite/ -name in.yaml -not -path '*/tags/*' -not -path '*/name/*' -printf '%h\n' | sort)
	echo "json PASS $jp/$jt"
	[ $verbose -eq 1 ] && [ ${#jfailed[@]} -gt 0 ] && printf '%s\n' "${jfailed[@]}"
fi
exit 0
