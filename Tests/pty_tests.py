#!/usr/bin/env python3
"""Test the app's PTY adapter without touching real CCAM accounts."""
import os
import select
import subprocess
import tempfile
import time

def start(args):
    return subprocess.Popen(['/usr/bin/script', '-q', '/dev/null', *args],
                            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)

def until(p, token, seconds=6):
    output = b''
    deadline = time.monotonic() + seconds
    while token not in output and time.monotonic() < deadline:
        readable, _, _ = select.select([p.stdout], [], [], 0.2)
        if readable:
            chunk = os.read(p.stdout.fileno(), 4096)
            if not chunk:
                break
            output += chunk
    assert token in output, repr(output)
    return output

with tempfile.TemporaryDirectory(prefix='ccam-desktop-test-') as directory:
    stub = os.path.join(directory, 'fake-ccam')
    with open(stub, 'w') as f:
        f.write('''#!/bin/sh
test -t 0 || exit 95
test -t 1 || exit 96
case "$1" in
  confirm) printf 'Continue? '; read answer; printf 'answer=%s\\n' "$answer"; test "$answer" = y ;;
  fail) printf 'failure-message\\n'; exit 7 ;;
  cancel) trap 'echo interrupted; exit 130' INT; echo waiting; while :; do sleep 1; done ;;
  echo) printf '%s\\n' "$2" ;;
esac
''')
    os.chmod(stub, 0o700)
    p = start([stub, 'confirm'])
    until(p, b'Continue?')
    p.stdin.write(b'y\n'); p.stdin.flush()
    until(p, b'answer=y')
    assert p.wait(timeout=6) == 0
    p = start([stub, 'fail'])
    until(p, b'failure-message')
    assert p.wait(timeout=6) == 7
    p = start([stub, 'echo', "space 'quotes' $(no-command)"])
    until(p, b"space 'quotes' $(no-command)")
    assert p.wait(timeout=6) == 0
    p = start([stub, 'cancel'])
    until(p, b'waiting')
    p.stdin.write(b'\x03'); p.stdin.flush()
    until(p, b'interrupted')
    assert p.wait(timeout=6) == 130
print('PASS: PTY detection, interactive confirmation, child exit status, argument boundaries, cancellation')
