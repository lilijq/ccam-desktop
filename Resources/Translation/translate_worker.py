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
INLINE_CODE = re.compile(r"(?P<ticks>`+)[^`\n]+?(?P=ticks)")


def opaque_spans(text):
    """Find code and fullwidth no-translate spans in source order.

    Code takes precedence: an unmatched ～ inside a fence or inline code must
    not shield later prose. Outside code, an unmatched delimiter protects the
    remaining input. The two fullwidth spellings never affect ASCII tildes.
    """
    position = 0
    while position < len(text):
        if position == 0 or text[position - 1] == "\n":
            newline = text.find("\n", position)
            line_end = len(text) if newline < 0 else newline + 1
            line = text[position:line_end]
            boundary = re.match(r"^[ \t]*(`{3,}|~{3,})", line)
            if boundary:
                start, fence = position, boundary.group(1)
                position = line_end
                while position < len(text):
                    newline = text.find("\n", position)
                    line_end = len(text) if newline < 0 else newline + 1
                    closing = re.match(r"^[ \t]*(`{3,}|~{3,})", text[position:line_end])
                    position = line_end
                    if closing and closing.group(1)[0] == fence[0] and len(closing.group(1)) >= len(fence):
                        break
                yield start, position, "code"
                continue
            if re.match(r"^(?: {4}|\t)\S", line):
                yield position, line_end, "code"
                position = line_end
                continue
        if text[position] == "`":
            inline = INLINE_CODE.match(text, position)
            if inline:
                yield position, inline.end(), "literal"
                position = inline.end()
                continue
        if text[position] == "～":
            delimiter = "～～" if text.startswith("～～", position) else "～"
            closing = text.find(delimiter, position + len(delimiter))
            end = len(text) if closing < 0 else closing + len(delimiter)
            yield position, end, "fullwidth"
            position = end
            continue
        position += 1


def fullwidth_body(value):
    """Remove only the no-translate wrapper; preserve its body byte-for-byte."""
    delimiter = "～～" if value.startswith("～～") else "～"
    body = value[len(delimiter):]
    return body[:-len(delimiter)] if body.endswith(delimiter) else body


def strip_no_translate_delimiters(text):
    """Handle no-inference inputs without altering spacing or code literals."""
    pieces, cursor = [], 0
    for start, end, kind in opaque_spans(text):
        if kind == "fullwidth":
            pieces.extend([text[cursor:start], fullwidth_body(text[start:end])])
            cursor = end
    pieces.append(text[cursor:])
    return "".join(pieces)


def shield(text, marker):
    """Mask original spans exactly once; generated markers never re-enter INLINE."""
    protected = {}
    next_marker = 0

    def mask_literal(value):
        nonlocal next_marker
        token = marker + str(next_marker)
        while token in text:
            next_marker += 1; token = marker + str(next_marker)
        next_marker += 1
        protected[token] = value
        return token

    pieces, cursor = [], 0
    for start, end, kind in opaque_spans(text):
        pieces.append(INLINE.sub(lambda match: mask_literal(match.group(0)), text[cursor:start]))
        value = fullwidth_body(text[start:end]) if kind == "fullwidth" else text[start:end]
        pieces.append(value if kind == "code" else mask_literal(value))
        cursor = end
    pieces.append(INLINE.sub(lambda match: mask_literal(match.group(0)), text[cursor:]))
    masked = "".join(pieces)
    if protected:
        # Adjacent islands, or English prose without spaces around ～...～,
        # still need separate model tokens. Only outer spacing may be added;
        # the protected body, including its internal newlines, is exact.
        pattern = re.compile("|".join(re.escape(key) for key in sorted(protected, key=len, reverse=True)))
        def separate(match):
            left = masked[match.start() - 1:match.start()] if match.start() else ""
            right = masked[match.end():match.end() + 1]
            return (" " if re.fullmatch(r"[A-Za-z0-9]", left) else "") + match.group(0) + (" " if re.fullmatch(r"[A-Za-z0-9]", right) else "")
        masked = pattern.sub(separate, masked)
    return masked, protected


def segments(text, source, marker="CCAM"):
    """Return context-bearing pieces and exact literals to restore afterwards."""
    result = []
    masked_text, protected = shield(text, marker)
    fence = None
    for line in masked_text.splitlines(keepends=True):
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
        masked = line[len(prefix):]
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
        # Sentence splitting can leave a protected-only clause after ordinary
        # prose. Do not ask the model to invent context for that lone marker.
        natural_core = re.sub(r"(?:CCAM|ZXQ)\d+", "", core)
        if not re.search(r"[A-Za-z]", natural_core) and not HAN.search(natural_core):
            pieces.append((False, core)); pieces.append((False, trailing)); continue
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


class TranslationFailure(ValueError):
    def __init__(self, code):
        self.code = code
        super().__init__(code)


