"""Seeds a generated multi-file torrent with libtorrent on 127.0.0.1 for end-to-end tests.

usage: python seeder.py <workdir> [port]
Writes <workdir>/test.torrent and the source files under <workdir>/seed/.
"""
import os
import random
import sys
import time

import libtorrent as lt

base = sys.argv[1]
port = sys.argv[2] if len(sys.argv) > 2 else "51413"
content = os.path.join(base, "seed", "测试 Pack")
os.makedirs(os.path.join(content, "sub"), exist_ok=True)
random.seed(1)
files = {"video.mp4": 12 * 1024 * 1024 + 12345, "sub/readme.txt": 1000, "sub/empty.bin": 0, "song.mp3": 3 * 1024 * 1024 + 7}
for name, size in files.items():
    p = os.path.join(content, name)
    if not os.path.exists(p):
        with open(p, "wb") as f:
            f.write(random.randbytes(size))

fs = lt.file_storage()
lt.add_files(fs, content)
t = lt.create_torrent(fs, 256 * 1024, flags=lt.create_torrent.v1_only)
t.add_tracker("udp://127.0.0.1:1/announce")
lt.set_piece_hashes(t, os.path.dirname(content))
tor = lt.bencode(t.generate())
with open(os.path.join(base, "test.torrent"), "wb") as f:
    f.write(tor)

ses = lt.session({"listen_interfaces": "127.0.0.1:" + port, "enable_dht": False, "enable_lsd": False,
                  "enable_upnp": False, "enable_natpmp": False, "allow_multiple_connections_per_ip": True})
info = lt.torrent_info(tor)
h = ses.add_torrent({"ti": info, "save_path": os.path.dirname(content), "flags": lt.torrent_flags.seed_mode})
print("INFOHASH", str(info.info_hash()), flush=True)
while True:
    s = h.status()
    print("seed", s.state, "peers", s.num_peers, "up", s.total_upload, flush=True)
    time.sleep(2)
