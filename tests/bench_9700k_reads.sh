#!/bin/sh
# lz4 -dc CPU time on silesia : dev vs this branch (input reads ending at multiples of their size)
# temporary : removed before the pull request
# usage : sh tests/bench_9700k_reads.sh /path/to/silesia.tar [workdir]   (ROUNDS=20 by default ; CPUS=0-7 to pin)
set -e
SILESIA=${1:?usage : $0 /path/to/silesia.tar [workdir]}
SILESIA=$(cd "$(dirname "$SILESIA")" && pwd)/$(basename "$SILESIA")
REPO=$(cd "$(dirname "$0")/.." && pwd)
WORK=${2:-$PWD/bench_9700k_reads}
ROUNDS=${ROUNDS:-20}
PIN=""; [ -n "$CPUS" ] && PIN="taskset -c $CPUS"
DEV=6d5ee52a
NEW=$(git -C "$REPO" rev-parse --short HEAD)
mkdir -p "$WORK/bin" && cd "$WORK"
rm -rf src && git clone -q "$REPO" src
if git -C src diff --quiet $DEV $NEW -- programs/lz4io.c; then echo "no change in lz4io.c between $DEV and $NEW"; exit 1; fi
for b in dev new; do
    if [ $b = dev ]; then c=$DEV; else c=$NEW; fi
    git -C src checkout -q $c
    make -s -C src clean >/dev/null; make -s -C src -j"$(nproc)" lz4 >/dev/null; cp -L src/lz4 bin/lz4-$b
    echo "lz4-$b : $c"
done
[ -f sil.lz4 ] || bin/lz4-dev -q "$SILESIA" sil.lz4
cat sil.lz4 > /dev/null
# run build mode : user and sys CPU of ROUNDS runs (children of the subshell)
run() {
    printf '%s %s : user sys over %s runs : ' "$2" "$1" "$ROUNDS"
    ( i=0
      while [ $i -lt "$ROUNDS" ]; do
          if [ "$2" = pipe ]; then cat sil.lz4 | $PIN bin/lz4-$1 -dc > /dev/null; else $PIN bin/lz4-$1 -dc sil.lz4 > /dev/null; fi
          i=$((i+1))
      done
      times ) | tail -1
}
for pass in 1 2; do for mode in file pipe; do run dev $mode; run new $mode; done; done
if command -v perf >/dev/null && perf stat -e cycles:k true >/dev/null 2>&1; then
    for b in dev new; do
        perf stat -r "$ROUNDS" -e cycles:u,cycles:k,instructions:k $PIN bin/lz4-$b -dc sil.lz4 2>&1 >/dev/null | grep -e cycles -e instructions | sed "s/^/$b /"
    done
fi
