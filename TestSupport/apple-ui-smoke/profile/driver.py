#!/usr/bin/env python3
"""Prepared real-time profile-return UI smoke; no app clock or defaults injection."""
import argparse
from datetime import datetime, timezone
import hashlib
import http.client
import json
import math
import re
from pathlib import Path
import time
import traceback
from urllib.parse import urlencode


def observed_input(tree, inventory, field, role):
    """Match an actual input role/placeholder to one live driver inventory frame."""
    if role not in ('TextField', 'SecureTextField') or not isinstance(tree, bytes):
        raise RuntimeError('Expected an original input role and accessibility tree')
    if not isinstance(inventory, dict) or not isinstance(inventory.get('items'), list):
        raise RuntimeError('Expected the original mobile element inventory')
    if inventory.get('role') != role:
        raise RuntimeError('The actual input inventory has a different role')
    if inventory.get('count') != len(inventory['items']):
        raise RuntimeError('The actual input inventory is truncated')
    text = tree.decode()
    if 'Element subtree:\n' not in text:
        raise RuntimeError('No original accessibility element subtree')
    subtree = text.split('Element subtree:\n', 1)[1].split('Path to element:', 1)[0]
    number = r'-?\d+(?:\.\d+)?'
    pattern = re.compile(r'^\s*(TextField|SecureTextField),\s+0x[0-9a-fA-F]+,\s+'
                         r'\{\{(' + number + r'),\s*(' + number + r')\},\s*\{('
                         + number + r'),\s*(' + number + r')\}\}(.*)$', re.MULTILINE)
    candidates = []
    for match in pattern.finditer(subtree):
        attributes = dict(re.findall(r"(?:^|,\s+)(label|identifier|placeholderValue|value): '([^']*)'", match[6]))
        if match[1] != role or field not in [attributes.get(key) for key in ('label', 'identifier', 'placeholderValue')]:
            continue
        frame = [int(float(match[index])) for index in range(2, 6)]
        if frame[2] <= 0 or frame[3] <= 0:
            continue
        candidates.append({'role': role, 'frame': frame, 'attributes': attributes,
                           'hasKeyboardFocus': bool(re.search(r'\bhasKeyboardFocus\b', match[6]))})
    if len(candidates) != 1:
        raise RuntimeError('Expected one actual ' + role + ' for ' + field + '; found ' + str(len(candidates)))
    element = candidates[0]
    element['inventoryRole'] = inventory['role']
    element['inventoryCount'] = inventory['count']
    items = [item for item in inventory['items'] if isinstance(item, dict)
             and item.get('frame') == element['frame'] and item.get('hittable') is True
             and isinstance(item.get('type'), str) and item['type']]
    if len(items) != 1:
        raise RuntimeError('Expected one hittable inventory input at the observed ' + field + ' frame')
    return element, items[0]



BACKGROUND_STATES = {'runningBackground', 'runningBackgroundSuspended'}


