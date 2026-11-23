#!/usr/bin/env python3
"""Nondispatchable synthetic-playback draft using the original opt-in iPhone driver."""
import argparse
from datetime import datetime, timezone
import hashlib
import http.client
import json
from pathlib import Path
import re
import math
import time
import traceback
from urllib.parse import urlencode


PLAYBACK_IDENTITY = {'prequeueId': 'synthetic-playback-1', 'profileId': 'pin',
                     'itemId': 'tmdb:movie:1', 'sourcePath': 'synthetic/ui-smoke.mp4'}
MEDIA_SHA256 = 'cb5e2eb01783cacbaa09495cd5c280791ee53540257b94a5cabfe30bc651561a'
MEDIA_BYTES = 986689


def observed_button(tree, inventory, labels, prefix=False):
    """Select one observed Button role and its current hittable inventory entry."""
    if not isinstance(tree, bytes) or not isinstance(inventory, dict) or not isinstance(inventory.get('items'), list):
        raise RuntimeError('Expected actual button tree and inventory')
    if inventory.get('role') != 'Button':
        raise RuntimeError('Actual button inventory has a different role')
    if inventory.get('count') != len(inventory['items']):
        raise RuntimeError('Actual button inventory is truncated')
    text = tree.decode()
    if 'Element subtree:\n' not in text:
        raise RuntimeError('Missing actual element subtree')
    subtree = text.split('Element subtree:\n', 1)[1].split('Path to element:', 1)[0]
    number = r'-?\d+(?:\.\d+)?'
    pattern = re.compile(r'^\s*Button,\s+0x[0-9a-fA-F]+,\s+\{\{(' + number + r'),\s*('
                         + number + r')\},\s*\{(' + number + r'),\s*(' + number + r')\}\}(.*)$', re.MULTILINE)
    candidates = []
    for match in pattern.finditer(subtree):
        attributes = dict(re.findall(r"(?:^|,\s+)(label|identifier): '([^']*)'", match[5]))
        label = attributes.get('label', '')
        if not any(label.startswith(wanted) if prefix else label == wanted for wanted in labels):
            continue
        if re.search(r'\bDisabled\b', match[5]):
            continue
        frame = [int(float(match[i])) for i in range(1, 5)]
        if frame[2] <= 0 or frame[3] <= 0:
            continue
        items = [item for item in inventory['items'] if isinstance(item, dict)
                 and item.get('frame') == frame and item.get('label') == label
                 and item.get('hittable') is True and isinstance(item.get('type'), str)]
        if len(items) == 1:
            candidates.append(items[0])
        elif len(items) > 1:
            raise RuntimeError('Ambiguous actual button inventory')
    if len(candidates) != 1:
        raise RuntimeError('Expected one observed hittable button for ' + repr(labels))
    return dict(candidates[0], inventoryRole=inventory['role'], inventoryCount=inventory['count'])


