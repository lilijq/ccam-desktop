#!/usr/bin/env python3
"""Explicit, proxy-only installation of CCAM's local translation runtime.

Usage: HTTPS_PROXY=http://127.0.0.1:PORT /usr/bin/python3 scripts/setup_translation.py
Inference itself does not use the network. No account data is read here.
"""
import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.parse
import urllib.request
import zipfile
from pathlib import Path

DEPENDENCIES = ["setuptools==75.3.2", "numpy==1.26.4", "PyYAML==6.0.2", "ctranslate2==4.4.0", "sentencepiece==0.2.0"]
# Model URLs come from the official Argos package index. Checksums pin exactly
# the reviewed package bytes, rather than trusting a mutable release filename.
MODELS = {
    "zh_en": {"filename": "translate-zh_en-1_9.argosmodel", "sha256": "62e7af5a3a48b530e47b7b3e5c78c2de79073ecd815750d2bf3ab35b4a67da2d"},
    "en_zh": {"filename": "translate-en_zh-1_9.argosmodel", "sha256": "433e7c4f034d87fbe2353161e05f18646d7999452f801a4e1f0378522b9850ab"},
}


def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def extract_model(archive, destination, pair):
    with zipfile.ZipFile(archive) as package:
        members = package.infolist()
        if len(members) > 2000 or sum(item.file_size for item in members) > 2_000_000_000:
            raise ValueError("Model archive exceeds installation limits")
        for item in members:
            path = Path(item.filename)
            if path.is_absolute() or ".." in path.parts or ((item.external_attr >> 16) & 0o170000) == 0o120000:
                raise ValueError("Unsafe model archive entry")
        metadata_files = [item for item in members if Path(item.filename).name == "metadata.json"]
        if len(metadata_files) != 1:
            raise ValueError("Model archive has ambiguous metadata")
        metadata_entry = metadata_files[0]
        metadata = json.loads(package.read(metadata_entry))
        if metadata.get("from_code") + "_" + metadata.get("to_code") != pair:
            raise ValueError("Model direction does not match its pinned archive")
        prefix = Path(metadata_entry.filename).parent
        with tempfile.TemporaryDirectory(prefix=".model-", dir=destination.parent) as temp:
            stage = Path(temp)
            for item in members:
                try:
                    relative = Path(item.filename).relative_to(prefix)
                except ValueError:
                    continue
                if not relative.parts or item.is_dir():
                    continue
                # Stanza is not needed by this lightweight inference adapter.
                if relative.parts[0] != "model" and relative.name not in ["sentencepiece.model", "metadata.json", "README", "README.md", "LICENSE", "LICENSE.txt"]:
                    continue
                target = stage / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                with package.open(item) as source, target.open("wb") as output:
                    shutil.copyfileobj(source, output)
            for required in ["model/model.bin", "sentencepiece.model", "metadata.json"]:
                if not (stage / required).is_file():
                    raise ValueError("Pinned package is missing " + required)
            if destination.exists():
                shutil.rmtree(destination)
            shutil.copytree(stage, destination)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--home", type=Path, default=Path(os.environ.get("CCAM_TRANSLATION_HOME", str(Path.home() / "Library/Application Support/CCAM Desktop/Translation"))))
    parser.add_argument("--models-dir", type=Path, help="Use already-downloaded pinned archives from this directory")
    parser.add_argument("--worker", type=Path)
    args = parser.parse_args()
    if sys.version_info < (3, 9):
        raise ValueError("Python 3.9 or newer is required")
    proxy = os.environ.get("HTTPS_PROXY") or os.environ.get("https_proxy")
    parsed = urllib.parse.urlsplit(proxy or "")
    if parsed.scheme not in ("http", "https") or not parsed.hostname or parsed.username or parsed.password:
        raise ValueError("Set HTTPS_PROXY to the configured HTTP proxy; direct installation is disabled")
    if any(not re.fullmatch(r"[0-9a-f]{64}", spec["sha256"]) for spec in MODELS.values()):
        raise ValueError("Model checksums have not been finalized")
    home = args.home.expanduser().resolve()
    home.mkdir(parents=True, exist_ok=True)
    os.chmod(home, 0o700)
    (home / "models").mkdir(exist_ok=True)
    downloads = args.models_dir or (home / "downloads")
    downloads.mkdir(parents=True, exist_ok=True)
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({"https": proxy, "http": proxy}))
    archives = {}
    for pair, spec in MODELS.items():
        archive = downloads / spec["filename"]
        if not archive.exists():
            print("Downloading pinned model " + pair, flush=True)
            partial = archive.with_suffix(".partial")
            total = 0
            try:
                with opener.open("https://argos-net.com/v1/" + spec["filename"], timeout=90) as response, partial.open("wb") as output:
                    while True:
                        chunk = response.read(1024 * 1024)
                        if not chunk:
                            break
                        total += len(chunk)
                        if total > 600_000_000:
                            raise ValueError("Model download exceeds size limit")
                        output.write(chunk)
                partial.replace(archive)
            finally:
                if partial.exists():
                    partial.unlink()
        if digest(archive) != spec["sha256"]:
            raise ValueError("Model checksum mismatch: " + pair)
        archives[pair] = archive
    marker = home / "installed.json"
    if marker.exists():
        marker.unlink()
    venv = home / "venv"
    if not (venv / "bin/python3").is_file():
        subprocess.run([sys.executable, "-I", "-m", "venv", str(venv)], check=True)
    python = venv / "bin/python3"
    # Ignore local pip indexes/config and pass a single approved proxy. No shell.
    env = {"HOME": str(home), "PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8", "HTTPS_PROXY": proxy, "HTTP_PROXY": proxy}
    subprocess.run([str(python), "-I", "-m", "pip", "--isolated", "--disable-pip-version-check", "--proxy", proxy,
                    "install", "--index-url", "https://pypi.org/simple", "--only-binary=:all:", "--no-deps"] + DEPENDENCIES,
                   env=env, check=True)
    for pair, archive in archives.items():
        extract_model(archive, home / "models" / pair, pair)
    worker = args.worker
    if worker is None:
        source_worker = Path(__file__).resolve().parents[1] / "Resources/Translation/translate_worker.py"
        worker = source_worker if source_worker.is_file() else Path(__file__).resolve().parent / "translate_worker.py"
    inference_env = {"HOME": str(home), "PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8", "OMP_NUM_THREADS": "2"}
    for source, target, prompt in [("zh", "en", "请检查这个项目。"), ("en", "zh", "Please check this project.")]:
        result = subprocess.run([str(python), "-I", "-B", str(worker), "--home", str(home)], input=json.dumps({"source": source, "target": target, "text": prompt}).encode(),
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=inference_env, timeout=90, check=True)
        if not json.loads(result.stdout).get("translation"):
            raise ValueError("Local inference validation failed")
        print("Validated local inference: " + source + " → " + target, flush=True)
    temporary = home / "installed.json.tmp"
    temporary.write_text(json.dumps({"version": 1, "engine": "CTranslate2 + Argos 1.9", "dependencies": DEPENDENCIES, "models": MODELS}, indent=2), encoding="utf-8")
    temporary.replace(marker)
    print("Local translation is ready.")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        # Package manager errors intentionally show no account/token environment.
        sys.stderr.write("Translation installation failed: " + str(error) + "\n")
        sys.exit(1)
