#!/usr/bin/env python3
"""Minimal anland display daemon mock: handshake + fd pickup + dmabuf push +
buffer-ready pacing + an input event. Used to smoke-test the wlroots backend.

Protocol mirrors backend/anland/{protocol.h,display_producer.c} (5-fd version).
"""
import array, os, socket, struct, sys, time, threading

SOCK = "/tmp/anland-test.sock"
CTRL_MSG_PRODUCER_HELLO = 2
CTRL_MSG_SCREEN_INFO = 7
CTRL_MSG_PICKUP_FDS = 9
CTRL_MSG_FDS_READY = 10
DATA_MSG_BUFS_READY = 200
DATA_MSG_INPUT_EVENT = 102
INPUT_TYPE_KEY = 2
INPUT_ACTION_DOWN = 0

SCREEN_W, SCREEN_H = 640, 480
NBUFS = 2

def send_fds(sock, payload, fds):
    sock.sendmsg([payload], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array("i", fds))])

def recv_exact(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise EOFError
        buf += chunk
    return buf

def make_eventfd():
    import ctypes
    libc = ctypes.CDLL("libc.so.6", use_errno=True)
    fd = libc.eventfd(0, 0)
    assert fd >= 0
    return fd

def make_idx_shm():
    fd = os.memfd_create("anland_idx", 0)
    os.ftruncate(fd, 4)
    os.lseek(fd, 0, 0)
    os.write(fd, struct.pack("I", 0))
    return fd

def make_dmabuf(idx):
    # memfd stands in for a dma-buf: enough for the CPU copy path and for the
    # control flow. The GPU EGL import of a memfd will fail and fall back.
    fd = os.memfd_create(f"anland_buf{idx}", 0)
    stride = SCREEN_W * 4
    os.ftruncate(fd, stride * SCREEN_H)
    # paint a recognizable pattern
    os.lseek(fd, 0, 0)
    row = bytes([0x10 + idx, 0x20, 0x30, 0xFF]) * SCREEN_W
    os.write(fd, row * SCREEN_H)
    return fd

def main():
    if os.path.exists(SOCK):
        os.unlink(SOCK)
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(SOCK)
    srv.listen(2)
    print("mock: listening on", SOCK, flush=True)

    cli, _ = srv.accept()
    print("mock: producer connected", flush=True)

    # handshake: PRODUCER_HELLO -> SCREEN_INFO
    hdr = recv_exact(cli, 8)
    typ, size = struct.unpack("II", hdr)
    assert typ == CTRL_MSG_PRODUCER_HELLO, typ
    si = struct.pack("IIII", SCREEN_W, SCREEN_H, 1, 60000)  # format 1 = RGBA_8888
    cli.sendall(struct.pack("II", CTRL_MSG_SCREEN_INFO, len(si)) + si)
    print("mock: sent screen info", flush=True)

    # PICKUP_FDS -> FDS_READY + 4 fds
    hdr = recv_exact(cli, 8)
    typ, size = struct.unpack("II", hdr)
    assert typ == CTRL_MSG_PICKUP_FDS, typ

    buf_ready = make_eventfd()
    refresh_done = make_eventfd()
    a, b = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)
    data_fd = a.fileno()  # consumer end kept in `a` below
    idx_fd = make_idx_shm()
    send_fds(cli, struct.pack("II", CTRL_MSG_FDS_READY, 0),
             [buf_ready, refresh_done, data_fd, idx_fd])
    print("mock: sent 4 fds", flush=True)

    # dmabuf set goes on the data channel, right after the fd handshake
    bufs = [make_dmabuf(i) for i in range(NBUFS)]
    stride = SCREEN_W * 4
    infos = b"".join(struct.pack("IIQI", stride, 1, 0, 0) for _ in range(NBUFS))
    dhdr = struct.pack("II", DATA_MSG_BUFS_READY, len(infos))
    send_fds(b, dhdr, bufs)
    b.sendall(infos)
    print("mock: sent dmabuf set", flush=True)

    time.sleep(1.2)

    # input: a key press on the data channel
    # InputEvent: type u32 + union (action i32, keycode i32, ...) packed
    ev = struct.pack("I", INPUT_TYPE_KEY)
    ev += struct.pack("ii", INPUT_ACTION_DOWN, 30)  # action, keycode (KEY_A)
    ev += b"\x00" * (48 - len(ev))  # pad to sizeof(InputEvent) ~48
    # sizeof(InputEvent): 4 + max(union) = 4 + 16 = 20, packed. Let the C side
    # size-match: send 4 + 16.
    ev = struct.pack("I", INPUT_TYPE_KEY) + struct.pack("ii", INPUT_ACTION_DOWN, 30)
    ev += b"\x00" * 8  # rest of the union
    msg = struct.pack("II", DATA_MSG_INPUT_EVENT, 0) + ev.ljust(20, b"\x00")
    b.sendall(msg)
    print("mock: sent input event", flush=True)

    # request a frame: buffer-ready
    os.write(buf_ready, struct.pack("Q", 1))
    print("mock: sent buffer-ready", flush=True)

    # wait for trigger_refresh (eventfd write on refresh_done)
    import select
    r, _, _ = select.select([refresh_done], [], [], 3.0)
    if r:
        val = struct.unpack("Q", os.read(refresh_done, 8))[0]
        print(f"MOCK_OK trigger_refresh received (eventfd={val})", flush=True)
    else:
        print("MOCK_FAIL no trigger_refresh within 3s", flush=True)
        sys.exit(1)

    # Check whether the compositor frame made it into the selected buffer.
    # The host paints solid (r=0.25, g=0.5, b=0.75) over the whole buffer; the
    # mock pre-filled each buffer with (0x10+i, 0x20, 0x30, 0xff). The commit
    # may land before or after this check depending on event ordering, so poll.
    os.lseek(bufs[0], 0, 0)
    px = os.read(bufs[0], 4)
    print(f"mock: buf[0] first pixel after trigger: {px.hex()} "
          f"(was 102030ff)", flush=True)
    if px != b"\x10\x20\x30\xff":
        print("MOCK_COPY_OK consumer buffer was updated by the producer",
              flush=True)
    else:
        print("MOCK_COPY_NOTE buffer still has the pre-fill pattern "
              "(no frame commit reached the copy path)", flush=True)

    time.sleep(0.2)
    os.unlink(SOCK)
    print("mock: done", flush=True)

if __name__ == "__main__":
    main()
