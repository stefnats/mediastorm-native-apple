#!/usr/bin/env python3
"""Generate only owned synthetic 60-second bars/tone media using existing system tools."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import struct
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', type=Path, required=True)
    args = parser.parse_args()
    ffmpeg, ffprobe = Path('/usr/bin/ffmpeg'), Path('/usr/bin/ffprobe')
    if not ffmpeg.is_file() or not ffprobe.is_file():
        parser.error('Existing /usr/bin/ffmpeg and ffprobe are required; nothing will be installed')
    directory = args.directory
    if not directory.is_absolute() or directory.exists() or not directory.parent.is_dir():
        parser.error('Use a new absolute directory under the persistent task directory')
    directory.mkdir(mode=0o700)
    media = directory / 'ui-smoke.mp4'
    command = [str(ffmpeg), '-nostdin', '-hide_banner', '-loglevel', 'warning', '-n',
               '-filter_threads', '1', '-f', 'lavfi', '-i', 'testsrc2=size=160x90:rate=10',
               '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000', '-t', '60',
               '-c:v', 'libx264', '-threads', '2', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p',
               '-b:v', '96k', '-maxrate', '128k', '-bufsize', '256k',
               '-c:a', 'aac', '-b:a', '32k', '-ac', '1', '-movflags', '+faststart', str(media)]
    with (directory / 'ffmpeg.log').open('wb') as log:
        subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=120)
    result = subprocess.run([str(ffprobe), '-v', 'error', '-show_format', '-show_streams', '-of', 'json', str(media)],
                            capture_output=True, check=True, timeout=30)
    (directory / 'ffprobe-stderr.log').write_bytes(result.stderr)
    probe = json.loads(result.stdout)
    video = [s for s in probe['streams'] if s['codec_type'] == 'video']
    audio = [s for s in probe['streams'] if s['codec_type'] == 'audio']
    assert len(video) == len(audio) == 1
    assert (video[0]['codec_name'], video[0]['width'], video[0]['height'], video[0]['pix_fmt'], video[0]['r_frame_rate']) == ('h264', 160, 90, 'yuv420p', '10/1')
    assert audio[0]['codec_name'] == 'aac' and audio[0]['channels'] == 1
    duration = float(probe['format']['duration'])
    assert math.isfinite(duration) and 59.5 <= duration <= 60.5
    raw = media.read_bytes()
    assert 0 < len(raw) < 2 * 1024 * 1024, 'Media exceeds strict two-MiB fixture budget; never truncate it'
    atoms, offset = {}, 0
    while offset < len(raw):
        size, kind = struct.unpack('>I4s', raw[offset:offset + 8])
        if size == 1:
            size = struct.unpack('>Q', raw[offset + 8:offset + 16])[0]
        elif size == 0:
            size = len(raw) - offset
        assert size >= 8 and offset + size <= len(raw)
        atoms[kind.decode('ascii')] = offset
        offset += size
    assert offset == len(raw) and atoms['moov'] < atoms['mdat'], 'Actual faststart layout is required'
    receipt = {'scope': 'Owned synthetic bars/test pattern and440Hz tone only, not private or provider media',
               'mediaPath': str(media), 'mediaBytes': len(raw), 'mediaSHA256': hashlib.sha256(raw).hexdigest(),
               'duration': duration, 'ffprobe': probe, 'faststartAtoms': atoms, 'ffmpegCommand': command,
               'tools': {str(tool): hashlib.sha256(tool.read_bytes()).hexdigest() for tool in (ffmpeg, ffprobe)},
               'noTruncationOrDurationRewrite': True, 'playbackOrAppleUIExecuted': False}
    (directory / 'media-evidence.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps({'path': str(media), 'bytes': len(raw), 'duration': duration, 'sha256': receipt['mediaSHA256']}))


if __name__ == '__main__':
    main()
