"""Probe notification ordering boundaries."""

import json
import os
from pathlib import Path
import subprocess
import shutil
import sys
import tempfile
from datetime import datetime, timezone


SCRIPT = Path(__file__).resolve().parents[2] / 'scripts/mcp-watch.sh'
BASE = 1800000000


def iso(value):
    """Format fixture time."""
    return datetime.fromtimestamp(value, timezone.utc).isoformat().replace('+00:00', 'Z')


def park(name, at):
    """Create native failure evidence."""
    return f"{iso(at)} WARNING tools.mcp_tool: MCP server '{name}' failed initial connection, parking until a reconnect is requested\n"


def revival(name, at):
    """Create native recovery evidence."""
    return f"{iso(at)} WARNING tools.mcp_tool: MCP server '{name}': revived \u2014 session healthy again after parking\n"


class Fixture:
    """Drive independent watchdog sequences."""

    def __init__(self, root):
        """Create controlled fixture transports."""
        self.root = root
        (root / 'bin').mkdir()
        (root / 'clock').mkdir()
        (root / 'clock/sitecustomize.py').write_text('''import datetime,os,time
class Clock(datetime.datetime):
    @classmethod
    def now(cls,tz=None):return cls.fromtimestamp(float(os.environ['MPR_NOW']),tz)
datetime.datetime=Clock
time.time=lambda:float(os.environ['MPR_NOW'])
''')
        docker = root / 'bin/docker'
        docker.write_text(f'#!{sys.executable}\n' + '''import datetime,os,sys
from pathlib import Path
a=sys.argv[1:]
if a[0]=='inspect':
    if a[2]=='{{.Id}}':
        if os.environ.get('MPR_NO_ID'):sys.exit(1)
        print('fixture-container-id')
    else:print(os.environ['MPR_STARTED'])
elif a[0]=='exec':
    if any('s6-svstat' in x for x in a):print('up (pid 175 pgid 175) %s seconds'%(int(os.environ['MPR_NOW'])-int(os.environ['MPR_BORN'])))
    else:print('/run/hermes-service/gateway-default')
elif a[0]=='logs':
    cutoff=datetime.datetime.fromisoformat(a[a.index('--since')+1].replace('Z','+00:00')).timestamp()
    for line in Path(os.environ['MPR_LOGS']).read_text().splitlines():
        at=datetime.datetime.fromisoformat(line.split(' ',1)[0].replace('Z','+00:00')).timestamp()
        if at>=cutoff:print(line)
else:sys.exit(7)
''')
        curl = root / 'bin/curl'
        curl.write_text(f'#!{sys.executable}\n' + '''import json,os,sys
from pathlib import Path
d=json.loads(sys.argv[sys.argv.index('--data')+1]);kind='recovery' if 'recovery confirmed' in d['text'].lower() else 'detection' if 'servers detected' in d['text'] else 'reminder'
failed=os.environ.get('MPR_FAIL_KIND') in ('all',kind)
with open(os.environ['MPR_SENDS'],'a') as f:f.write(json.dumps({'kind':kind,'delivered':not failed,'text':d['text']})+'\\n')
if failed:sys.exit(22)
print('OK\\n200')
''')
        for p in [docker, curl]:
            p.chmod(0o700)
        self.env = os.environ | {'PATH': str(root / 'bin') + os.pathsep + os.environ['PATH'], 'PYTHONPATH': str(root / 'clock'), 'MPR_NOW': str(BASE), 'MPR_STARTED': iso(BASE - 86400), 'MPR_BORN': str(BASE - 3600), 'MPR_LOGS': str(root / 'logs'), 'MPR_SENDS': str(root / 'sends'), 'RELAY_URL': 'https://example.invalid/alert', 'RELAY_TOKEN': 'synthetic-only', 'WATCH_CONTAINERS': 'hermes', 'WATCH_STATE_DIR': str(root / 'state'), 'WATCH_WINDOW': '20m', 'WATCH_REMIND_SECONDS': '43200'}

    def tick(self, at, logs, fail='', no_id=False):
        """Execute one real script run."""
        self.env['MPR_NOW'] = str(at)
        self.env['MPR_FAIL_KIND'] = fail
        self.env['MPR_NO_ID'] = '1' if no_id else ''
        (self.root / 'logs').write_text(logs)
        p = subprocess.run([os.environ.get('MPR_TEST_BASH', shutil.which('bash')), str(SCRIPT)], env=self.env, capture_output=True, text=True, timeout=15)
        return {'exit': p.returncode, 'stderr': p.stderr, 'state': (self.root / 'state/hermes.state').read_text() if (self.root / 'state/hermes.state').exists() else ''}

    def sends(self):
        """Read actual attempted notifications."""
        p = self.root / 'sends'
        return [json.loads(s) for s in p.read_text().splitlines()] if p.exists() else []


