#!/bin/bash
# run_wifi.sh NAME [SECONDS] — one T-127 workload run (wload + continuous tone) and the host.log slice for it.
# Output: ~/.cache/matebridge-tools/data/wifi-runs/NAME.{start,end,host.log}. Tablet logs: start an on-tablet
# capture first (README) and slice it by the .start/.end times afterwards.
set -e
D=$(cd "$(dirname "$0")" && pwd); N=$1; S=${2:-300}; O=~/.cache/matebridge-tools/data/wifi-runs; mkdir -p $O
B=~/.cache/matebridge-tools/wifi-bin; mkdir -p $B
[ -x $B/wload ] || swiftc -O $D/wload.swift -o $B/wload
[ -f $B/tone.wav ] || python3 $D/tone.py $B/tone.wav
HL=~/Library/Logs/MateBridge/host.log; off=$(wc -c < $HL); ino=$(stat -f %i $HL)
date "+%m-%d %H:%M:%S" > $O/$N.start
afplay $B/tone.wav & AP=$!
$B/wload $S
kill $AP 2>/dev/null || true
date "+%m-%d %H:%M:%S" > $O/$N.end
if [ "$(stat -f %i $HL)" = "$ino" ]; then tail -c +$((off+1)) $HL > $O/$N.host.log
else tail -c +$((off+1)) ~/Library/Logs/MateBridge/host.1.log > $O/$N.host.log; cat $HL >> $O/$N.host.log; fi
echo "done $N $(cat $O/$N.start) -> $(cat $O/$N.end), $(wc -l < $O/$N.host.log) host lines"
