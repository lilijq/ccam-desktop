#!/usr/bin/env python3
"""Explicit proxy-only native model install. Inference is separately offline."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import posixpath
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.parse
import urllib.request

ENGINE = 'Hy-MT2-1.8B-Q8_0'
REVISION = 'a0c709d9fac510f2c807aa3af52872340dc37a4a'
MODEL = ENGINE + '.gguf'
MODEL_HASH = '5c3fe0b1408a5ceb0143184ef247b11b579c525f4b02b060e6c851bb76fef1a4'
RUNTIME = 'llama-b11871-bin-macos-arm64.tar.gz'
RUNTIME_HASH = '389977376e89be4708e3e20c2f0c70b7252d15f5b848e754a26cf5fb06748d7c'


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        for data in iter(lambda: f.read(8*1024*1024), b''): h.update(data)
    return h.hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--home', type=Path, required=True)
    parser.add_argument('--data-root', type=Path, required=True)
    parser.add_argument('--worker', type=Path, required=True)
    args = parser.parse_args()
    if os.uname().machine != 'arm64': raise ValueError('Apple Silicon required')
    root = args.data_root.expanduser().absolute()
    if len(root.parts) < 3: raise ValueError('Choose a dedicated data folder')
    if root.parts[1] == 'Volumes' and not Path(*root.parts[:3]).is_mount(): raise ValueError('External drive is not mounted')
    proxy = os.environ.get('HTTPS_PROXY', '')
    parsed = urllib.parse.urlsplit(proxy)
    if parsed.scheme not in ('http', 'https') or not parsed.hostname or parsed.username or parsed.password:
        raise ValueError('Configured HTTP proxy required for installation')
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({'http': proxy, 'https': proxy}))
    for folder in ['models', 'downloads', 'licenses']: (root / folder).mkdir(parents=True, exist_ok=True)
    def download(url, path, sha=None, limit=2_000_000_000):
        if path.is_file() and (sha is None or digest(path) == sha): return
        print('Downloading pinned model/component', flush=True)
        partial = path.with_suffix(path.suffix + '.download')
        try:
            with opener.open(url, timeout=90) as response, partial.open('wb') as output:
                total = 0
                for block in iter(lambda: response.read(1024*1024), b''):
                    total += len(block)
                    if total > limit: raise ValueError('Download exceeds expected limit')
                    output.write(block)
            if sha and digest(partial) != sha: raise ValueError('Download checksum mismatch')
            partial.replace(path)
        finally:
            if partial.exists(): partial.unlink()
    download('https://huggingface.co/tencent/Hy-MT2-1.8B-GGUF/resolve/' + REVISION + '/' + MODEL, root / 'models' / MODEL, MODEL_HASH)
    download('https://github.com/ggml-org/llama.cpp/releases/download/b11871/' + RUNTIME, root / 'downloads' / RUNTIME, RUNTIME_HASH, 100_000_000)
    runtime = root / 'runtime'
    runtime.mkdir(exist_ok=True)
    with tarfile.open(root / 'downloads' / RUNTIME) as package:
        for member in package.getmembers():
            if member.name.startswith('/') or '..' in Path(member.name).parts: raise ValueError('Invalid runtime entry')
            if member.issym() or member.islnk():
                target = posixpath.normpath(posixpath.join(posixpath.dirname(member.name), member.linkname))
                if target.startswith('/') or target.startswith('../'): raise ValueError('Invalid runtime link')
            elif not member.isfile() and not member.isdir(): raise ValueError('Invalid runtime file type')
        package.extractall(runtime)
    download('https://huggingface.co/tencent/Hy-MT2-1.8B-GGUF/resolve/' + REVISION + '/LICENSE.txt', root / 'licenses/Hy-MT2-LICENSE.txt', limit=100_000)
    download('https://huggingface.co/tencent/Hy-MT2-1.8B-GGUF/resolve/' + REVISION + '/README.md', root / 'licenses/Hy-MT2-README.md', limit=200_000)
    config = {'version': 2, 'engine': ENGINE, 'dataRoot': str(root), 'revision': REVISION, 'modelSHA256': MODEL_HASH, 'runtimeSHA256': RUNTIME_HASH}
    # Validate before changing the active backend. A failed install leaves the old configuration intact.
    with tempfile.TemporaryDirectory(prefix='ccam-native-verify-') as temp:
        test_home = Path(temp); (test_home / 'native.json').write_text(json.dumps(config))
        # Stay in the install supervisor's process group so cancellation also
        # terminates the temporary server. Inference has bounded startup/HTTP timeouts.
        spec = importlib.util.spec_from_file_location('ccam_install_check', args.worker)
        worker = importlib.util.module_from_spec(spec); spec.loader.exec_module(worker)
        result = worker.translate('The repository contains three commits. Do not deploy.', 'en', 'zh', test_home)
        if not result.strip(): raise ValueError('Native validation failed')
    print('Validated local inference', flush=True)
    args.home.mkdir(parents=True, exist_ok=True)
    temporary = args.home / 'native.json.tmp'; temporary.write_text(json.dumps(config, indent=2)); temporary.chmod(0o600)
    temporary.replace(args.home / 'native.json')
    (root / 'installation.json').write_text(json.dumps(config, indent=2))
    print('Native translation is ready.', flush=True)


if __name__ == '__main__':
    try: main()
    except Exception as error:
        sys.stderr.write('Native translation installation failed: ' + type(error).__name__ + '\n'); sys.exit(1)
