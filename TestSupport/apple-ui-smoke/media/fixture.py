#!/usr/bin/env python3
"""Loopback-only synthetic Apple playback HTTP draft; no PG, provider or UI authority."""
import argparse
import base64
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import hashlib
import math
from pathlib import Path
import re
import signal
import threading
import time
from urllib.parse import parse_qs, urlsplit

USER, PASSWORD, PIN = 'apple-smoke', 'synthetic-only', '1234'
TOKEN, UNLOCK = 'synthetic-apple-session', 'synthetic-apple-pin'
PROFILES = [{'id': 'open', 'name': 'Synthetic Open', 'hasPin': False, 'pinLength': 0},
            {'id': 'pin', 'name': 'Synthetic PIN', 'hasPin': True, 'pinLength': 4}]
SHELVES = ['watch-together', 'top-ten', 'continue-watching', 'watch-something', 'tonight',
           'my-recommended', 'my-upcoming', 'calendar', 'my-recently-aired', 'watchlist',
           'trending-movies', 'trending-tv', 'streaming-services', 'live-favorites',
           'popular-on-server', 'recently-watched', 'dashboard', 'permanent-prequeue', 'set-aside']
PNG = base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=')


def expiry():
    return (datetime.now(timezone.utc) + timedelta(hours=1)).isoformat().replace('+00:00', 'Z')


def settings():
    return {'display': {'alwaysShowProfileSelector': True}, 'filtering': {'adaptivePlaybackEnabled': False},
            'playback': {'autoPlayTrailersTV': False, 'disablePrequeue': True,
                         'creditsDetectionEnabled': False, 'thumbnails': {'enabled': False}},
            'homeShelves': {'tvTopShelfMode': 'disabled', 'itemCap': 8, 'exploreCardPosition': 'end',
                            'shelves': [{'id': name, 'name': 'Continue Watching' if name == 'continue-watching' else name,
                                         'enabled': name == 'continue-watching', 'order': i}
                                        for i, name in enumerate(SHELVES)]}}


