#!/usr/bin/env python3
# test-agent: venera-agent's protocol through --stdio, as Proxmox talks to it (no VM needed: on a Mac, build it for
# this Mac's architecture; in a VM, the installed one).   agent/test-agent.py PATH-TO-venera-agent
import base64, json, os, subprocess, sys, tempfile, time

p = subprocess.Popen([sys.argv[1], '--stdio'], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
fails = 0

def ask(obj=None, raw=None):
    p.stdin.write(raw if raw is not None else json.dumps(obj).encode())
    p.stdin.flush()
    line = p.stdout.readline()
    return line

def ret(obj):
    r = json.loads(ask(obj))
    if 'return' not in r:
        raise AssertionError(f'{obj["execute"]}: {r}')
    return r['return']

def check(name, ok, got=''):
    global fails
    print(('ok   ' if ok else 'FAIL ') + name + ('' if ok else f'  ({got!r})'))
    fails += not ok

r = ask(raw=b'\xff{"execute":"guest-sync-delimited","arguments":{"id":12345}}')
check('sync-delimited answers 0xFF then the id', r == b'\xff{"return":12345}\n', r)
check('ping', ret({'execute': 'guest-ping'}) == {})
info = ret({'execute': 'guest-info'})
names = {c['name'] for c in info['supported_commands']}
check('info lists exec, file and shutdown', {'guest-exec', 'guest-file-write', 'guest-shutdown'} <= names, names)
os_ = ret({'execute': 'guest-get-osinfo'})
check('osinfo is macOS', os_['id'] == 'macos' and os_['version'], os_)
r = json.loads(ask({'execute': 'guest-nope'}))
check('an unknown command is CommandNotFound', r.get('error', {}).get('class') == 'CommandNotFound', r)

big = os.urandom(300000)
pid = ret({'execute': 'guest-exec', 'arguments': {'path': '/bin/sh', 'arg': ['-c', 'cat; echo err >&2; exit 3'],
                                                  'input-data': base64.b64encode(big).decode(),
                                                  'capture-output': True}})['pid']
for _ in range(200):
    s = ret({'execute': 'guest-exec-status', 'arguments': {'pid': pid}})
    if s['exited']:
        break
    time.sleep(0.05)
check('exec: stdin in, stdout and stderr out, exit code',
      s.get('exitcode') == 3 and base64.b64decode(s['out-data']) == big and base64.b64decode(s['err-data']) == b'err\n',
      {k: v for k, v in s.items() if k not in ('out-data',)})
r = json.loads(ask({'execute': 'guest-exec-status', 'arguments': {'pid': pid}}))
check('exec status is read once', 'error' in r, r)
pid = ret({'execute': 'guest-exec', 'arguments': {'path': 'echo', 'arg': ['found on PATH'], 'capture-output': 'merged'}})['pid']
time.sleep(0.3)
s = ret({'execute': 'guest-exec-status', 'arguments': {'pid': pid}})
check('exec: a bare name is looked up on PATH', base64.b64decode(s.get('out-data', '')) == b'found on PATH\n', s)
r = json.loads(ask({'execute': 'guest-exec', 'arguments': {'path': '/no/such/thing'}}))
check('exec: a missing program is an error', 'error' in r, r)

path = tempfile.mktemp()
data = os.urandom(1 << 20)
h = ret({'execute': 'guest-file-open', 'arguments': {'path': path, 'mode': 'w'}})
w = ret({'execute': 'guest-file-write', 'arguments': {'handle': h, 'buf-b64': base64.b64encode(data).decode()}})
ret({'execute': 'guest-file-close', 'arguments': {'handle': h}})
h = ret({'execute': 'guest-file-open', 'arguments': {'path': path}})
got = b''
while True:
    r = ret({'execute': 'guest-file-read', 'arguments': {'handle': h, 'count': 300000}})
    got += base64.b64decode(r['buf-b64'])
    if r['eof'] or not r['count']:
        break
ret({'execute': 'guest-file-close', 'arguments': {'handle': h}})
os.unlink(path)
check('a 1 MB file written and read back', w['count'] == len(data) and got == data, (w, len(got)))
r = json.loads(ask({'execute': 'guest-file-read', 'arguments': {'handle': h}}))
check('a closed handle is an error', 'error' in r, r)

nics = ret({'execute': 'guest-network-get-interfaces'})
check('interfaces include loopback 127.0.0.1',
      any(a['ip-address'] == '127.0.0.1' for i in nics for a in i['ip-addresses']), [i['name'] for i in nics])
check('fsfreeze: freeze syncs, nothing frozen', ret({'execute': 'guest-fsfreeze-freeze'}) == 0)
check('fsfreeze: status thawed', ret({'execute': 'guest-fsfreeze-status'}) == 'thawed')
fsi = ret({'execute': 'guest-get-fsinfo'})
check('fsinfo has the root volume with sizes', any(f['mountpoint'] == '/' and f['total-bytes'] > 0 for f in fsi), fsi)
check('users answers a list', isinstance(ret({'execute': 'guest-get-users'}), list))
check('load has three averages', set(ret({'execute': 'guest-get-load'})) == {'load1', 'load5', 'load15'})
r = json.loads(ask({'execute': 'guest-suspend-ram'}))
check('suspend is Unsupported', r.get('error', {}).get('class') == 'Unsupported', r)
r = json.loads(ask({'execute': 'guest-set-user-password', 'arguments': {'username': 'no-such-user-here', 'password': 'eA==\n'}}))
check('a password with a newline in its base64 reaches the account lookup', 'no local account' in r.get('error', {}).get('desc', ''), r)
r = json.loads(ask({'execute': 'guest-set-user-password', 'arguments': {'username': 'x', 'password': 'eA==', 'crypted': True}}))
check('a crypted password is Unsupported', r.get('error', {}).get('class') == 'Unsupported', r)
r = json.loads(ask(raw=b'  {"execute": "guest-ping", "id": "a{b}\\"}"}  '))
check('braces and quotes inside strings, and the id echoed', r == {'return': {}, 'id': 'a{b}"}'}, r)
r = ask(raw=b'{"execute": "guest-pi' + b'\xff{"execute":"guest-sync","arguments":{"id":7}}')
check('0xFF throws away a half request', r == b'{"return":7}\n', r)
p.stdin.close()
p.wait()
check('ends at end of input', p.returncode == 0, p.returncode)


# answers kept small (a second agent with a 100 KB limit, as on a slow port)
p = subprocess.Popen([sys.argv[1], '--stdio', '--answer-max', '100000'], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
pid = ret({'execute': 'guest-exec', 'arguments': {'path': '/bin/sh', 'arg': ['-c', 'head -c 300000 /dev/zero; head -c 300000 /dev/zero >&2'],
                                                  'capture-output': True}})['pid']
for _ in range(100):
    raw = ask({'execute': 'guest-exec-status', 'arguments': {'pid': pid}})
    s = json.loads(raw)['return']
    if s['exited']:
        break
    time.sleep(0.05)
check('a big output is cut to fit the answer, and says so',
      len(raw) <= 100000 and s.get('out-truncated') and s.get('err-truncated') and len(base64.b64decode(s['out-data'])) > 40000,
      (len(raw), {k: v for k, v in s.items() if 'data' not in k}))
path = tempfile.mktemp()
open(path, 'wb').write(os.urandom(500000))
h = ret({'execute': 'guest-file-open', 'arguments': {'path': path}})
got = b''
while True:
    raw = ask({'execute': 'guest-file-read', 'arguments': {'handle': h, 'count': 1048576}})
    r = json.loads(raw)['return']
    check_size = len(raw) <= 100000
    got += base64.b64decode(r['buf-b64'])
    if r['eof'] or not r['count']:
        break
ret({'execute': 'guest-file-close', 'arguments': {'handle': h}})
check('a file read in pieces that fit, all of it', check_size and got == open(path, 'rb').read(), len(got))
os.unlink(path)
p.stdin.close()
p.wait()
print('all passed' if not fails else f'{fails} failed')
sys.exit(1 if fails else 0)
