#!/bin/sh
# bench_9700k_extdict.sh : decoding speed on another cpu (ex : i7-9700K), dev vs branch bench-extdict (= PR #2140) :
#   - LZ4_decompress_incomplete() specialized on the dictionary's position
#   - lz4frame : detached history (dictionary) : beyond 64 KB, the block's rest decoded as with a prefix
#
# usage : sh bench_9700k_extdict.sh /path/to/silesia.tar [workdir]
#   CCS="gcc-13 gcc-14 clang-18" sh ...   (compilers, default : gcc clang)
#   CORE=3 sh ...                         (cpu to pin, default 2 ; needs taskset)
#   ROUNDS=6 sh ...                       (rounds, alternating builds, default 3)
#   PARTS="1 2" sh ...                    (also part 2, default : 1)
#
# Part 1 : lz4 -b1, decompression of frames (32 MB of silesia), without and with a 64 KB dictionary
#          (with a dictionary, blocks beyond 64 KB are decoded in two parts)
# Part 2 : fullbench, block functions : LZ4_decompress_safe (control), _forceExtDict, _incomplete (none, prefix, extDict)
# Builds use the default Makefile flags (JCC erratum mitigation included) ; fullbench.c : the branch's, for both.
set -e
SILESIA=${1:?usage : $0 /path/to/silesia.tar [workdir]}
case "$SILESIA" in /*) ;; *) SILESIA=$PWD/$SILESIA ;; esac
WORK=${2:-$PWD/bench_extdict}
CCS=${CCS:-"gcc clang"}
CORE=${CORE:-2}
ROUNDS=${ROUNDS:-3}
PARTS=${PARTS:-"1"}
REPO=${REPO:-https://github.com/lz4/lz4.git}
BRANCH=bench-extdict

mkdir -p "$WORK/bin"
cd "$WORK"
[ -d src ] || git clone -q "$REPO" src
git -C src fetch -q origin
NEW=$(git -C src rev-parse --short "origin/$BRANCH~1")   # the branch without this script
OLD=$(git -C src rev-parse --short "$(git -C src merge-base origin/dev "$NEW")")

# data : 32 MB from silesia (after its first MB), dictionary : its first 64 KB
[ -f sil32m ] || tail -c +1048577 "$SILESIA" | head -c 33554432 > sil32m
[ -f dict64k ] || head -c 65536 "$SILESIA" > dict64k

for cc in $CCS; do
    for c in $OLD $NEW; do
        b=bin/${cc}_$c
        [ -x "$b.lz4" ] && [ -x "$b.fb" ] && continue
        git -C src checkout -q -f "$c"
        git -C src show "$NEW:tests/bench/fullbench.c" > src/tests/bench/fullbench.c
        make -s -C src clean >/dev/null
        make -s -C src/tests clean >/dev/null
        make -s -C src -j"$(nproc)" lz4 CC="$cc" >/dev/null
        make -s -C src/tests -j"$(nproc)" fullbench CC="$cc" >/dev/null
        cp -L src/lz4 "$b.lz4"
        cp -L src/tests/fullbench "$b.fb"
        git -C src checkout -q -f "$c"
    done
done

PIN=""
command -v taskset >/dev/null && PIN="taskset -c $CORE"

# lz4speed binary options... : decompression speed (MB/s)
lz4speed() {
    b=$1; shift
    $PIN "$b" -b1 -i3 "$@" sil32m 2>&1 | tr '\r' '\n' | grep "MB/s" | tail -1 |
        sed 's/.*), *\([0-9.]*\) MB\/s, *\([0-9.]*\) MB\/s.*/\2/'
}
# fbspeed binary functionId blockSizeId : MB/s
fbspeed() {
    $PIN "$1" -d"$2" -i3 -B"$3" sil32m 2>&1 | tr '\r' '\n' | grep "MB/s" | tail -1 |
        sed 's/.*-> *\([0-9.]*\) MB\/s.*/\1/'
}

# compare label kind(lz4|fb) args... : average over ROUNDS, alternating builds
compare() {
    label=$1; kind=$2; shift 2
    for cc in $CCS; do
        so=0; sn=0; r=0
        while [ "$r" -lt "$ROUNDS" ]; do
            o=$(${kind}speed "bin/${cc}_$OLD.$kind" "$@")
            n=$(${kind}speed "bin/${cc}_$NEW.$kind" "$@")
            so=$(echo "$so $o" | awk '{print $1+$2}')
            sn=$(echo "$sn $n" | awk '{print $1+$2}')
            r=$((r+1))
        done
        echo "$label $cc $so $sn" | awk -v n="$ROUNDS" '{
            printf "%-36s %-10s %8.1f -> %8.1f MB/s  %+5.1f%%\n", $1, $2, $3/n, $4/n, ($4/$3-1)*100 }'
    done
}

echo "== cpu : $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2)"
echo "== dev $OLD -> branch $NEW, $ROUNDS rounds"
case " $PARTS " in *" 1 "*)
echo "== Part 1 : lz4 -b1, decompression"
for o in "-B4" "-B7" "-B4 -D dict64k" "-B5 -D dict64k" "-B6 -D dict64k" "-B7 -D dict64k"; do
    # shellcheck disable=SC2086
    compare "lz4$(echo $o | tr -d ' ' | sed 's/dict64k//')" lz4 $o
done ;;
esac
case " $PARTS " in *" 2 "*)
echo "== Part 2 : fullbench (4 : safe, 10 : forceExtDict, 14 / 15 / 16 : incomplete none / prefix / extDict)"
for B in 4 5 7; do
    for id in 4 10 14 15 16; do
        compare "fullbench-d$id-B$B" fb "$id" "$B"
    done
done ;;
esac
echo "== done"
