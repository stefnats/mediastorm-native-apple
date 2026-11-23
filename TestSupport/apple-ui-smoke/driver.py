#!/usr/bin/env python3
"""Unexecuted iPhone UI-smoke controller for the original opt-in XCTest HTTP driver."""
import argparse
from datetime import datetime, timezone
import hashlib
import http.client
import json
from pathlib import Path
import time
import traceback
from urllib.parse import urlencode


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--driver-port', type=int, default=7791)
    parser.add_argument('--fixture-port', type=int, default=8765)
    parser.add_argument('--fixture-log', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--owned-driver', action='store_true', help='Confirm this is your dedicated MobileDriverUITests instance; it will receive /quit even on failure')
    args = parser.parse_args()
    if not args.owned_driver or not (1 <= args.driver_port <= 65535 and 1 <= args.fixture_port <= 65535):
        parser.error('Explicit dedicated driver ownership and valid loopback ports are required')
    if not args.output.is_absolute() or args.output.exists() or not args.output.parent.is_dir():
        parser.error('Use a new absolute output directory under the prepared persistent station results directory')
    if not args.fixture_log.is_absolute() or not args.fixture_log.is_file():
        parser.error('The local synthetic fixture request log must already exist')
    args.output.mkdir(mode=0o700)
    outcome = {'scope': 'iPhone simulator onboarding/PIN/Home UI only', 'appleUIExecuted': False,
               'passed': False, 'steps': [], 'cleanupErrors': [], 'driverQuitAcknowledged': False,
               'xcodebuildProcessJoined': False, 'operatorMustJoinOriginalXcodebuild': True}
    connected = False
    button_type = None

    def call(endpoint, query=None):
        connection = http.client.HTTPConnection('127.0.0.1', args.driver_port, timeout=25)
        try:
            target = endpoint + ('?' + urlencode(query) if query else '')
            connection.request('GET', target)
            reply = connection.getresponse()
            data = reply.read()
            if reply.status != 200:
                raise RuntimeError(endpoint + ': HTTP ' + str(reply.status) + ' ' + data.decode(errors='replace')[:300])
            if reply.getheader('Content-Type', '').startswith('application/json'):
                return json.loads(data)
            return data
        finally:
            connection.close()

    def wait(label):
        call('/wait', {'q': label, 'timeout': '15'})

    def checkpoint(name):
        tree = call('/tree')
        shot = call('/shot')
        if not isinstance(tree, bytes) or not isinstance(shot, bytes) or not shot.startswith(b'\x89PNG\r\n\x1a\n'):
            raise RuntimeError('Driver returned invalid tree or screenshot')
        (args.output / (name + '-tree.txt')).write_bytes(tree)
        (args.output / (name + '.png')).write_bytes(shot)
        outcome['steps'].append({'name': name, 'observedAtUTC': datetime.now(timezone.utc).isoformat(),
                                 'treeSHA256': hashlib.sha256(tree).hexdigest(), 'pngSHA256': hashlib.sha256(shot).hexdigest()})

    def find(label, button=False, hittable=True):
        result = call('/find', {'q': label, 'limit': '100'})
        if not isinstance(result, dict):
            raise RuntimeError('Expected original mobile /find JSON')
        matches = [item for item in result.get('items', [])
                   if label in (item.get('label'), item.get('identifier'))
                   and (not button or item.get('type') == button_type)
                   and (not hittable or item.get('hittable') is True)]
        if len(matches) != 1:
            raise RuntimeError('Expected one current visible element for ' + label + '; found ' + str(len(matches)))
        return matches[0]

    def tap_item(item):
        x, y, width, height = item.get('frame', [])
        if width <= 0 or height <= 0:
            raise RuntimeError('Element has no usable actual frame')
        call('/tap', {'x': str(x + width / 2), 'y': str(y + height / 2)})

    def tap(label):
        tap_item(find(label, button=True))

    def enter(label, value):
        # Only public synthetic fixture values are ever typed by this controller.
        tap_item(find(label))
        call('/type', {'text': value})

    def rows():
        data = args.fixture_log.read_text()
        return [json.loads(line) for line in data.splitlines() if line]

    initial_requests = 0

    def require_request(method, path, status, after):
        deadline = time.monotonic() + 5
        while True:
            current = rows()
            if any(row == {'method': method, 'path': path, 'status': status} for row in current[after:]):
                return
            if time.monotonic() >= deadline:
                raise RuntimeError('Actual UI did not cause expected fixture request: ' + method + ' ' + path + ' ' + str(status))
            time.sleep(0.1)

    try:
        if call('/ping').strip() != b'ok':
            raise RuntimeError('Original driver did not answer ping')
        connected = True
        initial_requests = len(rows())
        # Reset only this dedicated simulator app; never select a live account/server.
        call('/launch', {'args': '-StrmrResetSession 1 -AppleLanguages (en) -AppleLocale en_US'})
        outcome['appleUIExecuted'] = True
        wait('Connect to Your Server')
        checkpoint('01-reset-server')
        connect = find('Connect', hittable=False)
        button_type = connect['type']  # Learn from an actual unambiguous button, never invent XCTest numeric types.
        fields = []
        for label in ('192.168.1.10 or media.example.com', 'Server Address'):
            try:
                item = find(label)
                if item['type'] != button_type:
                    fields.append(item)
                    break
            except RuntimeError:
                continue
        if not fields:
            raise RuntimeError('No unique actual server address field; inspect saved tree')
        tap_item(fields[0])
        call('/type', {'text': 'http://127.0.0.1:' + str(args.fixture_port) + '\n'})
        # MobileServerForm.onSubmit(connect) is the actual Go/return action.
        wait('Username')
        require_request('GET', '/health', 200, initial_requests)
        checkpoint('02-login')
        enter('Username', 'apple-smoke\n')  # MobileLoginForm advances to Password on submit.
        enter('Password', 'synthetic-only\n')  # Actual SecureField.onSubmit(signIn).
        wait("Who's Watching?")
        require_request('POST', '/api/auth/login', 200, initial_requests)
        require_request('GET', '/api/users', 200, initial_requests)
        checkpoint('03-profiles')
        tap('Synthetic PIN')
        wait('Enter PIN for Synthetic PIN')
        checkpoint('04-pin-prompt')
        before_bad = len(rows())
        for digit in '9999':
            tap(digit)
        wait('Incorrect PIN. Try again.')
        require_request('POST', '/api/users/pin/pin/verify', 401, before_bad)
        checkpoint('05-bad-pin')
        before_good = len(rows())
        for digit in '1234':
            tap(digit)
        wait('Continue Watching')
        require_request('POST', '/api/users/pin/pin/verify', 200, before_good)
        require_request('GET', '/api/users/pin/settings', 200, before_good)
        require_request('GET', '/api/users/pin/history/continue', 200, before_good)
        # Require a rendered card, not merely the Home heading or a successful wire response.
        deadline = time.monotonic() + 15
        while True:
            found = call('/find', {'q': 'Synthetic Film 1', 'limit': '100'})
            cards = [item for item in found.get('items', [])
                     if item.get('label', '').startswith('Synthetic Film 1')
                     and item.get('type') == button_type and item.get('hittable') is True]
            if cards:
                break  # Mobile cards may append subtitle text to their accessibility label.
            if time.monotonic() >= deadline:
                raise RuntimeError('No actual visible Synthetic Film 1 card after Home loaded')
            time.sleep(0.2)
        checkpoint('06-home-with-card')
        outcome['passed'] = True
    except Exception as error:
        outcome['failure'] = type(error).__name__ + ': ' + str(error)
        (args.output / 'failure.txt').write_text(traceback.format_exc())
        if connected:
            try:
                checkpoint('failure')
            except Exception as diagnostic_error:
                outcome['diagnosticError'] = str(diagnostic_error)
    finally:
        # Never terminate an unrelated driver instance: --owned-driver is mandatory.
        try:
            if call('/quit').strip() != b'bye':
                raise RuntimeError('Unexpected quit acknowledgement')
            outcome['driverQuitAcknowledged'] = True
        except Exception as cleanup_error:
            outcome['cleanupErrors'].append(str(cleanup_error))
            outcome['passed'] = False
        try:
            (args.output / 'fixture-requests-observed.json').write_text(json.dumps(rows()[initial_requests:], indent=2) + '\n')
        except Exception as log_error:
            outcome['logCaptureError'] = str(log_error)
            outcome['passed'] = False
        outcome['limits'] = ['No tvOS UI automation, Details/back/Settings/logout or playback is covered.',
                             'Simulator UI plus synthetic wire contract only, not real PG/PIN/provider/device authority.',
                             'Root must wait the original XCTest/xcodebuild process after the quit ACK; HTTP ACK is not a process join.']
        (args.output / 'outcome.json').write_text(json.dumps(outcome, indent=2) + '\n')
    print(json.dumps({'passed': outcome['passed'], 'output': str(args.output),
                      'driverQuitAcknowledged': outcome['driverQuitAcknowledged'], 'xcodebuildProcessJoined': False}))
    return 0 if outcome['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