def main():
    """Exercise additional contrasting cases."""
    result = {}
    with tempfile.TemporaryDirectory(prefix='mpr-notification-review-') as temp:
        root = Path(temp)
        def fixture(name):
            """Create one isolated episode."""
            folder = root / name
            folder.mkdir()
            return Fixture(folder)
        f = fixture('control')
        f.tick(BASE, park('vault', BASE-60))
        control = f.tick(BASE+60, revival('vault', BASE+50))
        assert 'status=ok' in control['state'] and [s['kind'] for s in f.sends()] == ['detection', 'recovery']
        result['control'] = control | {'sends': f.sends()}
        f = fixture('owed-order')
        first = f.tick(BASE, park('vault', BASE-60) + revival('vault', BASE-10), fail='all')
        second = f.tick(BASE+60, '', fail='detection')
        attempts_before_retry = f.sends()
        delivered = f.tick(BASE+1800, '')
        assert 'status=ok' in delivered['state']
        assert [s['kind'] for s in f.sends() if s['delivered']] == ['detection', 'recovery']
        assert iso(BASE).split('+')[0][:19] in f.sends()[-1]['text']
        result['repeated_detection_failure_must_not_deliver_recovery'] = {'first': first, 'second': second, 'sends': attempts_before_retry}
        f = fixture('reminder')
        f.env['WATCH_REMIND_SECONDS'] = '60'
        f.tick(BASE, park('vault', BASE-60))
        f.tick(BASE+61, '')
        third = f.tick(BASE+62, '')
        result['successful_reminder_must_debounce_next_run'] = third | {'sends': f.sends()}
        f = fixture('unknown-id')
        f.tick(BASE, park('vault', BASE-60))
        result['missing_container_identity_is_unknown'] = f.tick(BASE+60, revival('vault', BASE+50), no_id=True) | {'sends': f.sends()}
        f = fixture('newer-failure')
        f.tick(BASE, park('vault', BASE-60))
        f.tick(BASE+60, revival('vault', BASE+50), fail='recovery')
        result['new_failure_supersedes_undelivered_recovery'] = f.tick(BASE+120, park('vault', BASE+110)) | {'sends': f.sends()}
        f = fixture('aged-out-proof')
        f.tick(BASE, park('vault', BASE-60))
        recovered = f.tick(BASE+1800, revival('vault', BASE+1790))
        f.tick(BASE+1801, revival('vault', BASE+1790))
        result['aged_out_failure_recovers_once'] = recovered | {'sends': f.sends()}
        f = fixture('partial-recovery')
        f.tick(BASE, park('vault', BASE-60) + park('calendar', BASE-55))
        partial = f.tick(BASE+1800, park('calendar', BASE+1750) + revival('calendar', BASE+1790))
        assert 'status=problem' in partial['state'] and len(f.sends()) == 1
        complete = f.tick(BASE+1810, revival('vault', BASE+1809))
        result['aged_out_other_server_stays_unresolved'] = complete | {'sends': f.sends()}
        f = fixture('unattributed-failure')
        unknown = f"{iso(BASE-55)} ERROR tools.mcp_tool: parking until a reconnect is requested\n"
        f.tick(BASE, park('vault', BASE-60) + unknown)
        unproven = f.tick(BASE+1800, revival('vault', BASE+1790))
        assert 'status=problem' in unproven['state'] and len(f.sends()) == 1, 'An aged-out unattributed failure must not be silently declared recovered'
        result['unattributed_failure_stays_unknown_after_window_expires'] = unproven | {'sends': f.sends()}
        row = result['repeated_detection_failure_must_not_deliver_recovery']
        assert 'status=problem' in row['second']['state']
        assert len(row['sends']) == 2 and not any(s['kind'] == 'recovery' for s in row['sends'])
        row = result['successful_reminder_must_debounce_next_run']
        assert len(row['sends']) == 2 and f"last_alert_ts={BASE+61}\n" in row['state']
        row = result['missing_container_identity_is_unknown']
        assert 'status=problem' in row['state'] and len(row['sends']) == 1
        row = result['new_failure_supersedes_undelivered_recovery']
        assert 'status=problem' in row['state']
        assert not any(s['kind'] == 'recovery' and s['delivered'] for s in row['sends'])
        assert row['sends'][-1]['kind'] == 'detection' and row['sends'][-1]['delivered']
        for key in ['aged_out_failure_recovers_once', 'aged_out_other_server_stays_unresolved']:
            assert 'status=ok' in result[key]['state'] and len(result[key]['sends']) == 2
    for name in result:
        print('PASS  sequence: ' + name)
    print(str(len(result)) + ' controlled-clock sequence cases passed')


if __name__ == '__main__':
    main()