class Fixture(ThreadingHTTPServer):
    daemon_threads = False
    block_on_close = True

    def __init__(self, port, log, media_evidence):
        evidence = json.loads(media_evidence.read_text())
        self.media = (media_evidence.parent / 'ui-smoke.mp4').read_bytes()
        assert 0 < len(self.media) < 2 * 1024 * 1024
        assert hashlib.sha256(self.media).hexdigest() == evidence['mediaSHA256']
        self.duration = float(evidence['ffprobe']['format']['duration'])
        assert math.isfinite(self.duration) and self.duration == evidence['duration'] and 59.5 <= self.duration <= 60.5
        self.audio_index = next(row['index'] for row in evidence['ffprobe']['streams'] if row['codec_type'] == 'audio')
        self.playback_client = None
        super().__init__(('127.0.0.1', port), Handler)
        self.origin = 'http://127.0.0.1:' + str(self.server_port)
        self.log, self.guard = log, threading.Lock()
        self.session = False
        self.pin_unlocked = False
        self.events = []
        self.events_overflow = False

    def record(self, method, path, status):
        # Never log headers, query strings, bodies, session tokens or PIN values.
        with self.guard:
            self.log.write(json.dumps({'method': method, 'path': path, 'status': status}) + '\n')
            self.log.flush()

    def playback_event(self, kind, response_status, response_completed, **fields):
        # Server observations are not proof of decoding or presentation by a player.
        with self.guard:
            if len(self.events) >= 4096:
                self.events_overflow = True
                return
            self.events.append({'sequence': len(self.events) + 1, 'monotonicNanos': time.monotonic_ns(),
                                'kind': kind, 'responseStatus': response_status,
                                'responseCompleted': response_completed,
                                'prequeueId': 'synthetic-playback-1', 'profileId': 'pin',
                                'itemId': 'tmdb:movie:1', 'sourcePath': 'synthetic/ui-smoke.mp4', **fields})

    def title(self, number):
        return {'id': 'tmdb:movie:' + str(number), 'name': 'Synthetic Film ' + str(number),
                'mediaType': 'movie', 'tmdbId': number, 'year': 2020, 'status': 'released',
                'runtimeMinutes': 1 if number == 1 else 90, 'overview': 'Synthetic UI-only catalogue item.',
                'poster': {'url': self.origin + '/art.png'}, 'backdrop': {'url': self.origin + '/art.png'}}


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.0'

    def setup(self):
        super().setup()
        self.connection.settimeout(3)

    def log_message(self, *args):
        pass

    def reply(self, status, value):
        self.server.record(self.command, self.safe_path, status)
        raw = value if isinstance(value, bytes) else json.dumps(value).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'image/png' if isinstance(value, bytes) else 'application/json')
        self.send_header('Content-Length', str(len(raw)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        completed = False
        try:
            if self.command != 'HEAD':
                self.wfile.write(raw)
            completed = True
        except (BrokenPipeError, ConnectionResetError):
            pass
        if status == 200:
            if self.safe_path == '/api/playback/prequeue':
                self.server.playback_event('admission', status, completed)
            elif self.safe_path == '/api/playback/prequeue/synthetic-playback-1':
                self.server.playback_event('status', status, completed, duration=self.server.duration)
            elif self.safe_path == '/api/users/pin/history/progress':
                self.server.playback_event('progress', status, completed, **self.progress_witness)

    def do_GET(self):
        self.handle_route()

    def do_POST(self):
        self.handle_route()

    def do_PUT(self):
        self.handle_route()

    def do_DELETE(self):
        self.handle_route()

    def do_OPTIONS(self):
        self.handle_route()

    do_HEAD = do_OPTIONS
    do_PATCH = do_OPTIONS
    do_TRACE = do_OPTIONS
    do_CONNECT = do_OPTIONS

    def handle_route(self):
        self.safe_path = '/invalid-request-target'
        try:
            parsed = urlsplit(self.path)
            if parsed.scheme or parsed.netloc or (not re.fullmatch(r'/[A-Za-z0-9_./:-]*', parsed.path)
                    and parsed.path != '/api/users/pin/preferences/content/tmdb%3Amovie%3A1'):
                return self.reply(400, {'error': 'Invalid fixture path'})
            self.safe_path = parsed.path
            host = self.server.origin.removeprefix('http://')
            if self.headers.get_all('Host') != [host] or (self.headers.get_all('Origin', []) not in ([], [self.server.origin])):
                return self.reply(403, {'error': 'Unexpected fixture origin'})
            if self.headers.get('Transfer-Encoding'):
                return self.reply(400, {'error': 'Unsupported fixture framing'})
            lengths = self.headers.get_all('Content-Length', [])
            if len(lengths) > 1:
                return self.reply(400, {'error': 'Ambiguous fixture body'})
            size = int(lengths[0]) if lengths else 0
            if not 0 <= size <= 65536:
                return self.reply(413, {'error': 'Fixture body too large'})
            raw = self.rfile.read(size)
            if self.command == 'GET' and raw:
                return self.reply(400, {'error': 'GET body unsupported'})
            body = json.loads(raw) if raw else {}
            if not isinstance(body, dict):
                return self.reply(400, {'error': 'Object body required'})
            query = parse_qs(parsed.query, keep_blank_values=True, max_num_fields=32)
            if any(len(values) != 1 for values in query.values()):
                return self.reply(400, {'error': 'Duplicate query field'})
            return self.dispatch(parsed.path, query, body)
        except (ValueError, TimeoutError):
            self.reply(400, {'error': 'Invalid fixture request'})

    def original_job(self):
        with self.server.guard:
            return self.server.playback_client is not None and self.headers.get('X-Client-ID') == self.server.playback_client

    def stream(self, query):
        allowed = {'path', 'profileId', 'profileName', 'profileUnlock', 'transmux', 'mediaType',
                   'titleId', 'tmdb', 'year', 'posterUrl', 'itemId', 'movieName', 'title'}
        one = lambda key: query.get(key, [''])[0]
        if self.command not in ('GET', 'HEAD'):
            return self.reply(405, {'error': 'Stream supports GET and HEAD only'})
        if set(query) - allowed or one('path') != 'synthetic/ui-smoke.mp4' or one('profileId') != 'pin':
            return self.reply(400, {'error': 'Only the owned synthetic movie/profile stream is supported'})
        if not self.original_job():
            return self.reply(403, {'error': 'Original synthetic prepared client required'})
        with self.server.guard:
            unlocked = self.server.pin_unlocked and (self.headers.get('X-Profile-Unlock') == UNLOCK or one('profileUnlock') == UNLOCK)
        if not unlocked:
            return self.reply(403, {'error': 'Original synthetic PIN required'})
        expected = {'transmux': '0', 'mediaType': 'movie', 'titleId': 'tmdb:movie:1', 'tmdb': '1',
                    'year': '2020', 'itemId': 'tmdb:movie:1', 'movieName': 'Synthetic Film 1',
                    'title': 'Synthetic Film 1', 'profileName': 'Synthetic PIN', 'posterUrl': self.server.origin + '/art.png'}
        if any(key in query and one(key) != value for key, value in expected.items()):
            return self.reply(400, {'error': 'Mismatched original synthetic stream metadata'})
        size = len(self.server.media)
        start, end, status = 0, size - 1, 200
        ranges = self.headers.get_all('Range', [])
        if ranges:
            match = re.fullmatch(r'bytes=([0-9]{0,20})-([0-9]{0,20})', ranges[0]) if len(ranges) == 1 else None
            valid = match is not None and bool(match[1] or match[2])
            if valid:
                if match[1]:
                    start = int(match[1]); end = min(int(match[2]), size - 1) if match[2] else size - 1
                else:
                    count = int(match[2]); start, end = max(0, size - count), size - 1
                    valid = count > 0
                valid = valid and 0 <= start <= end < size
            if not valid:
                self.server.record(self.command, self.safe_path, 416)
                self.send_response(416)
                self.send_header('Content-Range', 'bytes */' + str(size))
                self.send_header('Content-Type', 'video/mp4')
                self.send_header('Accept-Ranges', 'bytes')
                self.send_header('Content-Length', '0')
                self.end_headers()
                return
            status = 206
        self.server.record(self.command, self.safe_path, status)
        self.send_response(status)
        self.send_header('Content-Type', 'video/mp4')
        self.send_header('Accept-Ranges', 'bytes')
        self.send_header('Content-Length', str(end - start + 1))
        self.send_header('Cache-Control', 'no-store')
        if status == 206:
            self.send_header('Content-Range', 'bytes ' + str(start) + '-' + str(end) + '/' + str(size))
        self.end_headers()
        completed = False
        try:
            if self.command != 'HEAD':
                self.wfile.write(self.server.media[start:end + 1])
            completed = True
        except (BrokenPipeError, ConnectionResetError):
            pass
        self.server.playback_event('media', status, completed, method=self.command,
                                   rangeStart=start, rangeEnd=end, totalBytes=size,
                                   bodyBytesWritten=(0 if self.command == 'HEAD' else end - start + 1) if completed else None)

    def progress(self, body):
        allowed = {'mediaType', 'position', 'duration', 'timestamp', 'isPaused', 'playbackEnded',
                   'isBuffering', 'sourcePath', 'externalIds', 'itemId', 'year', 'movieName',
                   'posterUrl', 'bufferAheadSeconds', 'requiredBandwidthMbps'}
        required = {'mediaType', 'position', 'duration', 'timestamp', 'isPaused', 'playbackEnded',
                    'sourcePath', 'externalIds', 'itemId'}
        finite = lambda v: not isinstance(v, bool) and isinstance(v, (int, float)) and math.isfinite(v)
        ids = body.get('externalIds')
        valid = not (set(body) - allowed) and required <= set(body) and self.original_job()
        valid = valid and body.get('mediaType') == 'movie' and body.get('itemId') == 'tmdb:movie:1'
        valid = valid and body.get('sourcePath') == 'synthetic/ui-smoke.mp4'
        valid = valid and isinstance(ids, dict) and ids.get('titleId') == 'tmdb:movie:1' and not (set(ids) - {'titleId', 'tmdb'})
        valid = valid and (not isinstance(ids, dict) or 'tmdb' not in ids or ids['tmdb'] == '1')
        valid = valid and finite(body.get('position')) and finite(body.get('duration'))
        if valid:
            valid = 0 <= body['position'] <= self.server.duration + 0.25 and abs(body['duration'] - self.server.duration) <= 0.25
        valid = valid and type(body.get('isPaused')) is bool and type(body.get('playbackEnded')) is bool
        for key in ('isBuffering',):
            valid = valid and (key not in body or type(body[key]) is bool)
        for key in ('bufferAheadSeconds', 'requiredBandwidthMbps'):
            valid = valid and (key not in body or finite(body[key]) and body[key] >= 0)
        valid = valid and ('movieName' not in body or body['movieName'] == 'Synthetic Film 1') and ('year' not in body or body['year'] == 2020)
        valid = valid and ('posterUrl' not in body or body['posterUrl'] == self.server.origin + '/art.png')
        try:
            stamp = body.get('timestamp')
            valid = valid and isinstance(stamp, str) and len(stamp) <= 64 and datetime.fromisoformat(stamp.replace('Z', '+00:00')).tzinfo is not None
        except (ValueError, TypeError):
            valid = False
        if not valid:
            return self.reply(400, {'error': 'Invalid original synthetic movie progress DTO'})
        witness = {'event': 'synthetic-progress', 'itemId': 'tmdb:movie:1', 'sourcePath': 'synthetic/ui-smoke.mp4',
                   'position': body['position'], 'duration': body['duration'],
                   'paused': body['isPaused'], 'ended': body['playbackEnded']}
        self.progress_witness = {key: witness[key] for key in ('position', 'duration', 'paused', 'ended')}
        with self.server.guard:
            self.server.log.write(json.dumps(witness, allow_nan=False) + '\n')
            self.server.log.flush()
        return self.reply(200, {'migrationRequested': False})

    def dispatch(self, path, query, body):
        s, method = self.server, self.command
        def allowed(verb, keys=()):
            if method != verb:
                self.reply(405, {'error': 'Method unsupported for fixture route'})
                return False
            if set(query) - set(keys):
                self.reply(400, {'error': 'Unexpected fixture query'})
                return False
            return True

        if path == '/__fixture/playback-evidence':
            if not allowed('GET', ('after',)):
                return
            cursor = query.get('after', ['0'])[0]
            if not re.fullmatch(r'0|[1-9][0-9]{0,3}', cursor):
                return self.reply(400, {'error': 'Invalid bounded evidence cursor'})
            after = int(cursor)
            with s.guard:
                if after > len(s.events):
                    result = None
                else:
                    result = {'schemaVersion': 1, 'events': list(s.events[after:]),
                              'nextSequence': len(s.events), 'overflow': s.events_overflow,
                              'mediaSHA256': hashlib.sha256(s.media).hexdigest(),
                              'mediaBytes': len(s.media), 'duration': s.duration}
            if result is None:
                return self.reply(400, {'error': 'Evidence cursor exceeds observed sequence'})
            return self.reply(200, result)
        if path in ('/health', '/api/version', '/api/branding', '/art.png'):
            if not allowed('GET'):
                return
            values = {'/health': {'status': 'ok'}, '/api/version': {'version': 'synthetic-apple-ui', 'buildId': 'ui-only'},
                      '/api/branding': {'branding': {}}, '/art.png': PNG}
            return self.reply(200, values[path])
        if path == '/api/auth/login':
            if not allowed('POST'):
                return
            if set(body) - {'username', 'password', 'rememberMe'} or body.get('username') != USER or body.get('password') != PASSWORD:
                return self.reply(401, {'error': 'Synthetic credentials required'})
            with s.guard:
                s.session, s.pin_unlocked = True, False
                s.playback_client = None
            return self.reply(200, {'token': TOKEN, 'accountId': 'synthetic-account', 'username': USER,
                                    'isMaster': False, 'expiresAt': expiry()})
        with s.guard:
            authorized = s.session and self.headers.get('Authorization') == 'Bearer ' + TOKEN
        if not authorized:
            return self.reply(401, {'error': 'Synthetic session required'})
        if path == '/api/auth/logout':
            if not allowed('POST'):
                return
            with s.guard:
                s.session, s.pin_unlocked = False, False
                s.playback_client = None
            return self.reply(204, b'')
        if path == '/api/users':
            if allowed('GET'):
                return self.reply(200, PROFILES)
            return
        match = re.fullmatch(r'/api/users/(open|pin)/(.+)', path)
        profile, suffix = match.groups() if match else (None, None)
        if suffix == 'pin/verify':
            if not allowed('POST'):
                return
            if profile != 'pin' or set(body) != {'pin'} or body.get('pin') != PIN:
                return self.reply(401, {'valid': False, 'code': 'pin_invalid', 'error': 'Wrong synthetic PIN'})
            with s.guard:
                s.pin_unlocked = True
            return self.reply(200, {'valid': True, 'unlockToken': UNLOCK, 'expiresAt': expiry()})
        selected = profile or query.get('userId', [''])[0] or body.get('userId')
        if selected and selected not in ('open', 'pin'):
            return self.reply(404, {'error': 'Unknown synthetic profile'})
        if selected == 'pin':
            with s.guard:
                unlocked = s.pin_unlocked and self.headers.get('X-Profile-Unlock') == UNLOCK
            if not unlocked:
                return self.reply(403, {'code': 'profile_locked', 'profileId': 'pin', 'error': 'Synthetic PIN required'})
        if path == '/api/video/stream':
            return self.stream(query)
        if path == '/api/playback/prequeue':
            if not allowed('POST'):
                return
            fields = {'titleId', 'titleName', 'mediaType', 'userId', 'clientId', 'reason', 'skipHLS',
                      'tmdbId', 'year', 'startOffset', 'automaticLibrarySelection'}
            valid = not (set(body) - fields) and body.get('titleId') == 'tmdb:movie:1' and body.get('mediaType') == 'movie' and body.get('userId') == 'pin'
            client = body.get('clientId')
            valid = valid and isinstance(client, str) and 1 <= len(client) <= 128 and client == self.headers.get('X-Client-ID')
            valid = valid and body.get('titleName') == 'Synthetic Film 1' and body.get('reason') == 'details' and body.get('skipHLS') is True
            valid = valid and ('tmdbId' not in body or body['tmdbId'] in ('1', 1)) and ('year' not in body or body['year'] == 2020)
            valid = valid and ('automaticLibrarySelection' not in body or type(body['automaticLibrarySelection']) is bool)
            if 'startOffset' in body:
                value = body['startOffset']
                valid = valid and not isinstance(value, bool) and isinstance(value, (int, float)) and math.isfinite(value) and 0 <= value < s.duration
            if not valid:
                return self.reply(400, {'error': 'Only the original synthetic movie1/PIN/client prequeue is supported'})
            with s.guard:
                s.playback_client = client
            return self.reply(200, {'prequeueId': 'synthetic-playback-1', 'status': 'ready'})
        if path == '/api/playback/prequeue/synthetic-playback-1':
            if not allowed('GET'):
                return
            if not self.original_job():
                return self.reply(404, {'error': 'No original synthetic prepared playback'})
            return self.reply(200, {'prequeueId': 'synthetic-playback-1', 'status': 'ready', 'streamPath': 'synthetic/ui-smoke.mp4',
                                    'displayName': 'Owned synthetic sixty-second test pattern', 'duration': s.duration,
                                    'selectedAudioTrack': s.audio_index, 'selectedSubtitleTrack': -1,
                                    'audioTracks': [{'index': s.audio_index, 'codec': 'aac', 'language': 'und'}]})
        if path in ('/api/users/pin/preferences/content/tmdb%3Amovie%3A1', '/api/users/pin/preferences/content/tmdb:movie:1'):
            if allowed('GET', ('profileId',)):
                if query.get('profileId', ['pin']) != ['pin']:
                    return self.reply(400, {'error': 'Only the original synthetic preference profile is supported'})
                return self.reply(200, {'contentId': 'tmdb:movie:1', 'preferLocalFiles': False, 'localSourcePreferenceSupported': False})
            return
        if suffix == 'history/progress' and profile == 'pin':
            if allowed('POST'):
                return self.progress(body)
            return
        if path == '/api/video/segments':
            if not allowed('POST'):
                return
            if not self.original_job() or set(body) != {'duration', 'chapters'} or body['chapters'] != [] or not isinstance(body['duration'], (int, float)) or isinstance(body['duration'], bool) or not math.isfinite(body['duration']) or abs(body['duration'] - s.duration) > 0.25:
                return self.reply(400, {'error': 'Only the observed synthetic duration/empty-chapter segment DTO is supported'})
            return self.reply(200, {'segments': []})
        if path == '/api/settings' or suffix == 'settings':
            if allowed('GET'):
                return self.reply(200, settings())
            return
        if re.fullmatch(r'/api/clients/[A-Za-z0-9_-]{1,128}/settings', path):
            if allowed('GET', ('userId',)):
                return self.reply(200, {'homeShelfFocusModel': 'fixed'})
            return
        if path in ('/api/clients/register', '/api/logs/frontend'):
            if allowed('POST'):
                return self.reply(200, {'accepted': True})
            return
        if suffix == 'home/manifest':
            if allowed('GET'):
                return self.reply(200, {'revision': 'synthetic-fixed-1'})
            return
        if suffix in ('custom-lists', 'hidden-items', 'history/continue/hidden', 'watchlist', 'history/watched'):
            if allowed('GET'):
                return self.reply(200, [])
            return
        if suffix == 'history/continue':
            if allowed('GET'):
                return self.reply(200, [{'seriesId': 'tmdb:movie:' + str(i), 'seriesTitle': 'Synthetic Film ' + str(i),
                                         'year': 2020, 'posterUrl': s.origin + '/art.png', 'backdropUrl': s.origin + '/art.png',
                                         'externalIds': {'tmdb': str(i)}, 'percentWatched': 10, 'status': 'released'} for i in range(1, 7)])
            return
        if suffix == 'details-bundle' or path == '/api/metadata/movies/details':
            if not allowed('GET', ('type', 'titleId', 'name', 'tmdbId', 'imdbId', 'year', 'userId')):
                return
            title_id = query.get('titleId', [''])[0]
            raw_id = query.get('tmdbId', [title_id.rsplit(':', 1)[-1]])[0]
            if raw_id not in {str(i) for i in range(1, 7)}:
                return self.reply(404, {'error': 'Unknown synthetic title'})
            title = s.title(int(raw_id))
            if suffix:
                result = {'movieDetails': title, 'inWatchlist': False, 'watched': False, 'similar': []}
                if raw_id == '1':
                    result['resume'] = {'position': 0, 'duration': s.duration, 'percent': 0, 'eligible': False}
                return self.reply(200, result)
            return self.reply(200, title)
        return self.reply(404, {'error': 'No such synthetic route'})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--media-evidence', type=Path, required=True)
    parser.add_argument('--port', type=int, default=8765)
    parser.add_argument('--log', type=Path, required=True)
    parser.add_argument('--ready-file', type=Path, required=True)
    parser.add_argument('--duration-seconds', type=int, default=1800)
    args = parser.parse_args()
    if not 0 <= args.port <= 65535 or not 1 <= args.duration_seconds <= 3600:
        parser.error('Invalid port or bounded duration')
    for path in (args.log, args.ready_file):
        if not path.is_absolute() or path.exists() or not path.parent.is_dir():
            parser.error('Use new absolute output files in an existing persistent task directory')
    stop = threading.Event()
    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, lambda *_: stop.set())
    with args.log.open('x', encoding='utf-8') as log:
        server = Fixture(args.port, log, args.media_evidence)
        worker = threading.Thread(target=server.serve_forever, kwargs={'poll_interval': 0.1})
        worker.start()
        try:
            ready = {'origin': server.origin, 'scope': 'NONDISPATCHABLE-synthetic-media-HTTP-draft', 'upstreamAccess': False}
            args.ready_file.write_text(json.dumps(ready) + '\n')
            print(json.dumps(ready), flush=True)
            stop.wait(args.duration_seconds)
        finally:
            server.shutdown()
            server.server_close()
            worker.join()
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
