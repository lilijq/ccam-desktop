#!/usr/bin/env python3
"""Exercise the installed CCAM using its documented CCAM_HOME test isolation.
No login occurs and no real account, settings folder, or shortcut is changed.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

binary = shutil.which('ccam') or str(Path.home() / '.local/bin/ccam')
with tempfile.TemporaryDirectory(prefix='ccam-desktop-integration-') as directory:
    root = Path(directory)
    environment = dict(os.environ, CCAM_HOME=directory, NO_COLOR='1', TERM='dumb')
    count = 0
    def call(*args):
        global count
        count += 1
        result = subprocess.run([binary, *args], env=environment, cwd=directory,
                                stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=20)
        assert result.returncode == 0, (args, result.stdout, result.stderr)
        return result.stdout
    assert json.loads(call('list', '--json')) in (None, [])
    call('add', 'work', '--no-login', '--no-group')
    call('add', 'personal', '--no-login', '--no-group')
    accounts = json.loads(call('list', '--json'))
    assert all(a['dir'].startswith(directory + '/') for a in accounts), 'isolation failed'
    call('use', 'personal')
    assert next(a for a in json.loads(call('list', '--json')) if a['default'])['name'] == 'personal'
    call('rename', 'personal', 'side')
    call('shortcut', 'side', 'ccdesktoptest')
    assert (root/'bin/ccdesktoptest').exists()
    call('shortcut', 'side', '--remove')
    call('--dry-run', 'group', 'add', 'team', '--items', 'settings,memory', '--members', 'work,side')
    assert not (root/'data/groups/team').exists(), 'dry run unexpectedly wrote files'
    call('group', 'add', 'team', '--items', 'settings,memory', '--members', 'work,side', '--yes')
    assert 'team' in call('group', 'list')
    call('group', 'set', 'team', '--add', 'mcp', '--yes')
    call('mcp', 'add-json', 'fixture', '{"command":"/usr/bin/true","args":[]}', '--group', 'team')
    assert 'fixture' in call('mcp', 'list')
    call('mcp', 'remove', 'fixture', '--group', 'team')
    project = root / "project space ' quote"
    project.mkdir()
    call('folder', 'work', str(project))
    assert str(project) in call('folder')
    call('folder', '--remove', str(project))
    call('share', 'work')
    call('group', 'leave', 'team', 'side', '--yes')
    call('group', 'join', 'team', 'side', '--yes')
    call('group', 'rename', 'team', 'team2')
    call('group', 'remove', 'team2', '--leave', '--yes')
    data = json.loads(call('usage', '--json'))
    assert all(a['status'] == 'logged_out' for a in data)
    call('ext', '--json')
    # Removing the unlogged-in test profiles is safe inside CCAM_HOME.
    call('remove', 'side', '--yes')
    assert len(json.loads(call('list', '--json'))) == 1
    print(f'PASS: {count} isolated real-CCAM commands (account switching, rename, shortcuts, groups, dry-run, MCP, folder bindings, usage, extensions, removal)')
