#!/usr/bin/env python3
"""One owned hosted iPhone real-time profile-return UI smoke; no real providers, Apple login or deployment."""
import argparse
from datetime import datetime, timezone
import hashlib
import http.client
import json
import os
from pathlib import Path
import plistlib
import re
import signal
import shutil
import socket
import subprocess
import sys
import time
import traceback

BASE = '9e70ae1a023190c91463e085f480deedbe697254'
LEAVES = {'.github/workflows/apple-source-actions.yml', 'TestSupport/apple-ui-smoke/fixture.py',
          'TestSupport/apple-ui-smoke/driver.py', 'TestSupport/apple-ui-smoke/run-ci.py',
          'StrmrMobileUITests/MobileDriverUITests.swift'}
PINS = {'fixture.py': 'b6f4ef1e919f80e7ba0a3a0ad71f8b593a074935ec7159c95a29b02553edaa0b',
        'driver.py': '56ab341980d3259a30c51a8931bdfddd11b0102cad1654084421be663dcc6ff4'}


class Job:
    def __init__(self, name, argv, output, env, separate_stderr=False):
        self.name, self.argv = name, argv
        self.stream = (output / (name + '.log')).open('wb')
        self.stderr_stream = None
        try:
            if separate_stderr:
                self.stderr_stream = (output / (name + '-stderr.log')).open('wb')
            self.child = subprocess.Popen(argv, stdout=self.stream,
                                          stderr=self.stderr_stream if separate_stderr else subprocess.STDOUT,
                                          env=env, start_new_session=True)
        except BaseException:
            self.stream.close()
            if self.stderr_stream is not None:
                self.stderr_stream.close()
            raise

    def wait(self, timeout):
        return self.child.wait(timeout=timeout)

    def stop(self, grace):
        forced = False
        errors = []
        previous = {sig: signal.signal(sig, signal.SIG_IGN)
                    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP)}
        try:
            if self.child.poll() is None:
                try:
                    os.killpg(self.child.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                except OSError as error:
                    errors.append('TERM: ' + str(error))
                try:
                    self.child.wait(timeout=grace)
                except subprocess.TimeoutExpired:
                    forced = True
                    try:
                        os.killpg(self.child.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    except OSError as error:
                        errors.append('KILL group: ' + str(error))
                        self.child.kill()
                    finally:
                        self.child.wait()
            else:
                self.child.wait()
        finally:
            self.stream.close()
            if self.stderr_stream is not None:
                self.stderr_stream.close()
            for sig, handler in previous.items():
                signal.signal(sig, handler)
        return {'name': self.name, 'pid': self.child.pid, 'exitCode': self.child.returncode,
                'actualOriginalChildJoined': True, 'forcedKill': forced, 'terminationErrors': errors}



def generated_ui_plan(products):
    """Select one original generated mobile UI plan without rewriting or exporting its environment."""
    products = products.resolve(strict=True)
    matches = []
    for plan in sorted(products.glob('*.xctestrun')):
        raw = plan.read_bytes()
        data = plistlib.loads(raw)
        assert isinstance(data, dict), 'Generated test plan is not a dictionary'
        if 'TestConfigurations' in data:
            configurations = data['TestConfigurations']
            assert isinstance(configurations, list), 'Invalid generated test configurations'
            targets = []
            for configuration in configurations:
                assert isinstance(configuration, dict), 'Invalid generated test configuration'
                rows = configuration.get('TestTargets', [])
                assert isinstance(rows, list), 'Invalid generated test targets'
                targets += [(None, target) for target in rows]
            schema = 'TestConfigurations/TestTargets'
        else:
            targets = [(key, value) for key, value in data.items() if not key.startswith('__') and isinstance(value, dict)]
            schema = 'legacy-target-dictionary'
        selected = []
        for legacy_name, target in targets:
            assert isinstance(target, dict), 'Invalid generated target dictionary'
            if target.get('BlueprintName', legacy_name) != 'StrmrMobileUITests':
                continue
            assert target.get('IsUITestBundle') is True, 'Expected the original mobile UI-test bundle'

            def expand(value, host=None):
                assert isinstance(value, str) and value, 'Missing generated test path'
                value = value.replace('__TESTROOT__', str(products))
                if host is not None:
                    value = value.replace('__TESTHOST__', str(host))
                assert '__' not in value, 'Unsupported unresolved generated path macro'
                result = Path(value)
                assert result.is_absolute(), 'Expected resolved absolute generated test path'
                result = result.resolve(strict=True)
                assert result.is_relative_to(products), 'Generated test path outside original Build/Products'
                return result

            host = expand(target.get('TestHostPath'))
            host_apps = [path for path in (host, *host.parents) if path.suffix == '.app']
            assert host_apps and host_apps[0].name == 'StrmrMobileUITests-Runner.app', 'Unexpected original UI runner host'
            host_app = host_apps[0]
            bundle = expand(target.get('TestBundlePath'), host_app)
            app = expand(target.get('UITargetAppPath'), host_app)
            assert bundle.is_dir() and bundle.name == 'StrmrMobileUITests.xctest', 'Wrong or missing original mobile UI bundle'
            assert app.is_dir() and app.name == 'StrmrMobile.app', 'Wrong or missing original mobile target application'
            selected.append({'schema': schema, 'target': 'StrmrMobileUITests',
                             'testBundlePath': str(bundle), 'testHostPath': str(host), 'uiTargetAppPath': str(app)})
        if selected:
            assert len(selected) == 1, 'Ambiguous original mobile UI target configurations'
            metadata = selected[0]
            metadata.update({'planPath': str(plan), 'planSHA256': hashlib.sha256(raw).hexdigest(),
                             'planBytes': len(raw), 'originalPlanUnmodified': True})
            matches.append((plan, metadata))
    assert len(matches) == 1, 'Expected exactly one matching original generated mobile UI plan'
    return matches[0]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if sys.platform != 'darwin' or os.uname().machine != 'arm64':
        parser.error('This runner requires the standard arm64 hosted Mac')
    source = Path.cwd()
    expected = os.environ.get('SOURCE_REF', '')
    if not re.fullmatch('[0-9a-f]{40}', expected) or os.environ.get('GITHUB_SHA') != expected:
        parser.error('Workflow and checkout must use the same immutable dispatched SHA')
    if not args.output.is_absolute() or args.output.exists() or not args.output.parent.is_dir():
        parser.error('Use a new absolute output directory under the checkout artifacts directory')

    def git(*argv):
        return subprocess.check_output(['git', *argv], timeout=60)

    assert git('rev-parse', 'HEAD').decode().strip() == expected
    assert not git('status', '--porcelain'), 'Start from the clean exact checkout'
    scripts = source / 'TestSupport/apple-ui-smoke'
    for name, digest in PINS.items():
        assert hashlib.sha256((scripts / name).read_bytes()).hexdigest() == digest
    assert hashlib.sha256((source / 'StrmrMobileUITests/MobileDriverUITests.swift').read_bytes()).hexdigest() == 'e024e32505ef64b90ccf9edbefb52ddc8a3c62b122d9cfd65eb69df1f0899e59', 'Test-only public-state instrumentation changed'
    output = args.output
    output.mkdir(mode=0o700)
    temporary = source / 'build/apple-ui-smoke/temporary'
    temporary.mkdir(parents=True, exist_ok=True)
    homebrew_temporary = temporary / 'homebrew'
    homebrew_temporary.mkdir(exist_ok=True)
    derived = source / 'build/apple-ui-smoke/derived'
    env = dict(os.environ, TMPDIR=str(temporary) + '/', TMP=str(temporary) + '/',
               TEMP=str(temporary) + '/', PYTHONDONTWRITEBYTECODE='1',
               HOMEBREW_TEMP=str(homebrew_temporary), HOMEBREW_NO_AUTO_UPDATE='1',
               HOMEBREW_NO_ANALYTICS='1', HOMEBREW_NO_INSTALL_CLEANUP='1')
    state = {'passed': False, 'appleUIExecuted': False, 'head': expected, 'appBaseline': BASE,
             'scope': 'Single instrumented iPhone UI-driver case plus real10s/305s original-app profile-return assertions',
             'jobs': [], 'stages': [], 'diagnosticErrors': [], 'errors': [], 'lifecycleErrors': [], 'physicalDeviceAcceptance': False,
             'previous924UnitCasesRerun': False, 'actualPython': sys.version, 'pythonExecutable': sys.executable}
    fixture = driver = None
    simulator = None
    simulator_boot_started = False
    driver_ready = False
    test_plan = None

    def stage(name):
        event = {'phase': name, 'atUTC': datetime.now(timezone.utc).isoformat()}
        state['stages'].append(event)
        print(json.dumps(event), flush=True)

    def command(name, argv, timeout=120, structured=False):
        stage(name + ':start')
        job = Job(name, argv, output, env, separate_stderr=structured)
        try:
            assert job.wait(timeout) == 0, name + ' failed; inspect retained log'
        finally:
            joined = job.stop(5)
            state['jobs'].append(joined)
            stage(name + ':joined:' + str(joined['exitCode']))
        return (output / (name + '.log')).read_text()

    def resources(phase):
        stage(phase + ':resources')
        for label, argv in [('vm-stat', ['/usr/bin/vm_stat']),
                            ('swap-usage', ['/usr/sbin/sysctl', '-n', 'vm.swapusage']),
                            ('workspace-disk', ['/bin/df', '-k', str(source)])]:
            try:
                command(phase + '-' + label, argv, 60)
            except (subprocess.SubprocessError, AssertionError, OSError) as error:
                state['diagnosticErrors'].append(phase + '-' + label + ': ' + str(error))

    def driver_ping(path):
        connection = http.client.HTTPConnection('127.0.0.1', 7791, timeout=1)
        try:
            connection.request('GET', path)
            reply = connection.getresponse()
            data = reply.read()
            return reply.status == 200 and data.strip() == (b'ok' if path == '/ping' else b'bye')
        finally:
            connection.close()

    def source_check(phase):
        stage(phase + ':source-check:start')
        status = git('status', '--porcelain=v1', '--untracked-files=all')
        (output / (phase + '-git-status.txt')).write_bytes(status)
        (output / (phase + '-generated-project.patch')).write_bytes(git('diff', '--binary', 'HEAD', '--', 'StrmrTV.xcodeproj'))
        paths = git('diff', '--name-only', '--no-renames', '-z', 'HEAD').split(b'\0')
        paths += git('ls-files', '--others', '--exclude-standard', '-z').split(b'\0')
        assert all(not p or p.startswith((b'StrmrTV.xcodeproj/', b'artifacts/', b'build/')) for p in paths), 'Unexpected source mutation'
        assert git('rev-parse', 'HEAD').decode().strip() == expected
        stage(phase + ':source-check:exact')

    def interrupted(signum, frame):
        raise RuntimeError('Interrupted by signal ' + str(signum))

    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(sig, interrupted)
    try:
        origin = git('remote', 'get-url', 'origin').decode().strip()
        assert origin in {'https://github.com/stefnats/mediastorm-native-apple',
                          'https://github.com/stefnats/mediastorm-native-apple.git'}, 'Unexpected checkout origin'
        base_present = subprocess.run(['git', 'cat-file', '-e', BASE + '^{commit}'], env=env,
                                      stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=60)
        if base_present.returncode != 0:
            command('baseline-fetch', ['git', '-c', 'maintenance.auto=false', '-c', 'gc.auto=0',
                                       'fetch', '--no-tags', '--depth=1', '--no-recurse-submodules', 'origin', BASE])
        assert set(git('diff', '--name-only', BASE, 'HEAD').decode().splitlines()) == LEAVES
        if shutil.which('xcodegen', path=env.get('PATH')) is None:
            command('xcodegen-bootstrap', ['brew', 'install', 'xcodegen'], 600)
        tools = {}
        for name, argv in [('xcode', ['xcodebuild', '-version']), ('swift', ['xcrun', 'swift', '--version']),
                           ('xcodegen', ['xcodegen', '--version'])]:
            tools[name] = command(name, argv)
        assert int(re.search(r'Xcode (\d+)', tools['xcode'])[1]) >= 27
        assert tuple(map(int, re.search(r'Swift version (\d+)\.(\d+)', tools['swift']).groups())) >= (6, 4)
        state['actualTools'] = tools
        help_text = command('xcodebuild-help', ['xcodebuild', '-help'])
        assert '-xctestrun' in help_text, 'Installed xcodebuild does not advertise -xctestrun'
        timeout_flags = ['-test-timeouts-enabled', '-default-test-execution-time-allowance', '-maximum-test-execution-time-allowance']
        assert all(flag in help_text for flag in timeout_flags), 'Installed xcodebuild lacks required bounded test timeout flags'
        state['installedXctestrunFlagSupported'] = True
        state['installedTestTimeoutFlagsSupported'] = timeout_flags
        state['originalSingleTestTimeoutSeconds'] = 1200
        command('xcodegen-generate', ['xcodegen', 'generate'])
        source_check('after-generation')
        devices = json.loads(command('simulators', ['xcrun', 'simctl', 'list', 'devices', 'available', '--json'], structured=True))
        choices = []
        for runtime, rows in devices['devices'].items():
            match = re.search(r'iOS-(\d+)-(\d+)', runtime)
            if match and int(match[1]) >= 18:
                choices += [(tuple(map(int, match.groups())), d['udid']) for d in rows
                            if d.get('isAvailable') and d.get('name', '').startswith('iPhone') and d.get('state') == 'Shutdown']
        assert choices, 'No actual installed shutdown iPhone simulator'
        simulator = sorted(choices, reverse=True)[0][1]
        state['simulatorUDID'] = simulator
        common = ['-project', 'StrmrTV.xcodeproj', '-scheme', 'StrmrMobile', '-destination', 'id=' + simulator,
                  '-derivedDataPath', str(derived), '-jobs', '2', '-parallel-testing-enabled', 'NO',
                  'ONLY_ACTIVE_ARCH=YES', 'CODE_SIGNING_ALLOWED=YES', 'CODE_SIGN_IDENTITY=-']
        settings = json.loads(command('ios-build-settings', ['xcodebuild', '-showBuildSettings', *common, '-json'], structured=True))
        app = [row['buildSettings'] for row in settings if row.get('target') == 'StrmrMobile']
        assert len(app) == 1 and app[0]['ARCHS'].split() == ['arm64']
        assert app[0]['CODE_SIGNING_ALLOWED'] == 'YES' and app[0]['CODE_SIGN_IDENTITY'] == '-'
        selected_test = '-only-testing:StrmrMobileUITests/MobileDriverUITests/testServe'
        command('build-for-testing', ['xcodebuild', 'build-for-testing', *common, selected_test], 2400)
        test_plan, plan_metadata = generated_ui_plan(derived / 'Build/Products')
        state['selectedOriginalTestPlan'] = plan_metadata
        (output / 'selected-xctestrun-metadata.json').write_text(json.dumps(plan_metadata, indent=2) + '\n')
        stage('original-generated-xctestrun:selected')
        command('ios-codesign', ['codesign', '-d', '--verbose=4', str(derived / 'Build/Products/Debug-iphonesimulator/StrmrMobile.app')])
        assert 'Signature=adhoc' in (output / 'ios-codesign.log').read_text()
        records = [{'path': str(p.relative_to(source)), 'entitlements': plistlib.loads(p.read_bytes())}
                   for p in sorted((derived / 'Build/Intermediates.noindex').rglob('*.xcent'))]
        assert records
        (output / 'generated-entitlements.json').write_text(json.dumps(records, indent=2) + '\n')
        with socket.socket() as probe:
            probe.bind(('127.0.0.1', 7791))  # Never attach to an already running unrelated driver.
        resources('before-boot')
        command('fixture-python-help', [sys.executable, str(scripts / 'fixture.py'), '--help'], 60)
        command('controller-python-help', [sys.executable, str(scripts / 'driver.py'), '--help'], 60)
        stage('fixture:start-before-boot')
        fixture = Job('fixture', [sys.executable, str(scripts / 'fixture.py'), '--port', '0', '--log', str(output / 'fixture-requests.jsonl'),
                                  '--ready-file', str(output / 'fixture-ready.json'), '--duration-seconds', '1800'], output, env)
        deadline = time.monotonic() + 60
        while True:
            assert fixture.child.poll() is None, 'Fixture exited before readiness'
            try:
                ready = json.loads((output / 'fixture-ready.json').read_text())
                break
            except (FileNotFoundError, json.JSONDecodeError):
                assert time.monotonic() < deadline, 'Fixture readiness timed out'
                time.sleep(0.1)
        assert ready['origin'].startswith('http://127.0.0.1:')
        port = ready['origin'].rsplit(':', 1)[1]
        health = http.client.HTTPConnection('127.0.0.1', int(port), timeout=3)
        try:
            health.request('GET', '/health')
            reply = health.getresponse()
            assert reply.status == 200 and json.loads(reply.read()) == {'status': 'ok'}, 'Actual preboot fixture health failed'
        finally:
            health.close()
        stage('fixture:actual-health-200-before-boot')
        simulator_boot_started = True
        command('simulator-boot', ['xcrun', 'simctl', 'boot', simulator])
        command('simulator-ready', ['xcrun', 'simctl', 'bootstatus', simulator, '-b'], 180)
        resources('after-boot')
        driver_env = dict(env, TEST_RUNNER_STRMR_DRIVER='1', TEST_RUNNER_STRMR_DRIVER_PORT='7791')
        driver = Job('xctest-ui-driver', ['xcodebuild', 'test-without-building', '-xctestrun', str(test_plan),
                                        '-destination', 'id=' + simulator, '-parallel-testing-enabled', 'NO',
                                        '-test-timeouts-enabled', 'YES', '-default-test-execution-time-allowance', '1200',
                                        '-maximum-test-execution-time-allowance', '1200', selected_test,
                                        '-resultBundlePath', str(output / 'iPhone-UI.xcresult')], output, driver_env)
        deadline = time.monotonic() + 180
        while True:
            assert driver.child.poll() is None, 'Original UI-driver XCTest exited before readiness'
            try:
                driver_ready = driver_ping('/ping')
            except (OSError, http.client.HTTPException):
                driver_ready = False
            if driver_ready:
                break
            assert time.monotonic() < deadline, 'UI-driver readiness timed out'
            time.sleep(1)
        command('controller', [sys.executable, str(scripts / 'driver.py'), '--owned-driver', '--driver-port', '7791',
                               '--fixture-port', port, '--fixture-log', str(output / 'fixture-requests.jsonl'),
                               '--output', str(output / 'ui')], 900)
        controller = json.loads((output / 'ui/outcome.json').read_text())
        state['appleUIExecuted'] = controller['appleUIExecuted']
        assert controller['passed'] and controller['driverQuitAcknowledged'] and not controller['cleanupErrors']
        assert [row['name'] for row in controller['steps']] == ['01-reset-server', '02-login', '03-profiles', '03a-auto-profile-enabled', '04-pin-prompt', '05-bad-pin', '06-home-with-card', '07-short-return-home', '08-long-return-pin', '09-long-return-bad-pin', '10-long-return-home']
        assert driver.wait(90) == 0, 'Original UI-driver XCTest failed after controller'
        summary = json.loads(command('xcresult-summary', ['xcrun', 'xcresulttool', 'get', 'test-results', 'summary',
                                                          '--path', str(output / 'iPhone-UI.xcresult')], structured=True))
        state['actualXCTestSummary'] = summary
        assert (summary['totalTestCount'], summary['passedTests'], summary['failedTests'], summary['skippedTests']) == (1, 1, 0, 0), 'Expected exactly the original UI-driver case, no hidden skip'
        state['bodySucceeded'] = True
    except BaseException as error:
        state['errors'].append(type(error).__name__ + ': ' + str(error))
        (output / 'failure.txt').write_text(traceback.format_exc())
    finally:
        stage('cleanup:start')
        for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
            signal.signal(sig, signal.SIG_IGN)
        if driver is not None:
            if driver.child.poll() is None:
                try:
                    if driver_ready:
                        driver_ping('/quit')
                    driver.wait(30)
                except (OSError, http.client.HTTPException, subprocess.TimeoutExpired):
                    pass
            joined = driver.stop(10)
            state['jobs'].append(joined)
            if joined['exitCode'] != 0 or joined['forcedKill'] or joined['terminationErrors']:
                state['lifecycleErrors'].append('Original XCTest driver did not close normally')
        if fixture is not None:
            joined = fixture.stop(10)
            state['jobs'].append(joined)
            if joined['exitCode'] != 0 or joined['forcedKill'] or joined['terminationErrors']:
                state['lifecycleErrors'].append('Original synthetic fixture did not close normally')
        if simulator_boot_started:
            try:
                command('simulator-shutdown', ['xcrun', 'simctl', 'shutdown', simulator], 120)
            except BaseException as error:
                state['lifecycleErrors'].append('Simulator shutdown: ' + str(error))
        if test_plan is not None:
            try:
                assert hashlib.sha256(test_plan.read_bytes()).hexdigest() == state['selectedOriginalTestPlan']['planSHA256'], 'Original generated test plan changed'
            except (AssertionError, OSError) as error:
                state['errors'].append('Original test-plan preservation: ' + str(error))
        try:
            source_check('after-cleanup')
        except BaseException as error:
            state['errors'].append('Final source check: ' + str(error))
        if (output / 'ui/outcome.json').exists():
            try:
                state['appleUIExecuted'] = json.loads((output / 'ui/outcome.json').read_text()).get('appleUIExecuted', False)
            except (ValueError, OSError) as error:
                state['errors'].append('Controller outcome unreadable: ' + str(error))
        state['passed'] = bool(state.get('bodySucceeded')) and not state['errors'] and not state['lifecycleErrors']
        state['capturedAtUTC'] = datetime.now(timezone.utc).isoformat()
        state['limits'] = ['Synthetic iPhone simulator UI only; no real device, decoder, PG/PIN authority or provider acceptance.',
                           'No player-deferred return, PiP, physical device, tvOS UI or media playback is covered.',
                           'The single XCTest method is the original driver, not a rerun of the previous 924 unit cases.']
        (output / 'outcome.json').write_text(json.dumps(state, indent=2) + '\n')
    print(json.dumps({'passed': state['passed'], 'appleUIExecuted': state['appleUIExecuted'], 'output': str(output)}))
    return 0 if state['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
