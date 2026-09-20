"""Regenerate the synthetic HEVC fixture; requires ffmpeg/ffprobe on PATH.

These are development tools only, not Transom runtime dependencies.
The image is FFmpeg's synthetic testsrc2 pattern, not a screen recording.
"""
import json
from pathlib import Path
import struct
import subprocess
import tempfile


def unpack(dump):
    return bytes.fromhex("".join(
        line.split(":", 1)[1].split("  ", 1)[0].replace(" ", "")
        for line in dump.splitlines() if ":" in line
    ))


def framed(payload):
    return struct.pack(">I", len(payload)) + payload


with tempfile.TemporaryDirectory() as scratch:
    movie = str(Path(scratch) / "fixture.mp4")
    subprocess.run([
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i",
        "testsrc2=size=128x96:rate=12", "-frames:v", "12", "-c:v", "libx265",
        "-preset", "ultrafast", "-x265-params",
        "log-level=error:pools=1:bframes=0:keyint=4:min-keyint=4:scenecut=0",
        "-tag:v", "hvc1", "-y", movie,
    ], check=True)
    source = json.loads(subprocess.check_output([
        "ffprobe", "-v", "error", "-show_entries", "stream=extradata",
        "-show_entries", "packet=data,pts_time,flags", "-show_data", "-of", "json", movie,
    ]))
    wire = framed(b"\x01" + unpack(source["streams"][0]["extradata"]))
    for seq, packet in enumerate(source["packets"]):
        header = struct.pack(">QQB", seq, int(float(packet["pts_time"]) * 1e6), "K" in packet["flags"])
        wire += framed(b"\x02" + header + unpack(packet["data"]))
    Path(__file__).with_name("hevc-main.wire").write_bytes(wire)
