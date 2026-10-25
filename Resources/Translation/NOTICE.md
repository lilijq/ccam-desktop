# Local translation components

CCAM's small Python adapter performs local inference with these open-source components:

- [CTranslate2 4.4.0](https://github.com/OpenNMT/CTranslate2/tree/v4.4.0), MIT, OpenNMT contributors.
- [SentencePiece 0.2.0](https://github.com/google/sentencepiece/tree/v0.2.0), Apache License 2.0, Google contributors.
- [NumPy 1.26.4](https://github.com/numpy/numpy/tree/v1.26.4), BSD-3-Clause.
- [PyYAML 6.0.2](https://github.com/yaml/pyyaml/tree/6.0.2), MIT.
- [Setuptools 75.3.2](https://github.com/pypa/setuptools/tree/v75.3.2), MIT.

Dependency distributions retain their original license files in the isolated Python environment. They are downloaded from PyPI only during explicit installation; they are not vendored into CCAM source.

The Chinese ↔ English 1.9 model packages are distributed by [Argos Translate](https://github.com/argosopentech/argospm-index). Both package README files identify the original OPUS-MT models as **CC BY 4.0**. Attribution: Jörg Tiedemann and Santhosh Thottingal, “OPUS-MT — Building open translation services for the World,” Proceedings of EAMT 2020, Lisbon, Portugal. The original package README is retained beside each installed model. See [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) for license terms.

Pinned packages:

| Direction | Package | SHA-256 |
| --- | --- | --- |
| Chinese → English | `https://argos-net.com/v1/translate-zh_en-1_9.argosmodel` | `62e7af5a3a48b530e47b7b3e5c78c2de79073ecd815750d2bf3ab35b4a67da2d` |
| English → Chinese | `https://argos-net.com/v1/translate-en_zh-1_9.argosmodel` | `433e7c4f034d87fbe2353161e05f18646d7999452f801a4e1f0378522b9850ab` |

The model weights are not modified. The adapter excludes the optional Stanza sentence tokenizer and uses bounded punctuation/paragraph segmentation, preserving fenced code, inline code and identifiable URLs, paths and identifiers. This changes segmentation behavior from the complete Argos application and can affect translation quality. Long clauses may be split; machine translation can misinterpret technical prose. CCAM retains originals alongside translated text.

Inference does not call a translation API or use a Claude account. The setup utility requires the configured HTTP proxy to download the models and Python wheels; the inference subprocess inherits no proxy or account credentials and contains no download path.
