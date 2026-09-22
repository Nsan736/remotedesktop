"""RemoteDesk host for Windows.

Captures the desktop with ffmpeg (ddagrab + NVENC), streams H.264 access units
over TCP to the iPad client, and injects mouse/keyboard input with SendInput.

Run:  python host.py [--config config.json]
"""

import argparse
import ctypes
import ctypes.wintypes as wt
import json
import os
import queue
import shutil
import socket
import struct
import subprocess
import sys
import threading
import time
import traceback

DISCOVERY_PORT = 47001
DISCOVERY_MAGIC = b"RDESK_DISCOVER_V1"
DISCOVERY_REPLY = b"RDESK_HERE_V1"

# Server -> client message types
MSG_VIDEO = 1
MSG_PONG = 2
MSG_INFO = 3

# Client -> server message types
MSG_HELLO = 10
MSG_MOUSE_ABS = 11
MSG_MOUSE_REL = 12
MSG_BUTTON = 13
MSG_WHEEL = 14
MSG_KEY = 15
MSG_TEXT = 16
MSG_PING = 17

DEFAULT_CONFIG = {
    "port": 47000,
    "pin": "",
    "monitor": 0,
    "fps": 60,
    "bitrate_mbps": 20,
    "encoder": "auto",
    "scale_width": 0,
    "gop": 60,
    "max_backlog_frames": 3,
}


def log(*a):
    print(time.strftime("%H:%M:%S"), *a, flush=True)


# ---------------------------------------------------------------------------
# Win32 input injection
# ---------------------------------------------------------------------------

user32 = ctypes.WinDLL("user32", use_last_error=True)

try:
    user32.SetProcessDpiAwarenessContext(ctypes.c_void_p(-4))
except Exception:
    try:
        user32.SetProcessDPIAware()
    except Exception:
        pass

ULONG_PTR = ctypes.c_size_t


class MOUSEINPUT(ctypes.Structure):
    _fields_ = [
        ("dx", wt.LONG),
        ("dy", wt.LONG),
        ("mouseData", wt.DWORD),
        ("dwFlags", wt.DWORD),
        ("time", wt.DWORD),
        ("dwExtraInfo", ULONG_PTR),
    ]


class KEYBDINPUT(ctypes.Structure):
    _fields_ = [
        ("wVk", wt.WORD),
        ("wScan", wt.WORD),
        ("dwFlags", wt.DWORD),
        ("time", wt.DWORD),
        ("dwExtraInfo", ULONG_PTR),
    ]


class HARDWAREINPUT(ctypes.Structure):
    _fields_ = [("uMsg", wt.DWORD), ("wParamL", wt.WORD), ("wParamH", wt.WORD)]


class _INPUTUNION(ctypes.Union):
    _fields_ = [("mi", MOUSEINPUT), ("ki", KEYBDINPUT), ("hi", HARDWAREINPUT)]


class INPUT(ctypes.Structure):
    _anonymous_ = ("u",)
    _fields_ = [("type", wt.DWORD), ("u", _INPUTUNION)]


INPUT_MOUSE = 0
INPUT_KEYBOARD = 1

MOUSEEVENTF_MOVE = 0x0001
MOUSEEVENTF_LEFTDOWN = 0x0002
MOUSEEVENTF_LEFTUP = 0x0004
MOUSEEVENTF_RIGHTDOWN = 0x0008
MOUSEEVENTF_RIGHTUP = 0x0010
MOUSEEVENTF_MIDDLEDOWN = 0x0020
MOUSEEVENTF_MIDDLEUP = 0x0040
MOUSEEVENTF_XDOWN = 0x0080
MOUSEEVENTF_XUP = 0x0100
MOUSEEVENTF_WHEEL = 0x0800
MOUSEEVENTF_HWHEEL = 0x1000
MOUSEEVENTF_VIRTUALDESK = 0x4000
MOUSEEVENTF_ABSOLUTE = 0x8000

KEYEVENTF_EXTENDEDKEY = 0x0001
KEYEVENTF_KEYUP = 0x0002
KEYEVENTF_UNICODE = 0x0004
KEYEVENTF_SCANCODE = 0x0008