def playback_evidence(value):
    """Validate only the frozen local fixture's finite, original-source evidence."""
    if not isinstance(value, dict) or type(value.get('schemaVersion')) is not int or value['schemaVersion'] != 1:
        raise RuntimeError('Unexpected playback evidence schema')
    if value.get('overflow') is not False or value.get('mediaSHA256') != MEDIA_SHA256 or value.get('mediaBytes') != MEDIA_BYTES:
        raise RuntimeError('Playback evidence overflow or different synthetic media')
    duration = value.get('duration')
    if isinstance(duration, bool) or not isinstance(duration, (int, float)) or not math.isfinite(duration) or duration != 60:
        raise RuntimeError('Synthetic media duration is not the actual probed 60 seconds')
    events = value.get('events')
    if not isinstance(events, list) or len(events) > 4096 or type(value.get('nextSequence')) is not int or value['nextSequence'] != len(events):
        raise RuntimeError('Incomplete original playback event sequence')
    last_timestamp = -1
    for index, event in enumerate(events, 1):
        if not isinstance(event, dict) or type(event.get('sequence')) is not int or event['sequence'] != index:
            raise RuntimeError('Invalid playback event ordering')
        if any(event.get(key) != expected for key, expected in PLAYBACK_IDENTITY.items()):
            raise RuntimeError('Playback evidence belongs to another source or title')
        if event.get('kind') not in ('admission', 'status', 'media', 'progress'):
            raise RuntimeError('Unknown playback evidence kind')
        if type(event.get('monotonicNanos')) is not int or event['monotonicNanos'] < last_timestamp:
            raise RuntimeError('No actual server monotonic timestamp')
        last_timestamp = event['monotonicNanos']
        if type(event.get('responseCompleted')) is not bool or type(event.get('responseStatus')) is not int:
            raise RuntimeError('Missing actual response completion evidence')
        if event['kind'] == 'status' and event.get('duration') != duration:
            raise RuntimeError('Prepared source status has a different duration')
        if event['kind'] == 'media':
            start, end = event.get('rangeStart'), event.get('rangeEnd')
            if event.get('method') not in ('GET', 'HEAD') or event.get('totalBytes') != MEDIA_BYTES:
                raise RuntimeError('Different actual media response')
            if type(start) is not int or type(end) is not int or not 0 <= start <= end < MEDIA_BYTES:
                raise RuntimeError('Invalid observed media range')
            expected_bytes = 0 if event['method'] == 'HEAD' else end - start + 1
            if event['responseCompleted'] and (type(event.get('bodyBytesWritten')) is not int
                                              or event['bodyBytesWritten'] != expected_bytes):
                raise RuntimeError('Incomplete actual media response body')
            if not event['responseCompleted'] and event.get('bodyBytesWritten') is not None:
                raise RuntimeError('Unknown media response incorrectly counts delivered bytes')
        if event['kind'] == 'progress':
            position, reported_duration = event.get('position'), event.get('duration')
            if any(isinstance(n, bool) or not isinstance(n, (int, float)) or not math.isfinite(n)
                   for n in (position, reported_duration)):
                raise RuntimeError('Non-finite actual progress')
            if abs(reported_duration - duration) > 0.25 or not 0 <= position <= duration + 0.25:
                raise RuntimeError('Progress does not match actual media duration')
            if type(event.get('paused')) is not bool or type(event.get('ended')) is not bool:
                raise RuntimeError('Invalid actual progress state')
    return value


def actual_progress_pair(events):
    samples = [event for event in events if event['kind'] == 'progress' and event['responseCompleted'] is True
               and event['responseStatus'] == 200 and event['paused'] is False and event['ended'] is False]
    for first in samples:
        for second in samples:
            if second['sequence'] > first['sequence'] and second['position'] > first['position'] > 0:
                if second['monotonicNanos'] - first['monotonicNanos'] > 10_000_000_000:
                    return first, second
    return None


