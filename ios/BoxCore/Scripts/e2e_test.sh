#!/usr/bin/env bash
# End-to-end test of TorrentKit against a real libtorrent seeder on localhost:
#   1. download from a .torrent
#   2. download from a magnet link (BEP 9 metadata exchange)
#   3. play-while-downloading: HTTP Range requests through the stream server
#   4. interrupt + resume (recheck of existing data)
# Requires: python3 with `pip install libtorrent`, curl.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PKG="$HERE/.."
PY="${PYTHON:-python3}"
WORK="$(mktemp -d)"
cleanup() {
  status=$?
  if [ $status -ne 0 ]; then
    echo "---- seeder log"; tail -20 "$WORK/seeder.log" 2>/dev/null || true
    for f in "$WORK"/*.log; do echo "---- $f"; tail -30 "$f"; done
  fi
  kill $(jobs -p) 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

wait_port() {
  for _ in $(seq 1 60); do
    (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null && return 0
    sleep 0.5
  done
  echo "port $1 never opened"; return 1
}

(cd "$PKG" && swift build --product boxcli)
BIN="$(cd "$PKG" && swift build --show-bin-path)/boxcli"

"$PY" "$HERE/seeder.py" "$WORK" 51413 > "$WORK/seeder.log" 2>&1 &
"$PY" "$HERE/throttle.py" 51420 51413 600000 &
for _ in $(seq 1 60); do grep -q INFOHASH "$WORK/seeder.log" 2>/dev/null && break; sleep 0.5; done
wait_port 51413
wait_port 51420
HASH="$(grep INFOHASH "$WORK/seeder.log" | awk '{print $2}')"
SRC="$WORK/seed/测试 Pack"
echo "infohash $HASH"

echo "== 1. .torrent download"
timeout 120 "$BIN" download "$WORK/test.torrent" "$WORK/dl1" --peer 127.0.0.1:51413 --timeout 100 > "$WORK/dl1.log"
tail -1 "$WORK/dl1.log"
diff -r "$SRC" "$WORK/dl1/测试 Pack"

echo "== 2. magnet download"
timeout 120 "$BIN" download "magnet:?xt=urn:btih:$HASH&dn=test&x.pe=127.0.0.1:51413" "$WORK/dl2" --timeout 100 > "$WORK/dl2.log"
tail -1 "$WORK/dl2.log"
diff -r "$SRC" "$WORK/dl2/测试 Pack"

echo "== 3. streaming while downloading (throttled)"
"$BIN" download "magnet:?xt=urn:btih:$HASH&x.pe=127.0.0.1:51420" "$WORK/dl3" --stream 3 --linger 5 --timeout 200 > "$WORK/dl3.log" 2>&1 &
for _ in $(seq 1 60); do grep -q STREAM_URL "$WORK/dl3.log" && break; sleep 0.5; done
URL="$(grep STREAM_URL "$WORK/dl3.log" | awk '{print $2}')"
case "$URL" in http://*) ;; *) echo "expected http stream url, got $URL"; exit 1;; esac
curl -sf -H "Range: bytes=-100000" -o "$WORK/tail.bin" "$URL"
tail -c 100000 "$SRC/video.mp4" | cmp - "$WORK/tail.bin"
curl -sf -H "Range: bytes=5000000-5999999" -o "$WORK/mid.bin" "$URL"
head -c 6000000 "$SRC/video.mp4" | tail -c 1000000 | cmp - "$WORK/mid.bin"
for _ in $(seq 1 200); do grep -q DONE "$WORK/dl3.log" && break; sleep 1; done
diff -r "$SRC" "$WORK/dl3/测试 Pack"

echo "== 4. interrupt and resume"
timeout 6 "$BIN" download "$WORK/test.torrent" "$WORK/dl4" --peer 127.0.0.1:51420 > /dev/null || true
timeout 120 "$BIN" download "$WORK/test.torrent" "$WORK/dl4" --peer 127.0.0.1:51420 --timeout 100 > "$WORK/dl4.log"
tail -1 "$WORK/dl4.log"
diff -r "$SRC" "$WORK/dl4/测试 Pack"

echo "ALL E2E TESTS PASSED"
