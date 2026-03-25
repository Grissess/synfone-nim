#!/bin/bash

sfz="${1:?Usage: $0 /path/to/sfz}"
samprate="${SAMPLE_RATE:-44100}"
sox="${SOX:-sox}"

sfzdir="$(dirname "$sfz")"
tmpdir="$(mktemp -d samples.XXXXXX)"

verbose() {
	echo >&2 "$@"
	"$@"
}

args=( $(while read LINE; do
	case "$LINE" in
		key=*)
			pitch=$(cut -d= -f2 <<< "$LINE")
			freq=$(bc -l <<< "440 * e( (($pitch - 69) / 12) * l(2) )" | cut -d. -f1)
			;;
		sample=*)
			sample="$sfzdir/$(cut -d= -f2- <<< "$LINE")"
			outsamp="$tmpdir/$(basename "$(dirname "$sample")")_$(basename "$sample").raw"
			verbose sox "$sample" -r $samprate -c 1 -e floating-point -b 32 -t raw "$outsamp"
			echo "$freq:$outsamp"
			;;
	esac
done < "$sfz") )

verbose "$(dirname "$0")/synfone" sampler "${args[@]}" > sampler.cbor
rm -rf "$tmpdir"
