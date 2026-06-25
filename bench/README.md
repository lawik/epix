# Injection-detector benchmarks

Measures `Epix.InjectionDetector` against public prompt-injection datasets.

```sh
mix run bench/injection_eval.exs                 # default sets (deepset + safeguard)
mix run bench/injection_eval.exs deepset         # one set by slug
mix run bench/injection_eval.exs jayavibhav      # the large set, on demand
```

This script evaluates only the **offline `basic_detect/1` heuristics** — no model
calls, no API key needed. The model stage is covered by the tagged live tests
(`mix test --include llm_live`).

## Data is resolved, never vendored

Nothing under `bench/data/` is committed (it is gitignored). On first run each
dataset is downloaded from the public Hugging Face **datasets-server** (no auth)
and cached as `bench/data/<slug>.jsonl`; later runs read the cache. Delete a file
to re-fetch.

The built-in downloader pages the rows API at 100 rows/request, so its cost
scales with row count — fine for the small/medium sets, slow for the 327k-row
`jayavibhav`. For that one, the parquet files are a faster route:

```sh
# 1. discover the parquet URLs (auto-converted, public)
curl -s "https://datasets-server.huggingface.co/parquet?dataset=jayavibhav/prompt-injection" \
  | python3 -c "import sys,json;[print(f['url']) for f in json.load(sys.stdin)['parquet_files']]"

# 2. download + convert to the JSONL this harness reads (needs pandas+pyarrow)
python3 - <<'PY'
import pandas as pd
url = "https://huggingface.co/datasets/jayavibhav/prompt-injection/resolve/refs%2Fconvert%2Fparquet/default/test/0000.parquet"
df = pd.read_parquet(url)[["text", "label"]]
df.to_json("bench/data/jayavibhav.jsonl", orient="records", lines=True)
PY
```

## Datasets

| slug | source | rows | notes |
|------|--------|------|-------|
| `deepset` | [`deepset/prompt-injections`](https://huggingface.co/datasets/deepset/prompt-injections) | 662 | canonical, **multilingual** |
| `safeguard` | [`xTRam1/safe-guard-prompt-injection`](https://huggingface.co/datasets/xTRam1/safe-guard-prompt-injection) | ~10k (test ~2k) | broad mix |
| `jayavibhav` | [`jayavibhav/prompt-injection`](https://huggingface.co/datasets/jayavibhav/prompt-injection) | ~327k | large; shares lineage with `safeguard` |

Label convention: `1` = injection (positive), `0` = legitimate.

## ONNX classifier stage (`bench/onnx_eval.exs`)

Scores the ProtectAI DeBERTa-v3 prompt-injection classifier — run on **CPU via
Ortex, no Python** — on the same datasets. First download the model + tokenizer
into `bench/data/protectai/` (also gitignored, ~740MB):

```sh
base="https://huggingface.co/protectai/deberta-v3-base-prompt-injection-v2/resolve/main/onnx"
mkdir -p bench/data/protectai
for f in model.onnx tokenizer.json config.json; do
  curl -sL "$base/$f" -o "bench/data/protectai/$f"
done

mix run bench/injection_eval.exs   # populate dataset caches first
mix run bench/onnx_eval.exs        # then score the classifier
```

Baseline (this model vs `basic_detect/1`):

| stage | deepset recall | safeguard recall | precision | FPR | latency |
|-------|---------------|------------------|-----------|-----|---------|
| regex `basic_detect` | 23.6% | 31.8% | 88–100% | 0–1.9% | <1ms |
| ONNX deberta-v3 | 41.4% | **84.0%** | 96–99.6% | 0.1–1.0% | 30–86ms CPU |

The classifier roughly doubles-to-triples recall at equal-or-better precision.
deepset stays lower because it is multilingual (German) and this model is
English-only — the same blind spot as the regex.

## Caveat: domain mismatch

These datasets classify **user → model prompts**. `Epix.InjectionDetector`
targets **untrusted fetched content** (web pages, tool output). The two overlap
but disagree at the edges: a prompt like *"I want you to act as a debate coach"*
is a normal user request (labeled benign here) yet a red flag inside a fetched
web page. So treat these numbers as a useful lower bound on recall and an upper
bound on false positives for the real use case — not a verdict on it.
