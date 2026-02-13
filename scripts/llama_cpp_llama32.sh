#!/usr/bin/env bash
set -euo pipefail

# Example llama.cpp profiles for Llama 3.2 GGUF.
# Usage:
#   MODEL_PATH=/path/to/Llama-3.2-1B-Instruct.Q4_K_M.gguf ./scripts/llama_cpp_llama32.sh

: "${MODEL_PATH:?Set MODEL_PATH to a GGUF file path}"

export OMP_NUM_THREADS="${OMP_NUM_THREADS:-8}"
export GGML_N_THREADS="${GGML_N_THREADS:-8}"

echo "Basic profile"
llama-cli -m "$MODEL_PATH" \
  --temp 0.5 \
  --top-p 0.9 \
  --repetition-penalty 1.1 \
  --n_ctx 4096

echo "GPU-offload profile (if supported)"
llama-cli -m "$MODEL_PATH" \
  --temp 0.5 \
  --top-p 0.9 \
  --repetition-penalty 1.1 \
  --n_ctx 4096 \
  --threads "${GGML_N_THREADS}" \
  --gpu-layers 16
