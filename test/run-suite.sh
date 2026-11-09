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
[ $verbose -eq 1 ] && printf '%s\n' "${failed[@]}"
[ $json -eq 1 ] && echo "json: not implemented before M6"
exit 0
