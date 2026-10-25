#!/usr/bin/env python3
"""Local CTranslate2 inference using the pinned Argos Translate 1.9 models.

There is intentionally no downloader, URL client, credential access or model
auto-discovery here. stdin/stdout are one bounded JSON request and response.
"""
import argparse
import json
import re
import sys
from pathlib import Path

MAX_CHARS = 40_000
HAN = re.compile(r"[\u3400-\u4dbf\u4e00-\u9fff\U00020000-\U0002ffff]")
# Code, links and identifiable paths are replaced by checked placeholders before
# inference, so the surrounding sentence keeps its grammatical context.
INLINE = re.compile(
    r"(?P<code>`+)[^`\n]+?(?P=code)"
    r"|https?://[^\s<>\[\]()]+"
    r"|(?:[A-Za-z]:\\|(?:~|\.)?/|\.\./)[^\s<>\[\](){},;，。；]+"
    r"|\b[\w-]+(?:/[\w.-]+)+\b"
    r"|\b[\w-]+\.(?:rs|swift|js|jsx|ts|tsx|py|go|java|kt|json|ya?ml|toml|md|txt|sh|html|css|vue|svelte|c|cpp|h|sql|lock)\b"
    r"|\b[A-Za-z][A-Za-z0-9]*(?:_[A-Za-z0-9_]+|::[A-Za-z0-9_:]+|[a-z][A-Z][A-Za-z0-9]*)\b"
    r"|\b[A-Z][A-Z0-9]*\d[A-Z0-9]*\b"
    r"|(?<!\w)--?[A-Za-z][A-Za-z0-9_-]*(?:=[^\s,;，。；]+)?"
    r"|\b(?:cargo (?:build|test|run|clippy|fmt)|git (?:status|diff|pull|push|commit|log)|npm (?:install|test|run [\w:-]+))\b"
)
PREFIX = re.compile(r"^(\s*(?:(?:#{1,6}|>|[-*+]|\d+[.)])\s+)?)")


def segments(text, source, marker="CCAM"):
    """Return context-bearing pieces and exact literals to restore afterwards."""
    result = []
    protected = {}
    next_marker = 0
    fence = None
    for line in text.splitlines(keepends=True):
        boundary = re.match(r"^\s*(`{3,}|~{3,})", line)
        if fence:
            result.append((False, line))
            if boundary and boundary.group(1)[0] == fence[0] and len(boundary.group(1)) >= len(fence):
                fence = None
            continue
        if boundary:
            fence = boundary.group(1); result.append((False, line)); continue
        if re.match(r"^(?: {4}|\t)\S", line):
            result.append((False, line)); continue
        prefix = PREFIX.match(line).group(0)
        result.append((False, prefix))
        content = line[len(prefix):]
        def mask(match):
            nonlocal next_marker
            token = marker + str(next_marker)
            while token in text:
                next_marker += 1; token = marker + str(next_marker)
            next_marker += 1
            protected[token] = match.group(0)
            return token
        masked = INLINE.sub(mask, content)
        # Pipe tables have independent cells. Keep Markdown delimiters and
        # alignment rows out of the model, including pipes inside code literals.
        if masked.lstrip().startswith("|") and masked.count("|") >= 2:
            for cell in re.split(r"(?<!\\)(\|)", masked):
                result.extend([(False, cell)] if cell == "|" else prose(cell, source))
        else:
            result.extend(prose(masked, source))
    return result, protected


def restore(text, protected):
    """Reject missing/duplicated placeholders instead of corrupting user code."""
    if not protected:
        return text
    pattern = re.compile(r"(?<![A-Za-z0-9])(?:" + "|".join(re.escape(key) for key in protected) + r")(?![A-Za-z0-9])")
    found = pattern.findall(text)
    if len(found) != len(protected) or set(found) != set(protected):
        raise ValueError("translation did not preserve protected literals")
    return pattern.sub(lambda match: protected[match.group(0)], text)


