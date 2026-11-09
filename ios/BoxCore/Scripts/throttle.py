"""TCP proxy that limits the download direction to RATE bytes/s (libtorrent ignores limits for local peers).

usage: python throttle.py <listen_port> <target_port> <rate>
"""
import asyncio
import sys

LISTEN, TARGET, RATE = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])


async def pipe(r, w, rate):
    try:
        while True:
            d = await r.read(16384)
            if not d:
                break
            w.write(d)
            await w.drain()
            if rate:
                await asyncio.sleep(len(d) / rate)
    except Exception:
        pass
    finally:
        w.close()


async def handle(cr, cw):
    sr, sw = await asyncio.open_connection("127.0.0.1", TARGET)
    await asyncio.gather(pipe(cr, sw, 0), pipe(sr, cw, RATE))


async def main():
    s = await asyncio.start_server(handle, "127.0.0.1", LISTEN)
    async with s:
        await s.serve_forever()


asyncio.run(main())