def require_unended(evidence):
    if any(event['kind'] == 'progress' and event['ended'] for event in evidence['events']):
        raise RuntimeError('Playback already ended before the deliberate player-exit action')


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
    outcome = {'scope': 'iPhone simulator onboarding/PIN/Home and own synthetic playback', 'appleUIExecuted': False,
               'passed': False, 'steps': [], 'cleanupErrors': [], 'driverQuitAcknowledged': False,
               'xcodebuildProcessJoined': False, 'operatorMustJoinOriginalXcodebuild': True,
               'inputSelections': []}
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
        tap_item(item)
        deadline = time.monotonic() + 5
        while True:
            tree, element, item = current_input()
            keyboard = bool(re.search(rb'^\s*Keyboard,\s+0x[0-9a-fA-F]+,', tree, re.MULTILINE))
            if keyboard or element['hasKeyboardFocus'] or time.monotonic() >= deadline:
                selected['keyboardWitness'] = {'keyboardElement': keyboard,
                    'inputHasKeyboardFocus': element['hasKeyboardFocus'],
                    'observationalOnly': True,
                    'treeSHA256': hashlib.sha256(tree).hexdigest()}
                break
            time.sleep(0.2)
        text = value.removesuffix('\n')
        call('/type', {'text': text})  # HTTP 500 is fatal; never retry a failed XCTest event.
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

    def fixture_evidence():
        connection = http.client.HTTPConnection('127.0.0.1', args.fixture_port, timeout=5)
        try:
            connection.request('GET', '/__fixture/playback-evidence?after=0')
            response = connection.getresponse()
            raw = response.read(2_097_153)
            if response.status != 200 or len(raw) > 2_097_152:
                raise RuntimeError('Actual local playback evidence unavailable or oversized')
            return playback_evidence(json.loads(raw))
        finally:
            connection.close()

    def current_button(labels, prefix=False):
        tree = call('/tree')
        inventory = call('/find', {'q': '', 'limit': '1000', 'role': 'Button'})
        return observed_button(tree, inventory, labels, prefix), tree, inventory

    def save_playback_evidence(name, value):
        path = args.output / (name + '-fixture-evidence.json')
        path.write_text(json.dumps(value, indent=2) + '\n')
        return {'path': path.name, 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}

    def require_single_admission(evidence):
        admissions = [event for event in evidence['events'] if event['kind'] == 'admission']
        if len(admissions) != 1 or admissions[0]['responseCompleted'] is not True or admissions[0]['responseStatus'] != 200:
            raise RuntimeError('Expected exactly one actual successful fixture admission')
        return admissions[0]

    def wait_media():
        deadline = time.monotonic() + 30
        while True:
            evidence = fixture_evidence()
            admissions = [event for event in evidence['events'] if event['kind'] == 'admission']
            # The event is appended after the response completes, not at UI tap admission.
            if admissions:
                require_single_admission(evidence)
            statuses = [event for event in evidence['events'] if event['kind'] == 'status'
                        and event['responseCompleted'] is True and event['responseStatus'] == 200]
            media = [event for event in evidence['events'] if event['kind'] == 'media'
                     and event['responseCompleted'] is True and event['responseStatus'] in (200, 206)
                     and event.get('method') == 'GET' and type(event.get('bodyBytesWritten')) is int
                     and 0 < event['bodyBytesWritten'] <= MEDIA_BYTES and event.get('totalBytes') == MEDIA_BYTES]
            if admissions and statuses and media:
                return evidence
            if time.monotonic() >= deadline:
                raise RuntimeError('Original player did not fetch actual own MP4 bytes')
            time.sleep(0.25)

    def select_film_one(record):
        deadline = time.monotonic() + 15
        gestures = record['carouselGestures'] = []
        while True:
            card = home_card()
            if time.monotonic() >= deadline:
                raise RuntimeError('Film1 carousel selection deadline expired')
            if re.fullmatch(r'Synthetic Film 1(?:,.*)?', card['label']):
                tree = call('/tree')
                inventory = call('/find', {'q': 'homeHero', 'role': 'Button', 'limit': '100'})
                selected = observed_button(tree, inventory, ('Synthetic Film 1',), prefix=True)
                if selected.get('identifier') != 'homeHero' or selected.get('type') != button_type:
                    raise RuntimeError('Film1 is not the original observed Home hero button')
                if time.monotonic() >= deadline:
                    raise RuntimeError('Film1 observation completed after the carousel selection deadline')
                return selected
            if len(gestures) >= 6 or time.monotonic() >= deadline:
                raise RuntimeError('Film1 was not actually visible within the bounded carousel selection')
            call('/swipe', {'q': 'homeCarousel', 'dir': 'right', 'n': '1'})
            gestures.append({'observedAtUTC': datetime.now(timezone.utc).isoformat(),
                             'fromActualButton': card, 'direction': 'right'})

    def playback_smoke():
        record = outcome['playback'] = {'scope': 'Draft local synthetic media UI, not physical decoder/PiP acceptance',
                                        'testPatternVisualAcceptance': 'requires independent Root artifact inspection'}
        before_details = len(rows())
        if fixture_evidence()['events']:
            raise RuntimeError('Unexpected playback work before an explicit title/play action')
        card = select_film_one(record)
        record['actualFilmOneControl'] = card
        call('/tap', {'q': card['label']})
        require_request('GET', '/api/users/pin/details-bundle', 200, before_details)
        wait('Play')
        play, tree, inventory = current_button(('Play',))
        if play.get('type') != button_type:
            raise RuntimeError('Movie Play is not an observed original button')
        details, tree, inventory = current_button(('Choose Source',))
        if details.get('type') != button_type:
            raise RuntimeError('Original movie details landmark is not an observed button')
        record['initialDetailsLandmark'] = details
        checkpoint('07-movie-details')
        before_play = fixture_evidence()
        if before_play['events']:
            raise RuntimeError('Details opening performed playback work before the deliberate Play tap')
        record['beforePlay'] = save_playback_evidence('before-play', before_play)
        record['actualPlayControl'] = play
        tap_item(play)
        initial = wait_media()
        record['initialMedia'] = save_playback_evidence('initial-media', initial)
        checkpoint('08-initial-player')
        # AVKit chrome may hide. Capture what really exists, never force a video route or canvas tap.
        initial_tree = call('/tree')
        initial_inventory = call('/find', {'q': '', 'limit': '1000', 'role': 'Button'})
        try:
            record['initialCloseControl'] = observed_button(initial_tree, initial_inventory, ('Close', 'Done'))
        except RuntimeError as error:
            record['initialCloseObservation'] = str(error)
        deadline = time.monotonic() + 60
        while True:
            evidence = fixture_evidence()
            require_single_admission(evidence)
            require_unended(evidence)
            pair = actual_progress_pair(evidence['events'])
            if pair:
                record['progressPair'] = list(pair)
                record['progressEvidence'] = save_playback_evidence('playing-progress', evidence)
                break
            if time.monotonic() >= deadline:
                raise RuntimeError('No two genuine increasing unpaused samples over ten server seconds apart')
            time.sleep(0.5)
        checkpoint('09-player-progress')
        close, tree, inventory = current_button(('Close', 'Done'))
        # Use the original element.tap path: coordinate taps in a landscape AVKit player can assert.
        selector = close['label']
        exact = [item for item in inventory['items'] if selector in (item.get('label'), item.get('identifier'))]
        if len(exact) != 1 or close.get('type') != button_type:
            raise RuntimeError('AVKit exit control is ambiguous; no hidden-control or coordinate fallback')
        record['actualExitControl'] = close
        pre_exit = fixture_evidence()
        record['preExitEvidence'] = save_playback_evidence('before-exit', pre_exit)
        require_single_admission(pre_exit)
        require_unended(pre_exit)
        before_exit = pre_exit['nextSequence']
        call('/tap', {'q': selector})
        deadline = time.monotonic() + 15
        while True:
            evidence = fixture_evidence()
            require_single_admission(evidence)
            ended = [event for event in evidence['events'] if event['sequence'] > before_exit
                     and event['kind'] == 'progress' and event['ended'] is True
                     and event['responseCompleted'] is True and event['responseStatus'] == 200]
            if ended:
                record['exitEvidence'] = save_playback_evidence('player-exit', evidence)
                break
            if time.monotonic() >= deadline:
                raise RuntimeError('No genuine final progress request after the observed player exit')
            time.sleep(0.25)
        wait('Play')
        returned, tree, inventory = current_button(('Play',))
        if returned.get('type') != button_type:
            raise RuntimeError('Original movie details did not return after player exit')
        wait('Synthetic Film 1')
        details, tree, inventory = current_button(('Choose Source',))
        if details.get('type') != button_type:
            raise RuntimeError('Original details-only landmark did not return after player exit')
        record['returnedDetailsLandmark'] = details
        checkpoint('10-exit-details')

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
        home_card()
        checkpoint('06-home-with-card')
        playback_smoke()
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
        if outcome.get('playback'):
            try:
                outcome['playback']['finalEvidence'] = save_playback_evidence('final', fixture_evidence())
            except Exception as evidence_error:
                outcome['playback']['finalEvidenceError'] = str(evidence_error)
                outcome['passed'] = False
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
        outcome['limits'] = ['Draft controller; an actual UI run and independent player-PNG inspection are required for acceptance.',
                             'No automatic pixel/color heuristic; progress and media responses alone do not prove displayed test-pattern frames.',
                             'No tvOS, physical decoder/audio, PiP, background/PIN-return, source-recovery or postplay-completion acceptance.',
                             'Simulator UI plus synthetic wire contract only, not real PG/PIN/provider/device authority.',
                             'Root must wait the original XCTest/xcodebuild process after the quit ACK; HTTP ACK is not a process join.']
        (args.output / 'outcome.json').write_text(json.dumps(outcome, indent=2) + '\n')
    print(json.dumps({'passed': outcome['passed'], 'output': str(args.output),
                      'driverQuitAcknowledged': outcome['driverQuitAcknowledged'], 'xcodebuildProcessJoined': False}))
    return 0 if outcome['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
