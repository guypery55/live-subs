#!/usr/bin/env python3
"""Step 0: check Soniox's Hebrew -> English quality and delay on a real clip, before the Mac app.

Usage:
    export SONIOX_API_KEY=...            # never pass the key on the command line
    python3 -I spike/soniox_stream.py clip.wav [--fast] [--hebrew]

Input: a WAV file (16-bit PCM, any sample rate / channels). With ffmpeg installed
(`sudo apt install ffmpeg`), any audio or video file works.

The audio is streamed at real-time pace, like the app does, and each finished English line is
printed with the clip time and how far it trailed the speech. --fast streams as fast as
possible (no delay numbers). --hebrew also prints the Hebrew transcript.

Standard library only (no pip needed): includes a tiny WebSocket client.
"""
import base64
import json
import os
import shutil
import socket
import ssl
import struct
import subprocess
import sys
import threading
import time
import wave

HOST = "stt-rt.soniox.com"
PATH = "/transcribe-websocket"
MODEL = "stt-rt-v6"
PRICE_PER_HOUR = 0.12  # Soniox real-time list price (soniox.com/pricing), for the estimate only


class WebSocket:
    """Minimal RFC 6455 client: enough for one Soniox stream."""

    def __init__(self, host, path, headers):
        raw = socket.create_connection((host, 443), timeout=30)
        self.sock = ssl.create_default_context().wrap_socket(raw, server_hostname=host)
        key = base64.b64encode(os.urandom(16)).decode()
        lines = [f"GET {path} HTTP/1.1", f"Host: {host}", "Upgrade: websocket", "Connection: Upgrade",
                 f"Sec-WebSocket-Key: {key}", "Sec-WebSocket-Version: 13"]
        lines += [f"{k}: {v}" for k, v in headers.items()]
        self.sock.sendall(("\r\n".join(lines) + "\r\n\r\n").encode())
        response = b""
        while b"\r\n\r\n" not in response:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise ConnectionError("connection closed during handshake")
            response += chunk
        head, self.buf = response.split(b"\r\n\r\n", 1)
        status = head.split(b"\r\n")[0].decode(errors="replace")
        if " 101 " not in status:
            raise ConnectionError(f"handshake failed: {status} {self.buf[:300].decode(errors='replace')}")
        self.sock.settimeout(None)
        self.lock = threading.Lock()

    def _send(self, payload, opcode):
        if isinstance(payload, str):
            payload = payload.encode()
        n = len(payload)
        header = bytes([0x80 | opcode])
        if n < 126:
            header += bytes([0x80 | n])
        elif n < 65536:
            header += bytes([0x80 | 126]) + struct.pack(">H", n)
        else:
            header += bytes([0x80 | 127]) + struct.pack(">Q", n)
        mask = os.urandom(4)
        repeated = (mask * (n // 4 + 1))[:n]
        masked = (int.from_bytes(payload, "big") ^ int.from_bytes(repeated, "big")).to_bytes(n, "big")
        with self.lock:
            self.sock.sendall(header + mask + masked)

    def send_text(self, text):
        self._send(text, 0x1)

    def send_binary(self, data):
        self._send(data, 0x2)

    def _read(self, n):
        while len(self.buf) < n:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise ConnectionError("connection closed")
            self.buf += chunk
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def recv(self):
        """Next text/binary message as str, or None when the server closes the stream."""
        message = b""
        while True:
            b1, b2 = self._read(2)
            fin, opcode, n = b1 & 0x80, b1 & 0x0F, b2 & 0x7F
            if n == 126:
                n = struct.unpack(">H", self._read(2))[0]
            elif n == 127:
                n = struct.unpack(">Q", self._read(8))[0]
            if b2 & 0x80:
                self._read(4)  # servers don't mask; skip if one does
            data = self._read(n)
            if opcode == 0x8:
                return None
            if opcode == 0x9:
                self._send(data, 0xA)
                continue
            if opcode == 0xA:
                continue
            message += data
            if fin:
                return message.decode("utf-8", "replace")


def open_audio(path):
    """Returns (sample_rate, channels, iterator of (pcm_bytes, seconds))."""
    if shutil.which("ffmpeg"):
        proc = subprocess.Popen(["ffmpeg", "-v", "error", "-i", path, "-f", "s16le", "-ac", "1", "-ar", "16000", "-"],
                                stdout=subprocess.PIPE)

        def chunks():
            while True:
                data = proc.stdout.read(3200)  # 100 ms
                if not data:
                    return
                yield data, len(data) / 32000

        return 16000, 1, chunks()

    if not path.lower().endswith(".wav"):
        sys.exit("Without ffmpeg only .wav files work. Install it with: sudo apt install ffmpeg")
    w = wave.open(path, "rb")
    if w.getsampwidth() != 2:
        sys.exit("The WAV must be 16-bit PCM (or install ffmpeg to convert automatically).")
    rate, channels = w.getframerate(), w.getnchannels()

    def chunks():
        frames = max(1, rate // 10)
        while True:
            data = w.readframes(frames)
            if not data:
                return
            yield data, len(data) / (2 * channels * rate)

    return rate, channels, chunks()


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    fast, show_hebrew = "--fast" in sys.argv, "--hebrew" in sys.argv
    if len(args) != 1:
        sys.exit(__doc__)
    key = os.environ.get("SONIOX_API_KEY", "").strip()
    if not key:
        sys.exit("Set SONIOX_API_KEY first (export SONIOX_API_KEY=...).")

    rate, channels, chunks = open_audio(args[0])
    ws = WebSocket(HOST, PATH, {"Authorization": f"Bearer {key}"})
    ws.send_text(json.dumps({
        "model": MODEL,
        "audio_format": "pcm_s16le",
        "sample_rate": rate,
        "num_channels": channels,
        "language_hints": ["he"],
        "enable_endpoint_detection": True,
        "translation": {"type": "one_way", "target_language": "en"},
    }))

    start = time.monotonic()
    sent = {"seconds": 0.0}

    def sender():
        try:
            for data, seconds in chunks:
                ws.send_binary(data)
                sent["seconds"] += seconds
                if not fast:
                    wait = start + sent["seconds"] - time.monotonic()
                    if wait > 0:
                        time.sleep(wait)
            ws.send_text("")  # end of audio
        except (ConnectionError, OSError) as e:
            print(f"\n[send stopped: {e}]", file=sys.stderr)

    threading.Thread(target=sender, daemon=True).start()

    english, hebrew = "", ""
    hebrew_end_ms = 0.0
    delays = []

    def flush():
        nonlocal english, hebrew
        if english.strip() or hebrew.strip():
            elapsed = time.monotonic() - start
            clip_time = hebrew_end_ms / 1000
            stamp = f"[{int(clip_time // 60):02d}:{clip_time % 60:04.1f}"
            if not fast and english.strip():
                delay = max(0.0, elapsed - clip_time)
                delays.append(delay)
                stamp += f" +{delay:.1f}s"
            stamp += "]"
            if show_hebrew and hebrew.strip():
                print(f"{stamp} HE: {hebrew.strip()}")
            if english.strip():
                print(f"{stamp} EN: {english.strip()}", flush=True)
        english, hebrew = "", ""

    while True:
        msg = ws.recv()
        if msg is None:
            break
        r = json.loads(msg)
        if r.get("error_code") or r.get("error_type"):
            sys.exit(f"Soniox error {r.get('error_code')} {r.get('error_type')}: {r.get('error_message')}")
        for t in r.get("tokens", []):
            if not t.get("is_final"):
                continue
            text, status = t.get("text", ""), t.get("translation_status")
            if text in ("<end>", "<fin>"):
                flush()
            elif status == "translation" or (status in (None, "none") and t.get("language") == "en"):
                english += text
                if english.rstrip().endswith((".", "?", "!")) and len(english) > 40:
                    flush()
            else:
                hebrew += text
                if t.get("end_ms"):
                    hebrew_end_ms = t["end_ms"]
        if r.get("finished"):
            break
    flush()

    total = sent["seconds"]
    print(f"\nAudio: {total:.0f} s, estimated cost ${total / 3600 * PRICE_PER_HOUR:.4f}")
    if delays:
        delays.sort()
        print(f"English delay behind speech: median {delays[len(delays) // 2]:.1f} s, worst {delays[-1]:.1f} s")


if __name__ == "__main__":
    main()
