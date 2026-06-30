#!/bin/bash
# fetch-corpora.sh — download BFCL and MTEB STS-B corpora for local evaluation.
#
# Usage:
#   scripts/fetch-corpora.sh [--bfcl-only] [--stsb-only]
#
# Files are cached and never re-downloaded on repeated runs (presence check).
# Default cache root: ~/.cache/manifold-eval  (override: MANIFOLD_EVAL_CACHE)
#
# After running, set these env vars to enable the data-gated tests:
#
#   BFCL_GORILLA_CACHE=$CACHE_ROOT/bfcl \
#   RUN_OLLAMA_EMBED=1 \
#   STSB_DATA=$CACHE_ROOT/stsb_test.json \
#   swift test --filter BFCLRealCorpusTests
#
#   RUN_OLLAMA_EMBED=1 \
#   STSB_DATA=$CACHE_ROOT/stsb_test.json \
#   swift test --filter MTEBRealCorpusTests
#
# Shell compatibility: bash 3.2+ (macOS default). No declare -A.
set -euo pipefail

CACHE_ROOT="${MANIFOLD_EVAL_CACHE:-$HOME/.cache/manifold-eval}"
BFCL_DIR="$CACHE_ROOT/bfcl"
STSB_FILE="$CACHE_ROOT/stsb_test.json"

DO_BFCL=1
DO_STSB=1

for arg in "$@"; do
    case "$arg" in
        --bfcl-only) DO_STSB=0 ;;
        --stsb-only) DO_BFCL=0 ;;
    esac
done

# ─── BFCL Gorilla v4 ────────────────────────────────────────────────────────

if [ "$DO_BFCL" -eq 1 ]; then
    echo "==> BFCL Gorilla v4"
    BFCL_DATA_DIR="$BFCL_DIR/data"
    BFCL_ANSWERS_DIR="$BFCL_DATA_DIR/possible_answer"
    GORILLA_BASE="https://raw.githubusercontent.com/ShishirPatil/gorilla/main/berkeley-function-call-leaderboard/bfcl_eval/data"

    mkdir -p "$BFCL_DATA_DIR" "$BFCL_ANSWERS_DIR"

    download_if_absent() {
        local url="$1"
        local dest="$2"
        if [ -f "$dest" ]; then
            echo "    cached: $(basename "$dest")"
        else
            echo "    downloading: $(basename "$dest") ..."
            curl -fsSL --retry 3 --retry-delay 2 "$url" -o "$dest"
            echo "    done: $(wc -l < "$dest") lines"
        fi
    }

    # Question files
    download_if_absent "$GORILLA_BASE/BFCL_v4_simple_python.json"   "$BFCL_DATA_DIR/BFCL_v4_simple_python.json"
    download_if_absent "$GORILLA_BASE/BFCL_v4_multiple.json"        "$BFCL_DATA_DIR/BFCL_v4_multiple.json"
    download_if_absent "$GORILLA_BASE/BFCL_v4_parallel.json"        "$BFCL_DATA_DIR/BFCL_v4_parallel.json"
    download_if_absent "$GORILLA_BASE/BFCL_v4_parallel_multiple.json" "$BFCL_DATA_DIR/BFCL_v4_parallel_multiple.json"
    download_if_absent "$GORILLA_BASE/BFCL_v4_irrelevance.json"     "$BFCL_DATA_DIR/BFCL_v4_irrelevance.json"

    # Answer files (all categories except irrelevance have ground-truth)
    download_if_absent "$GORILLA_BASE/possible_answer/BFCL_v4_simple_python.json"   "$BFCL_ANSWERS_DIR/BFCL_v4_simple_python.json"
    download_if_absent "$GORILLA_BASE/possible_answer/BFCL_v4_multiple.json"        "$BFCL_ANSWERS_DIR/BFCL_v4_multiple.json"
    download_if_absent "$GORILLA_BASE/possible_answer/BFCL_v4_parallel.json"        "$BFCL_ANSWERS_DIR/BFCL_v4_parallel.json"
    download_if_absent "$GORILLA_BASE/possible_answer/BFCL_v4_parallel_multiple.json" "$BFCL_ANSWERS_DIR/BFCL_v4_parallel_multiple.json"

    echo "    BFCL corpus ready at: $BFCL_DIR"
fi

# ─── MTEB STS-Benchmark test split ──────────────────────────────────────────

if [ "$DO_STSB" -eq 1 ]; then
    echo "==> MTEB STS-B"
    if [ -f "$STSB_FILE" ]; then
        echo "    cached: $STSB_FILE"
    else
        echo "    downloading 1,379 pairs from HuggingFace Datasets API ..."
        mkdir -p "$(dirname "$STSB_FILE")"

        # Python3 ships with macOS 12+; used for paginated JSON assembly only.
        python3 - "$STSB_FILE" <<'PYEOF'
import json, sys, urllib.request

dest = sys.argv[1]
base = "https://datasets-server.huggingface.co/rows"
params = "dataset=mteb%2Fstsbenchmark-sts&config=default&split=test"
page_size = 100
pairs = []
offset = 0
total = None

while True:
    url = f"{base}?{params}&offset={offset}&length={page_size}"
    req = urllib.request.Request(url, headers={"Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        page = json.loads(resp.read())

    rows = page.get("rows", [])
    if not rows:
        break

    if total is None:
        total = page.get("num_rows_total", 1379)
        sys.stderr.write(f"    total: {total} pairs\n")

    for r in rows:
        row = r["row"]
        pairs.append({
            "sentence1": row["sentence1"],
            "sentence2": row["sentence2"],
            "goldScore": row["score"],
        })

    offset += page_size
    sys.stderr.write(f"    fetched {len(pairs)}/{total}...\r")
    if len(pairs) >= total:
        break

sys.stderr.write("\n")
with open(dest, "w") as f:
    json.dump(pairs, f)
sys.stdout.write(f"    wrote {len(pairs)} pairs to {dest}\n")
PYEOF

        echo "    STS-B ready at: $STSB_FILE"
    fi
fi

# ─── Summary ────────────────────────────────────────────────────────────────

echo ""
echo "Cache root: $CACHE_ROOT"
echo ""
echo "Run corpus-gated tests:"
if [ "$DO_BFCL" -eq 1 ]; then
    echo "  BFCL_GORILLA_CACHE=$BFCL_DIR swift test --filter BFCLRealCorpusTests"
fi
if [ "$DO_STSB" -eq 1 ]; then
    echo "  RUN_OLLAMA_EMBED=1 STSB_DATA=$STSB_FILE swift test --filter MTEBRealCorpusTests"
fi