SM_XVIRTUALSCREEN = 76
SM_YVIRTUALSCREEN = 77
SM_CXVIRTUALSCREEN = 78
SM_CYVIRTUALSCREEN = 79

MAPVK_VK_TO_VSC_EX = 4

EXTENDED_VKS = {
    0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x2D, 0x2E,
    0x5B, 0x5C, 0x5D, 0x6F, 0xA3, 0xA5, 0x90, 0x2C, 0x13,
}

MonitorEnumProc = ctypes.WINFUNCTYPE(
    ctypes.c_int, ctypes.c_void_p, ctypes.c_void_p, ctypes.POINTER(wt.RECT), ctypes.c_double
)


def enum_monitors():
    rects = []

    def cb(hmon, hdc, prect, data):
        r = prect.contents
        rects.append((r.left, r.top, r.right, r.bottom))
        return 1

    user32.EnumDisplayMonitors(None, None, MonitorEnumProc(cb), 0)
    return rects


class Injector:
    def __init__(self, monitor_index):
        rects = enum_monitors()
        if not rects:
            rects = [(0, 0, user32.GetSystemMetrics(0), user32.GetSystemMetrics(1))]
        if monitor_index >= len(rects):
            log(f"monitor {monitor_index} not found, using 0")
            monitor_index = 0
        self.mon = rects[monitor_index]
        self.vx = user32.GetSystemMetrics(SM_XVIRTUALSCREEN)
        self.vy = user32.GetSystemMetrics(SM_YVIRTUALSCREEN)
        self.vw = user32.GetSystemMetrics(SM_CXVIRTUALSCREEN)
        self.vh = user32.GetSystemMetrics(SM_CYVIRTUALSCREEN)
        self.width = self.mon[2] - self.mon[0]
        self.height = self.mon[3] - self.mon[1]
        log(f"monitor {monitor_index}: {self.mon} size {self.width}x{self.height}")

    def _send(self, inp):
        n = user32.SendInput(1, ctypes.byref(inp), ctypes.sizeof(INPUT))
        if n != 1:
            log("SendInput failed", ctypes.get_last_error())

    def _mouse(self, dx=0, dy=0, data=0, flags=0):
        inp = INPUT(type=INPUT_MOUSE)
        inp.mi = MOUSEINPUT(dx, dy, data, flags, 0, 0)
        self._send(inp)

    def move_abs(self, nx, ny):
        """nx, ny are 0..65535 relative to the captured monitor."""
        px = self.mon[0] + nx * self.width / 65535.0
        py = self.mon[1] + ny * self.height / 65535.0
        ax = int((px - self.vx) * 65535 / max(1, self.vw - 1))
        ay = int((py - self.vy) * 65535 / max(1, self.vh - 1))
        ax = min(max(ax, 0), 65535)
        ay = min(max(ay, 0), 65535)
        self._mouse(ax, ay, 0, MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK)

    def move_rel(self, dx, dy):
        self._mouse(dx, dy, 0, MOUSEEVENTF_MOVE)

    def button(self, btn, down):
        table = {
            0: (MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP, 0),
            1: (MOUSEEVENTF_RIGHTDOWN, MOUSEEVENTF_RIGHTUP, 0),
            2: (MOUSEEVENTF_MIDDLEDOWN, MOUSEEVENTF_MIDDLEUP, 0),
            3: (MOUSEEVENTF_XDOWN, MOUSEEVENTF_XUP, 1),
            4: (MOUSEEVENTF_XDOWN, MOUSEEVENTF_XUP, 2),
        }
        if btn not in table:
            return
        fdown, fup, data = table[btn]
        self._mouse(0, 0, data, fdown if down else fup)

    def wheel(self, dy, dx):
        if dy:
            self._mouse(0, 0, ctypes.c_uint32(dy & 0xFFFFFFFF).value, MOUSEEVENTF_WHEEL)
        if dx:
            self._mouse(0, 0, ctypes.c_uint32(dx & 0xFFFFFFFF).value, MOUSEEVENTF_HWHEEL)

    def key(self, vk, down):
        scan = user32.MapVirtualKeyW(vk, MAPVK_VK_TO_VSC_EX) & 0xFF
        flags = 0
        if vk in EXTENDED_VKS:
            flags |= KEYEVENTF_EXTENDEDKEY
        if not down:
            flags |= KEYEVENTF_KEYUP
        inp = INPUT(type=INPUT_KEYBOARD)
        inp.ki = KEYBDINPUT(vk, scan, flags, 0, 0)
        self._send(inp)

    def text(self, s):
        for ch in s:
            raw = ch.encode("utf-16-le")
            units = struct.unpack("<%dH" % (len(raw) // 2), raw)
            for u in units:
                for up in (0, KEYEVENTF_KEYUP):
                    inp = INPUT(type=INPUT_KEYBOARD)
                    inp.ki = KEYBDINPUT(0, u, KEYEVENTF_UNICODE | up, 0, 0)
                    self._send(inp)


# ---------------------------------------------------------------------------
# ffmpeg capture / encode
# ---------------------------------------------------------------------------


def find_ffmpeg():
    here = os.path.dirname(os.path.abspath(__file__))
    for cand in (os.path.join(here, "ffmpeg.exe"), os.path.join(here, "ffmpeg", "bin", "ffmpeg.exe")):
        if os.path.exists(cand):
            return cand
    return shutil.which("ffmpeg")


def available_encoders(ffmpeg):
    try:
        out = subprocess.run(
            [ffmpeg, "-hide_banner", "-encoders"], capture_output=True, text=True, timeout=10
        ).stdout
    except Exception:
        return set()
    names = set()
    for line in out.splitlines():
        parts = line.split()
        if len(parts) >= 2 and parts[0].startswith("V"):
            names.add(parts[1])
    return names


def pick_encoder(ffmpeg, wanted):
    if wanted != "auto":
        return wanted
    encs = available_encoders(ffmpeg)
    for e in ("h264_nvenc", "h264_amf", "h264_qsv", "libx264"):
        if e in encs:
            return e
    return "libx264"


def build_ffmpeg_cmd(ffmpeg, cfg, encoder, rtp_port):
    fps = int(cfg["fps"])
    gop = int(cfg["gop"])
    br = f"{cfg['bitrate_mbps']}M"
    grab = f"ddagrab=output_idx={int(cfg['monitor'])}:framerate={fps}:draw_mouse=1"
    cmd = [
        ffmpeg, "-hide_banner", "-loglevel", "warning", "-nostats",
        "-init_hw_device", "d3d11va",
        "-filter_complex",
    ]
    scale_w = int(cfg.get("scale_width") or 0)

    if encoder == "h264_nvenc" and scale_w == 0:
        cmd += [grab, "-c:v", "h264_nvenc",
                "-preset", "p1", "-tune", "ull", "-profile:v", "high",
                "-rc", "cbr", "-b:v", br, "-maxrate", br, "-bufsize", br,
                "-multipass", "0", "-rc-lookahead", "0", "-bf", "0",
                "-g", str(gop), "-forced-idr", "1", "-delay", "0", "-zerolatency", "1"]
    else:
        vf = grab + ",hwdownload,format=bgra"
        if scale_w:
            vf += f",scale={scale_w}:-2:flags=fast_bilinear"
        vf += ",format=nv12"
        cmd += [vf]
        if encoder == "h264_nvenc":
            cmd += ["-c:v", "h264_nvenc", "-preset", "p1", "-tune", "ull", "-profile:v", "high",
                    "-rc", "cbr", "-b:v", br, "-bufsize", br, "-multipass", "0",
                    "-rc-lookahead", "0", "-bf", "0", "-g", str(gop), "-forced-idr", "1",
                    "-delay", "0", "-zerolatency", "1"]
        elif encoder == "h264_amf":
            cmd += ["-c:v", "h264_amf", "-usage", "ultralowlatency", "-quality", "speed",
                    "-rc", "cbr", "-b:v", br, "-bf", "0", "-g", str(gop)]
        elif encoder == "h264_qsv":
            cmd += ["-c:v", "h264_qsv", "-preset", "veryfast", "-b:v", br, "-bf", "0",
                    "-g", str(gop), "-async_depth", "1", "-look_ahead", "0"]
        else:
            cmd += ["-c:v", "libx264", "-preset", "ultrafast", "-tune", "zerolatency",
                    "-b:v", br, "-maxrate", br, "-bufsize", br, "-bf", "0", "-g", str(gop),
                    "-threads", "8", "-x264-params", "sliced-threads=1:rc-lookahead=0:sync-lookahead=0"]
    cmd += ["-bsf:v", "dump_extra=freq=keyframe", "-f", "rtp", "-payload_type", "96",
            "-flush_packets", "1", f"rtp://127.0.0.1:{rtp_port}?pkt_size={RTP_PKT_SIZE}"]
    return cmd


RTP_PKT_SIZE = 8000
START_CODE = b"\x00\x00\x00\x01"


class RTPDepacketizer:
    """Reassembles H.264 access units from RFC 6184 RTP packets (single NAL, STAP-A, FU-A)."""

    def __init__(self):
        self.nals = []
        self.fu = None
        self.last_seq = None
        self.corrupt = False

    def push(self, pkt):
        """Feed one RTP packet. Returns (annexb_bytes, corrupt) when an access unit completes."""
        if len(pkt) < 12 or (pkt[0] >> 6) != 2:
            return None
        cc = pkt[0] & 0x0F
        ext = pkt[0] & 0x10
        marker = pkt[1] & 0x80
        seq = (pkt[2] << 8) | pkt[3]
        off = 12 + 4 * cc
        if ext:
            if len(pkt) < off + 4:
                return None
            off += 4 + 4 * ((pkt[off + 2] << 8) | pkt[off + 3])
        if pkt[0] & 0x20:
            pkt = pkt[:len(pkt) - pkt[-1]]
        if self.last_seq is not None and seq != (self.last_seq + 1) & 0xFFFF:
            self.corrupt = True
            self.fu = None
        self.last_seq = seq
        payload = pkt[off:]
        if not payload:
            return None
        ntype = payload[0] & 0x1F
        if 1 <= ntype <= 23:
            self.nals.append(payload)
        elif ntype == 24:
            i = 1
            while i + 2 <= len(payload):
                size = (payload[i] << 8) | payload[i + 1]
                i += 2
                self.nals.append(payload[i:i + size])
                i += size
        elif ntype == 28 and len(payload) >= 2:
            fu_hdr = payload[1]
            if fu_hdr & 0x80:
                self.fu = bytearray([(payload[0] & 0xE0) | (fu_hdr & 0x1F)])
                self.fu += payload[2:]
            elif self.fu is not None:
                self.fu += payload[2:]
            else:
                self.corrupt = True
            if fu_hdr & 0x40 and self.fu is not None:
                self.nals.append(bytes(self.fu))
                self.fu = None
        if marker:
            au = b"".join(START_CODE + n for n in self.nals)
            corrupt = self.corrupt or self.fu is not None
            self.nals = []
            self.fu = None
            self.corrupt = False
            return au, corrupt
        return None


def au_is_keyframe(au):
    pos = 0
    n = len(au)
    while True:
        i = au.find(b"\x00\x00\x01", pos)
        if i < 0 or i + 3 >= n:
            return False
        if au[i + 3] & 0x1F == 5:
            return True
        pos = i + 3


# ---------------------------------------------------------------------------
# Session
# ---------------------------------------------------------------------------


def pack_msg(mtype, payload):
    return struct.pack("<BI", mtype, len(payload)) + payload


def recv_exact(sock, n):
    data = bytearray()
    while len(data) < n:
        chunk = sock.recv(n - len(data))
        if not chunk:
            return None
        data += chunk
    return bytes(data)


class Session:
    def __init__(self, sock, addr, cfg, ffmpeg, encoder):
        self.sock = sock
        self.addr = addr
        self.cfg = cfg
        self.ffmpeg = ffmpeg
        self.encoder = encoder
        self.alive = True
        self.q = queue.Queue(maxsize=max(1, int(cfg["max_backlog_frames"])))
        self.proc = None
        self.inj = None
        self.send_lock = threading.Lock()
        self.rtp_sock = None

    def send(self, mtype, payload):
        with self.send_lock:
            self.sock.sendall(pack_msg(mtype, payload))

    def run(self):
        self.sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 256 * 1024)
        try:
            if not self.handshake():
                return
            self.inj = Injector(int(self.cfg["monitor"]))
            info = {
                "width": self.inj.width,
                "height": self.inj.height,
                "fps": self.cfg["fps"],
                "encoder": self.encoder,
            }
            self.send(MSG_INFO, json.dumps(info).encode())
            self.start_ffmpeg()
            threading.Thread(target=self.reader_loop, daemon=True).start()
            threading.Thread(target=self.sender_loop, daemon=True).start()
            self.input_loop()
        except (ConnectionError, OSError) as e:
            log("session error:", e)
        finally:
            self.alive = False
            self.stop_ffmpeg()
            try:
                self.sock.close()
            except OSError:
                pass
            log("session closed", self.addr)

    def handshake(self):
        self.sock.settimeout(5)
        hdr = recv_exact(self.sock, 5)
        if not hdr:
            return False
        mtype, length = struct.unpack("<BI", hdr)
        if mtype != MSG_HELLO or length > 4096:
            log("bad hello from", self.addr)
            return False
        body = recv_exact(self.sock, length)
        if body is None:
            return False
        try:
            hello = json.loads(body.decode())
        except Exception:
            return False
        if self.cfg["pin"] and str(hello.get("pin", "")) != str(self.cfg["pin"]):
            log("wrong pin from", self.addr)
            self.send(MSG_INFO, json.dumps({"error": "wrong pin"}).encode())
            return False
        self.sock.settimeout(None)
        log("client", self.addr, "hello", hello)
        return True

    def start_ffmpeg(self):
        self.rtp_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.rtp_sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 8 * 1024 * 1024)
        self.rtp_sock.bind(("127.0.0.1", 0))
        self.rtp_sock.settimeout(1.0)
        rtp_port = self.rtp_sock.getsockname()[1]
        cmd = build_ffmpeg_cmd(self.ffmpeg, self.cfg, self.encoder, rtp_port)
        log("ffmpeg:", " ".join(cmd))
        self.proc = subprocess.Popen(
            cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, stdin=subprocess.DEVNULL,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )
        threading.Thread(target=self.stderr_loop, daemon=True).start()

    def stop_ffmpeg(self):
        p = self.proc
        if p and p.poll() is None:
            try:
                p.kill()
            except Exception:
                pass
        if self.rtp_sock:
            try:
                self.rtp_sock.close()
            except OSError:
                pass

    def stderr_loop(self):
        p = self.proc
        for line in iter(p.stderr.readline, b""):
            log("ffmpeg:", line.decode(errors="replace").rstrip())

    def reader_loop(self):
        p = self.proc
        depack = RTPDepacketizer()
        wait_idr = True
        frames = 0
        t0 = time.time()
        dropped = 0
        total = 0
        try:
            while self.alive:
                try:
                    pkt = self.rtp_sock.recv(65535)
                except socket.timeout:
                    if p.poll() is not None:
                        log("ffmpeg exited with", p.returncode)
                        break
                    continue
                except OSError:
                    if not self.alive:
                        break
                    raise
                result = depack.push(pkt)
                if result is None:
                    continue
                au, corrupt = result
                key = au_is_keyframe(au)
                if corrupt:
                    log("corrupt access unit (packet loss), waiting for keyframe")
                    wait_idr = True
                    continue
                if wait_idr:
                    if not key:
                        dropped += 1
                        continue
                    wait_idr = False
                if total == 0:
                    log(f"first frame from encoder ({len(au)} bytes)")
                try:
                    if key:
                        while True:
                            try:
                                self.q.get_nowait()
                                dropped += 1
                            except queue.Empty:
                                break
                    self.q.put_nowait((au, key))
                except queue.Full:
                    dropped += 1
                    wait_idr = True
                frames += 1
                total += 1
                if frames % 600 == 0:
                    dt = time.time() - t0
                    log(f"video {frames / dt:.1f} fps, dropped {dropped}")
                    frames, t0, dropped = 0, time.time(), 0
        except Exception:
            log("reader error:", traceback.format_exc())
        finally:
            self.alive = False
            try:
                self.q.put_nowait((None, False))
            except queue.Full:
                pass

    def sender_loop(self):
        sent = 0
        try:
            while self.alive:
                au, key = self.q.get()
                if au is None:
                    break
                self.send(MSG_VIDEO, struct.pack("<I", 1 if key else 0) + au)
                sent += 1
                if sent == 1:
                    log("first frame sent to client")
        except (ConnectionError, OSError) as e:
            log("send error:", e)
        except Exception:
            log("sender crashed:", traceback.format_exc())
        finally:
            self.alive = False
            try:
                self.sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass

    def input_loop(self):
        inj = self.inj
        while self.alive:
            hdr = recv_exact(self.sock, 5)
            if not hdr:
                break
            mtype, length = struct.unpack("<BI", hdr)
            if length > 65536:
                break
            body = recv_exact(self.sock, length) if length else b""
            if body is None:
                break
            if mtype == MSG_MOUSE_ABS and length >= 4:
                nx, ny = struct.unpack("<HH", body[:4])
                inj.move_abs(nx, ny)
            elif mtype == MSG_MOUSE_REL and length >= 4:
                dx, dy = struct.unpack("<hh", body[:4])
                inj.move_rel(dx, dy)
            elif mtype == MSG_BUTTON and length >= 2:
                inj.button(body[0], body[1] != 0)
            elif mtype == MSG_WHEEL and length >= 4:
                dy, dx = struct.unpack("<hh", body[:4])
                inj.wheel(dy, dx)
            elif mtype == MSG_KEY and length >= 3:
                vk = struct.unpack("<H", body[:2])[0]
                inj.key(vk, body[2] != 0)
            elif mtype == MSG_TEXT:
                inj.text(body.decode("utf-8", errors="replace"))
            elif mtype == MSG_PING:
                self.send(MSG_PONG, body)


