import json, re, shutil, subprocess
from pathlib import Path
binary = shutil.which('ccam') or str(Path.home()/'.local/bin/ccam')
paths = json.loads(Path('.build-cache/command-paths.json').read_text())
def subcommands(prefix):
    text = subprocess.check_output([binary,*prefix,'--help'],text=True)
    section = text.partition('Available Commands:')[2].partition('\nFlags:')[0]
    return re.findall(r'^  ([a-z][a-z-]+)\s{2,}',section,re.M)
for command in subcommands([]):
    assert any(p and p[0]==command for p in paths), f'Missing button: {command}'
for group in ['group','mcp','shims','statusline']:
    for command in subcommands([group]):
        assert any(p[:2]==[group,command] for p in paths),f'Missing button: {group} {command}'
print(f'PASS: {len(paths)} categorized buttons cover the installed CCAM command tree')