def prose(text, source):
    if not text:
        return []
    # A cell/line made only of protected literals has nothing to translate.
    # Sending an isolated placeholder to a small model can alter its spelling.
    natural_text = re.sub(r"(?:CCAM|ZXQ)\d+", "", text)
    if not re.search(r"[A-Za-z]", natural_text) and not HAN.search(natural_text):
        return [(False, text)]
    if (source == "zh" and not HAN.search(text)) or (source == "en" and not re.search(r"[A-Za-z]", text)):
        return [(False, text)]
    # Preserve leading/trailing whitespace exactly. Keep sentence boundaries so
    # the model is never allowed to silently truncate a long prompt.
    pieces = []
    for piece in re.split(r"(?<=[。！？!?])|(?<=[.;])(?=\s)", text):
        if not piece:
            continue
        if not piece.strip():
            pieces.append((False, piece)); continue
        leading = piece[:len(piece) - len(piece.lstrip())]
        trailing = piece[len(piece.rstrip()):]
        core = piece.strip()
        pieces.append((False, leading))
        # Very long natural-language clauses are split at whitespace, or at a
        # character boundary for Chinese. This is documented, not silent loss.
        while len(core) > 500:
            split = core.rfind(" ", 100, 500)
            split = split if split > 0 else 500
            for token in re.finditer(r"(?:CCAM|ZXQ)\d+", core[:510]):
                if token.start() < split < token.end():
                    split = token.start(); break
            pieces.append((True, core[:split])); pieces.append((False, " "))
            core = core[split:].lstrip()
        if core:
            pieces.append((True, core))
        pieces.append((False, trailing))
    return pieces


def translate(text, source, target, home):
    import ctranslate2
    import sentencepiece

    package = home / "models" / (source + "_" + target)
    metadata = json.loads((package / "metadata.json").read_text(encoding="utf-8"))
    if metadata.get("from_code") != source or metadata.get("to_code") != target:
        raise ValueError("model direction mismatch")
    tokenizer = sentencepiece.SentencePieceProcessor(model_file=str(package / "sentencepiece.model"))
    translator = ctranslate2.Translator(str(package / "model"), device="cpu", compute_type="int8", intra_threads=2, inter_threads=1)
    # These simple ASCII markers survived the bilingual fixture corpus. If one
    # spelling is altered by the model, retry a different spelling once. Never
    # fall back to isolated grammar fragments or send a damaged code literal.
    for marker in ["CCAM", "ZXQ"]:
        parts, protected = segments(text, source, marker)
        indices = [i for i, part in enumerate(parts) if part[0]]
        if not indices:
            return text
        tokenized = [tokenizer.encode(parts[i][1], out_type=str) for i in indices]
        if any(len(tokens) > 512 for tokens in tokenized):
            raise ValueError("a text segment exceeds the model context")
        prefix = metadata.get("target_prefix", "")
        batches = translator.translate_batch(tokenized, target_prefix=[[prefix]] * len(tokenized) if prefix else None,
                                             beam_size=4, num_hypotheses=1, replace_unknowns=True, length_penalty=0.2,
                                             max_batch_size=32, max_input_length=0, max_decoding_length=1024)
        for i, batch in zip(indices, batches):
            decoded = tokenizer.decode(batch.hypotheses[0]).replace("▁", " ").strip()
            if prefix and decoded.startswith(prefix):
                decoded = decoded[len(prefix):].lstrip()
            if not decoded:
                raise ValueError("empty translation")
            parts[i] = (False, decoded)
        try:
            return restore("".join(part[1] for part in parts), protected)
        except ValueError:
            if marker == "ZXQ":
                raise


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--home", required=True, type=Path)
    args = parser.parse_args()
    raw = sys.stdin.buffer.read(256_001)
    if len(raw) > 256_000:
        raise ValueError("invalid request size")
    request = json.loads(raw)
    text, source, target = request["text"], request["source"], request["target"]
    if not isinstance(text, str) or len(text) > MAX_CHARS or len(text.encode("utf-8")) > 160_000:
        raise ValueError("invalid input size")
    if (source, target) not in [("zh", "en"), ("en", "zh")]:
        raise ValueError("unsupported direction")
    result = translate(text, source, target, args.home)
    encoded = json.dumps({"translation": result}, ensure_ascii=False).encode("utf-8")
    if len(encoded) > 640_000:
        raise ValueError("invalid output size")
    sys.stdout.buffer.write(encoded)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        # Never echo the prompt, local paths, configuration or third-party errors.
        sys.stderr.write("Local translation failed.\n")
        sys.exit(1)
