#!/usr/bin/env python3
"""Prepared original tvOS remote-driver onboarding/PIN/Home smoke, not device acceptance."""
import argparse
from datetime import datetime, timezone
import hashlib
import http.client
import json
from pathlib import Path
import re
import time
import traceback
from urllib.parse import urlencode


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--driver-port', type=int, default=7790)
    parser.add_argument('--fixture-port', type=int, default=8765)
    parser.add_argument('--fixture-log', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--owned-driver', action='store_true')
    args = parser.parse_args()
    if not args.owned_driver or not (1 <= args.driver_port <= 65535 and 1 <= args.fixture_port <= 65535):
        parser.error('Explicit ownership of this dedicated RemoteDriverUITests instance and valid ports are required')
    if not args.output.is_absolute() or args.output.exists() or not args.output.parent.is_dir():
        parser.error('Use a new absolute output directory under the persistent results directory')
    if not args.fixture_log.is_absolute() or not args.fixture_log.is_file():
        parser.error('The original local synthetic fixture request log is required')
    args.output.mkdir(mode=0o700)
    outcome = {'scope': 'tvOS simulator real remote onboarding/PIN/Home only', 'appleUIExecuted': False,
               'passed': False, 'steps': [], 'actions': [], 'cleanupErrors': [],
               'driverQuitAcknowledged': False, 'xcodebuildProcessJoined': False,
               'operatorMustJoinOriginalXcodebuild': True}
    connected = False
    initial_requests = 0

    def call(endpoint, query=None):
        connection = http.client.HTTPConnection('127.0.0.1', args.driver_port, timeout=25)
        try:
            connection.request('GET', endpoint + ('?' + urlencode(query) if query else ''))
            reply = connection.getresponse()
            data = reply.read()
            if reply.status != 200:
                raise RuntimeError(endpoint + ': HTTP ' + str(reply.status) + ' ' + data.decode(errors='replace')[:300])
            return json.loads(data) if reply.getheader('Content-Type', '').startswith('application/json') else data
        finally:
            connection.close()

    def focus():
        value = call('/focus')
        if not isinstance(value, dict):
            raise RuntimeError('Expected original tvOS focus JSON')
        return value

    def matches(value, label, prefix=False):
        text = value.get('label', '')
        return value.get('focused') is True and (text.startswith(label) if prefix else label in (text, value.get('identifier')))

    def press(button):
        before = focus()
        after = call('/press', {'b': button, 'n': '1', 'gap': '0.35'})
        outcome['actions'].append({'button': button, 'before': before, 'after': after})
        return after

    def require_focus(label, prefix=False, timeout=4):
        deadline = time.monotonic() + timeout
        while True:
            current = focus()
            if matches(current, label, prefix):
                return current
            if time.monotonic() >= deadline:
                raise RuntimeError('Unexpected actual focus; expected ' + label + ', observed ' + repr(current))
            time.sleep(0.2)

    def seek(label, direction, count=6, prefix=False):
        # A bounded structural move in one known screen section, never a guessed focus graph.
        for index in range(count + 1):
            current = focus()
            if matches(current, label, prefix):
                return current
            if index < count:
                press(direction)
        raise RuntimeError('Actual focus did not reach ' + label + ' via bounded ' + direction)

    def wait(label):
        call('/wait', {'q': label, 'timeout': '15'})

    def checkpoint(name):
        tree, shot, current = call('/tree'), call('/shot'), focus()
        if not isinstance(tree, bytes) or not isinstance(shot, bytes) or not shot.startswith(b'\x89PNG\r\n\x1a\n'):
            raise RuntimeError('Invalid actual tree or PNG')
        (args.output / (name + '-tree.txt')).write_bytes(tree)
        (args.output / (name + '-focus.json')).write_text(json.dumps(current, indent=2) + '\n')
        (args.output / (name + '.png')).write_bytes(shot)
        outcome['steps'].append({'name': name, 'atUTC': datetime.now(timezone.utc).isoformat(), 'focus': current,
                                 'treeSHA256': hashlib.sha256(tree).hexdigest(), 'pngSHA256': hashlib.sha256(shot).hexdigest()})

    def keyboard_present():
        tree = call('/tree')
        return bool(re.search(rb'\bKeyboard\b', tree, re.IGNORECASE))

    def edit(label, value, checkpoint_name, heading, secure=False):
        seek(label, 'down')
        require_focus(label)
        press('select')
        deadline = time.monotonic() + 5
        while not keyboard_present():
            if time.monotonic() >= deadline:
                raise RuntimeError('Actual TV keyboard structure not witnessed for ' + label)
            time.sleep(0.2)
        checkpoint(checkpoint_name)
        call('/type', {'text': value})  # Original TV driver types the active field; no mobile q/tap port.
        if keyboard_present():
            # Menu is allowed only after the actual keyboard tree witness above and now.
            outcome['actions'].append({'keyboardCloseFor': label, 'actualFocus': focus(), 'keyboardWitness': True})
            press('menu')
        deadline = time.monotonic() + 5
        while keyboard_present():
            if time.monotonic() >= deadline:
                raise RuntimeError('TV keyboard did not close; no second guessed Menu action')
            time.sleep(0.2)
        wait(heading)
        found = call('/find', {'q': label, 'limit': '50'})
        fields = [item for item in found.get('items', []) if label in (item.get('label'), item.get('identifier'))]
        if len(fields) != 1:
            raise RuntimeError('No unique original TV field after keyboard close: ' + label)
        actual = fields[0].get('value', '')
        if (not secure and actual != value) or (secure and (not actual or actual == label)):
            raise RuntimeError('Actual original field does not prove completed entry: ' + label)

    def rows():
        return [json.loads(line) for line in args.fixture_log.read_text().splitlines() if line]

    def require_request(method, path, status, after):
        deadline = time.monotonic() + 5
        while True:
            if any(row == {'method': method, 'path': path, 'status': status} for row in rows()[after:]):
                return
            if time.monotonic() >= deadline:
                raise RuntimeError('Missing actual UI-caused fixture request: ' + method + ' ' + path + ' ' + str(status))
            time.sleep(0.1)

    def select_button(label):
        current = require_focus(label)
        if current.get('type') != 'button':
            raise RuntimeError('Focused original control is not a button: ' + label)
        press('select')

    def digit_move(direction, target):
        press(direction)
        require_focus(target)

    try:
        if call('/ping').strip() != b'ok':
            raise RuntimeError('Original driver ping failed')
        connected = True
        initial_requests = len(rows())
        call('/launch', {'args': '-StrmrResetSession 1 -AppleLanguages (en) -AppleLocale en_US'})
        outcome['appleUIExecuted'] = True
        wait('Connect to Your Server')
        checkpoint('01-reset-server')
        edit('Server address', 'http://127.0.0.1:' + str(args.fixture_port), '02-server-keyboard', 'Connect to Your Server')
        seek('Connect', 'down')
        select_button('Connect')
        wait('Username')
        require_request('GET', '/health', 200, initial_requests)
        checkpoint('03-login')
        edit('Username', 'apple-smoke', '04-username-keyboard', 'Sign In')
        edit('Password', 'synthetic-only', '05-password-keyboard', 'Sign In', secure=True)
        seek('Sign In', 'down')
        select_button('Sign In')
        wait("Who's Watching?")
        require_request('POST', '/api/auth/login', 200, initial_requests)
        require_request('GET', '/api/users', 200, initial_requests)
        checkpoint('06-profiles')
        seek('Synthetic PIN', 'right', count=3)
        select_button('Synthetic PIN')
        wait('Enter PIN for Synthetic PIN')
        require_focus('1')
        checkpoint('07-pin-prompt')
        before_bad = len(rows())
        for direction, target in [('right', '2'), ('right', '3'), ('down', '6'), ('down', '9')]:
            digit_move(direction, target)
        for _ in range(4):
            select_button('9')
        wait('Incorrect PIN. Try again.')
        require_request('POST', '/api/users/pin/pin/verify', 401, before_bad)
        require_focus('1')  # The actual original PIN source resets focus after a wrong PIN.
        checkpoint('08-bad-pin')
        before_good = len(rows())
        select_button('1')
        digit_move('right', '2')
        select_button('2')
        digit_move('right', '3')
        select_button('3')
        for direction, target in [('down', '6'), ('left', '5'), ('left', '4')]:
            digit_move(direction, target)
        select_button('4')
        wait('Continue Watching')
        wait('shelf-continue-watching')
        require_request('POST', '/api/users/pin/pin/verify', 200, before_good)
        require_request('GET', '/api/users/pin/settings', 200, before_good)
        require_request('GET', '/api/users/pin/history/continue', 200, before_good)
        first = seek('Synthetic Film 1', 'down', count=8, prefix=True)
        if first.get('type') != 'button':
            raise RuntimeError('Focused Home card is not the actual original button')
        checkpoint('09-home-card1')
        press('right')
        require_focus('Synthetic Film 2', prefix=True)
        checkpoint('10-home-card2')
        press('left')
        require_focus('Synthetic Film 1', prefix=True)
        checkpoint('11-home-return-card1')
        # Do not Select any Home card: this smoke is remote navigation, not media playback.
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
        try:
            if call('/quit').strip() != b'bye':
                raise RuntimeError('Unexpected owned driver quit acknowledgement')
            outcome['driverQuitAcknowledged'] = True
        except Exception as cleanup_error:
            outcome['cleanupErrors'].append(str(cleanup_error))
            outcome['passed'] = False
        try:
            (args.output / 'fixture-requests-observed.json').write_text(json.dumps(rows()[initial_requests:], indent=2) + '\n')
        except Exception as log_error:
            outcome['logCaptureError'] = str(log_error)
            outcome['passed'] = False
        outcome['limits'] = ['Prepared structural keyboard/focus assumptions need a genuine first tvOS CI observation.',
                             'No real Apple TV/Siri Remote, hardware decoder, playback, PG authority or provider acceptance.',
                             'HTTP quit ACK is not an XCTest process join; the original supervisor must actually wait it.']
        (args.output / 'outcome.json').write_text(json.dumps(outcome, indent=2) + '\n')
    print(json.dumps({'passed': outcome['passed'], 'output': str(args.output),
                      'driverQuitAcknowledged': outcome['driverQuitAcknowledged'], 'xcodebuildProcessJoined': False}))
    return 0 if outcome['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
