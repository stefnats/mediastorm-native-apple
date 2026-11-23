#!/usr/bin/env python3
"""Loopback-only synthetic Apple onboarding/Home fixture; not PG or media authority."""
import argparse
import base64
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import re
import signal
import threading
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
            'playback': {'autoPlayTrailersTV': False, 'disablePrequeue': True},
            'homeShelves': {'tvTopShelfMode': 'disabled', 'itemCap': 8, 'exploreCardPosition': 'end',
                            'shelves': [{'id': name, 'name': 'Continue Watching' if name == 'continue-watching' else name,
                                         'enabled': name == 'continue-watching', 'order': i}
                                        for i, name in enumerate(SHELVES)]}}


class Fixture(ThreadingHTTPServer):
    daemon_threads = False
    block_on_close = True

    def __init__(self, port, log):
        super().__init__(('127.0.0.1', port), Handler)
        self.origin = 'http://127.0.0.1:' + str(self.server_port)
        self.log, self.guard = log, threading.Lock()
        self.session = False
        self.pin_unlocked = False

    def record(self, method, path, status):
        # Never log headers, query strings, bodies, session tokens or PIN values.
        with self.guard:
            self.log.write(json.dumps({'method': method, 'path': path, 'status': status}) + '\n')
            self.log.flush()

    def title(self, number):
        return {'id': 'tmdb:movie:' + str(number), 'name': 'Synthetic Film ' + str(number),
                'mediaType': 'movie', 'tmdbId': number, 'year': 2020, 'status': 'released',
                'runtimeMinutes': 90, 'overview': 'Synthetic UI-only catalogue item.',
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
        try:
            if self.command != 'HEAD':
                self.wfile.write(raw)
        except (BrokenPipeError, ConnectionResetError):
            pass

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
            if parsed.scheme or parsed.netloc or not re.fullmatch(r'/[A-Za-z0-9_./:-]*', parsed.path):
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
            return self.reply(200, {'movieDetails': title, 'inWatchlist': False, 'watched': False, 'similar': []} if suffix else title)
        return self.reply(404, {'error': 'No such synthetic route'})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
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
        server = Fixture(args.port, log)
        worker = threading.Thread(target=server.serve_forever, kwargs={'poll_interval': 0.1})
        worker.start()
        try:
            ready = {'origin': server.origin, 'scope': 'synthetic-ui-only', 'upstreamAccess': False}
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