def checked_state(snapshot, allowed):
    if not isinstance(snapshot, dict) or snapshot.get('state') not in allowed:
        raise RuntimeError('Actual application state is not allowed: ' + repr(snapshot))
    uptime = snapshot.get('systemUptime')
    if isinstance(uptime, bool) or not isinstance(uptime, (int, float)) or not math.isfinite(uptime) or uptime < 0:
        raise RuntimeError('Actual public systemUptime is missing or invalid')
    return snapshot


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
    outcome = {'scope': 'iPhone real10s/305s profile-return UI with original live background app', 'appleUIExecuted': False,
               'passed': False, 'steps': [], 'cleanupErrors': [], 'driverQuitAcknowledged': False,
               'xcodebuildProcessJoined': False, 'operatorMustJoinOriginalXcodebuild': True,
               'inputSelections': []}
    outcome['profileReturn'] = {'shortControlSeconds': 10, 'longAwaySeconds': 305, 'observations': []}
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
        role = 'SecureTextField' if label == 'Password' else 'TextField'

        def current_input():
            tree = call('/tree')
            inventory = call('/find', {'q': '', 'limit': '1000', 'role': role})
            element, item = observed_input(tree, inventory, label, role)
            return tree, element, item

        tree, element, item = current_input()
        initial_value = item.get('value', '')
        selected = {'field': label, 'role': role, 'frame': item['frame'], 'rawType': item['type'],
                    'inventoryRole': element['inventoryRole'], 'inventoryCount': element['inventoryCount'],
                    'label': item.get('label', ''), 'identifier': item.get('identifier', ''),
                    'placeholder': element['attributes'].get('placeholderValue'), 'hittable': True,
                    'treeSHA256': hashlib.sha256(tree).hexdigest()}
        outcome['inputSelections'].append(selected)
        text = value.removesuffix('\n')
        action = call('/input', {'role': role, 'field': label, 'text': text})
        if (not isinstance(action, dict) or set(action) != {'role', 'field', 'count', 'target'}
                or action['role'] != role or action['field'] != label or type(action['count']) is not int
                or action['count'] != 1 or not isinstance(action['target'], dict)):
            raise RuntimeError('Native field input did not confirm the original unique role and field')
        target = action['target']
        if ('value' in target or target.get('type') != item['type'] or target.get('hittable') is not True
                or not isinstance(target.get('frame'), list) or len(target['frame']) != 4
                or not all(type(number) is int for number in target['frame'])
                or target['frame'][2] <= 0 or target['frame'][3] <= 0):
            raise RuntimeError('Native field input did not return its actual safe target descriptor')
        selected['nativeInputAction'] = action  # No request text or actual secure value is echoed.
        selected['actualTypeAccepted'] = True
        tree, element, item = current_input()
        actual = item.get('value', '')
        if role == 'SecureTextField':
            if not isinstance(actual, str) or not actual or actual == label or actual == initial_value:
                raise RuntimeError('The actual secure input does not show completed entry')
            selected['secureValuePresent'] = True  # Do not record the password or secure-field value.
        else:
            if actual != text or actual == initial_value:
                raise RuntimeError('The actual input value does not match the typed ' + label)
            selected['confirmedValue'] = actual
        selected['valueTreeSHA256'] = hashlib.sha256(tree).hexdigest()
        selected['actualInputValueChanged'] = True
        if value.endswith('\n'):
            call('/type', {'text': '\n'})  # Submit only after the actual field value was confirmed.

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

    def home_card():
        # The only shelf feeds the default carousel, which intentionally omits its header.
        deadline = time.monotonic() + 15
        while True:
            found = call('/find', {'q': 'homeHero', 'role': 'Button', 'limit': '100'})
            if (not isinstance(found, dict) or found.get('role') != 'Button'
                    or not isinstance(found.get('items'), list)
                    or type(found.get('count')) is not int or found['count'] != len(found['items'])):
                raise RuntimeError('Expected the complete original Home hero button inventory')
            cards = [item for item in found['items'] if isinstance(item, dict)
                     and item.get('identifier') == 'homeHero' and item.get('type') == button_type
                     and item.get('hittable') is True
                     and re.fullmatch(r'Synthetic Film [1-6](?:,.*)?', item.get('label', ''))
                     and isinstance(item.get('frame'), list) and len(item['frame']) == 4
                     and all(type(value) is int for value in item['frame'])
                     and item['frame'][2] > 0 and item['frame'][3] > 0]
            if len(cards) == 1:
                outcome.setdefault('homeCards', []).append({'observedAtUTC': datetime.now(timezone.utc).isoformat(),
                    'actualButton': cards[0], 'inventoryRole': found['role'], 'inventoryCount': found['count']})
                return cards[0]
            if time.monotonic() >= deadline:
                raise RuntimeError('Expected one actual hittable synthetic Home hero button')
            time.sleep(0.2)

    def enable_automatic_profile():
        found = call('/find', {'q': 'Use Automatically', 'limit': '100'})
        switches = [item for item in found.get('items', [])
                    if item.get('label') == 'Use Automatically' and item.get('hittable') is True and item.get('value') == '0']
        if len(switches) != 1:
            raise RuntimeError('Expected one actually OFF Use Automatically control before profile selection')
        before = switches[0]
        tap_item(before)
        deadline = time.monotonic() + 5
        while True:
            found = call('/find', {'q': 'Use Automatically', 'limit': '100'})
            on = [item for item in found.get('items', [])
                  if item.get('label') == 'Use Automatically' and item.get('type') == before['type']
                  and item.get('hittable') is True and item.get('value') == '1']
            if len(on) == 1:
                outcome['profileReturn']['actualAutoToggle'] = {'before': before, 'after': on[0]}
                return
            if time.monotonic() >= deadline:
                raise RuntimeError('Original Use Automatically UI did not prove OFF-to-ON transition')
            time.sleep(0.2)

    def background_return(label, seconds):
        # Every state read is passive. Only the guarded same-handler endpoint may reactivate.
        acknowledged = checked_state(call('/background'), BACKGROUND_STATES)
        started = time.monotonic()
        deadline = started + seconds
        observations = []
        while True:
            current = checked_state(call('/state'), BACKGROUND_STATES)
            observations.append({'atUTC': datetime.now(timezone.utc).isoformat(),
                                 'controllerMonotonicElapsed': time.monotonic() - started, 'actual': current})
            outcome['profileReturn']['observations'].append({'round': label, **observations[-1]})
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            time.sleep(min(5, remaining))
        final_background = checked_state(call('/state'), BACKGROUND_STATES)
        returned = checked_state(call('/resume-backgrounded'), {'runningForeground'})
        if returned.get('previousState') not in BACKGROUND_STATES:
            raise RuntimeError('Guarded return did not witness a still-running original background app')
        elapsed = time.monotonic() - started
        if elapsed < seconds or returned['systemUptime'] - acknowledged['systemUptime'] < seconds:
            raise RuntimeError('Real elapsed background interval was not established')
        outcome['profileReturn'][label] = {'requestedSeconds': seconds, 'actualControllerSeconds': elapsed,
                                         'backgroundAck': acknowledged, 'immediatePreReturnState': final_background,
                                         'sameHandlerReturnWitness': returned}

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
        enter('192.168.1.10 or media.example.com', 'http://127.0.0.1:' + str(args.fixture_port) + '\n')
        # MobileServerForm.onSubmit(connect) is the actual Go/return action.
        wait('Account')
        require_request('GET', '/health', 200, initial_requests)
        checkpoint('02-login')
        enter('Username', 'apple-smoke\n')  # MobileLoginForm advances to Password on submit.
        enter('Password', 'synthetic-only\n')  # Actual SecureField.onSubmit(signIn).
        wait("Who's Watching?")
        require_request('POST', '/api/auth/login', 200, initial_requests)
        require_request('GET', '/api/users', 200, initial_requests)
        checkpoint('03-profiles')
        enable_automatic_profile()
        checkpoint('03a-auto-profile-enabled')
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
        wait('homeViewSwitcher')
        require_request('POST', '/api/users/pin/pin/verify', 200, before_good)
        require_request('GET', '/api/users/pin/settings', 200, before_good)
        require_request('GET', '/api/users/pin/history/continue', 200, before_good)
        # Require a rendered card, not merely the Home heading or a successful wire response.
        home_card()
        checkpoint('06-home-with-card')
        before_short = len(rows())
        background_return('shortControl', 10)
        wait('homeViewSwitcher')
        home_card()
        if call('/find', {'q': 'Enter PIN for Synthetic PIN', 'limit': '100'}).get('count') != 0:
            raise RuntimeError('Short original background return unexpectedly requested a PIN')
        if any(row['path'] == '/api/users/pin/pin/verify' for row in rows()[before_short:]):
            raise RuntimeError('Short negative control unexpectedly issued PIN verification')
        checkpoint('07-short-return-home')
        before_long = len(rows())
        background_return('longAway', 305)
        wait('This profile is locked. Enter its PIN to continue.')
        wait('Enter PIN for Synthetic PIN')
        if any(row['status'] == 403 for row in rows()[before_long:]):
            raise RuntimeError('Long-return challenge must not be manufactured by an expired fixture unlock')
        checkpoint('08-long-return-pin')
        before_bad_return = len(rows())
        for digit in '9999':
            tap(digit)
        wait('Incorrect PIN. Try again.')
        require_request('POST', '/api/users/pin/pin/verify', 401, before_bad_return)
        checkpoint('09-long-return-bad-pin')
        before_good_return = len(rows())
        for digit in '1234':
            tap(digit)
        require_request('POST', '/api/users/pin/pin/verify', 200, before_good_return)
        wait('homeViewSwitcher')
        home_card()
        checkpoint('10-long-return-home')
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
        outcome['limits'] = ['Real simulator background return only; no player-deferred/PiP/physical-device behavior is covered.',
                             'Simulator UI plus synthetic wire contract only, not real PG/PIN/provider/device authority.',
                             'Root must wait the original XCTest/xcodebuild process after the quit ACK; HTTP ACK is not a process join.']
        (args.output / 'outcome.json').write_text(json.dumps(outcome, indent=2) + '\n')
    print(json.dumps({'passed': outcome['passed'], 'output': str(args.output),
                      'driverQuitAcknowledged': outcome['driverQuitAcknowledged'], 'xcodebuildProcessJoined': False}))
    return 0 if outcome['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