# ---------------------------------------------------------------------------
# Discovery + main
# ---------------------------------------------------------------------------


def discovery_loop(cfg):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        s.bind(("", DISCOVERY_PORT))
    except OSError as e:
        log("discovery bind failed:", e)
        return
    name = socket.gethostname()
    while True:
        try:
            data, addr = s.recvfrom(1024)
        except OSError:
            continue
        if data.startswith(DISCOVERY_MAGIC):
            reply = DISCOVERY_REPLY + json.dumps({"name": name, "port": cfg["port"]}).encode()
            try:
                s.sendto(reply, addr)
            except OSError:
                pass


def load_config(path):
    cfg = dict(DEFAULT_CONFIG)
    if path and os.path.exists(path):
        with open(path, "r", encoding="utf-8") as f:
            cfg.update(json.load(f))
    return cfg


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "config.json"))
    args = ap.parse_args()
    cfg = load_config(args.config)

    ffmpeg = find_ffmpeg()
    if not ffmpeg:
        log("ffmpeg.exe not found. Put ffmpeg.exe next to host.py or install it (winget install Gyan.FFmpeg).")
        sys.exit(1)
    encoder = pick_encoder(ffmpeg, cfg["encoder"])
    log(f"ffmpeg: {ffmpeg}  encoder: {encoder}")

    threading.Thread(target=discovery_loop, args=(cfg,), daemon=True).start()

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("", int(cfg["port"])))
    srv.listen(1)
    log(f"listening on tcp {cfg['port']} (discovery udp {DISCOVERY_PORT})")

    current = None
    while True:
        sock, addr = srv.accept()
        log("connection from", addr)
        if current is not None and current.alive:
            log("closing previous session")
            current.alive = False
            try:
                current.sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
        current = Session(sock, addr, cfg, ffmpeg, encoder)
        threading.Thread(target=current.run, daemon=True).start()


if __name__ == "__main__":
    main()