def checked_segments(parts, protected, source, infer):
    """Retry only damaged segments; literal islands never enter fallback inference."""
    keys = sorted(protected, key=len, reverse=True)
    pattern = re.compile(r"(?<![A-Za-z0-9])(?:" + "|".join(map(re.escape, keys)) + r")(?![A-Za-z0-9])") if keys else None
    def tokens(value):
        return pattern.findall(value) if pattern else []
    def check(decoded, original):
        # Whitespace/case changes within a known marker are reversible. Never
        # guess missing numbers, drop a literal, or accept duplicated markers.
        decoded = re.sub(r"(?<![A-Za-z0-9])(CCAM|ZXQ)\s*([0-9]+)(?![A-Za-z0-9])",
                         lambda m: m[1].upper() + m[2] if m[1].upper() + m[2] in protected else m[0], decoded, flags=re.I)
        if sorted(tokens(decoded)) != sorted(tokens(original)) or sorted(re.findall(r"(?:CCAM|ZXQ)\d+", decoded)) != sorted(re.findall(r"(?:CCAM|ZXQ)\d+", original)):
            raise TranslationFailure("preservation_failed")
        return decoded
    indices = [i for i, part in enumerate(parts) if part[0]]
    outputs = infer([parts[i][1] for i in indices])
    if len(outputs) != len(indices):
        raise TranslationFailure("incomplete_result")
    for index, decoded in zip(indices, outputs):
        original = parts[index][1]
        try:
            decoded = check(decoded, original)
        except TranslationFailure:
            # Retry with local, low-numbered markers. Long replies otherwise
            # force a small model to carry ever larger marker numbers.
            if not pattern or not tokens(original):
                raise
            mapping = {}
            candidate = 0
            for token in tokens(original):
                while "ZXQ" + str(candidate) in original or any("ZXQ" + str(candidate) in v for v in protected.values()):
                    candidate += 1
                mapping["ZXQ" + str(candidate)] = token
                candidate += 1
            reverse = {value: key for key, value in mapping.items()}
            alternative = pattern.sub(lambda m: reverse[m[0]], original)
            retried = infer([alternative])
            if len(retried) != 1:
                raise TranslationFailure("incomplete_result")
            retry = retried[0]
            retry = re.sub(r"(?<![A-Za-z0-9])ZXQ\s*([0-9]+)(?![A-Za-z0-9])", r"ZXQ\1", retry, flags=re.I)
            try:
                decoded = check(restore(retry, mapping), original)
            except ValueError:
                # Deterministic fallback: translate prose fragments around
                # protected values, then join the exact literal anchors back.
                chunks, slots, cursor = [], [], 0
                for match in pattern.finditer(original):
                    chunks.append((True, original[cursor:match.start()]))
                    chunks.append((False, match[0])); cursor = match.end()
                chunks.append((True, original[cursor:]))
                split = []
                for enabled, value in chunks:
                    split.extend(prose(value, source) if enabled else [(False, value)])
                slots = [i for i, (enabled, _) in enumerate(split) if enabled]
                values = infer([split[i][1] for i in slots])
                if len(values) != len(slots):
                    raise TranslationFailure("incomplete_result")
                for i, value in zip(slots, values):
                    # A new marker hallucinated by fragment inference is never
                    # allowed to introduce or duplicate code in the result.
                    if re.search(r"(?:CCAM|ZXQ)\d+", value):
                        raise TranslationFailure("preservation_failed")
                    split[i] = (False, value)
                decoded = check("".join(value for _, value in split), original)
        parts[index] = (False, decoded)
    return restore("".join(value for _, value in parts), protected)


def translate(text, source, target, home):
    if (home / "native.json").is_file():
        import importlib.util
        spec = importlib.util.spec_from_file_location("ccam_native_translation", Path(__file__).with_name("native_translation.py"))
        native = importlib.util.module_from_spec(spec); spec.loader.exec_module(native)
        try:
            return native.translate(text, source, target, home, __import__("types").SimpleNamespace(**globals()))
        except TranslationFailure:
            raise
        except (OSError, ValueError) as error:
            code = str(error)
            raise TranslationFailure(code if code in {"component_unavailable", "native_unavailable", "native_start_failed", "incomplete_result", "empty_result"} else "native_failed") from None
    parts, protected = segments(text, source)
    if not any(enabled for enabled, _ in parts):
        return strip_no_translate_delimiters(text)
    import ctranslate2
    import sentencepiece

    package = home / "models" / (source + "_" + target)
    metadata = json.loads((package / "metadata.json").read_text(encoding="utf-8"))
    if metadata.get("from_code") != source or metadata.get("to_code") != target:
        raise TranslationFailure("component_unavailable")
    tokenizer = sentencepiece.SentencePieceProcessor(model_file=str(package / "sentencepiece.model"))
    translator = ctranslate2.Translator(str(package / "model"), device="cpu", compute_type="int8", intra_threads=2, inter_threads=1)
    prefix = metadata.get("target_prefix", "")
    def infer(values):
        if not values:
            return []
        tokenized = [tokenizer.encode(value, out_type=str) for value in values]
        if any(len(tokens) > 512 for tokens in tokenized):
            raise TranslationFailure("segment_too_long")
        batches = translator.translate_batch(tokenized, target_prefix=[[prefix]] * len(tokenized) if prefix else None,
                                             beam_size=4, num_hypotheses=1, replace_unknowns=True, length_penalty=0.2,
                                             max_batch_size=32, max_input_length=0, max_decoding_length=1024)
        results = []
        for batch in batches:
            decoded = tokenizer.decode(batch.hypotheses[0]).replace("▁", " ").strip()
            if prefix and decoded.startswith(prefix):
                decoded = decoded[len(prefix):].lstrip()
            if not decoded:
                raise TranslationFailure("empty_result")
            results.append(decoded)
        return results
    return checked_segments(parts, protected, source, infer)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--home", required=True, type=Path)
    args = parser.parse_args()
    if (args.home / "native.json").is_file():
        import os, signal
        # Foundation.Process may already launch us as a process-group leader.
        # setsid() would then fail with EPERM; the group is already isolated.
        if os.getpgrp() != os.getpid(): os.setsid()
        signal.signal(signal.SIGTERM, lambda *_: sys.exit(1))
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
    except Exception as error:
        code = error.code if isinstance(error, TranslationFailure) else "engine_failed"
        sys.stdout.write(json.dumps({"error": code}))
        # Never echo the prompt, local paths, configuration or third-party errors.
        sys.stderr.write("Local translation failed.\n")
        sys.exit(1)
