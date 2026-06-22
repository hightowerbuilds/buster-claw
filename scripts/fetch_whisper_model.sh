#!/usr/bin/env bash
#
# Fetch the whisper.cpp STT model bundled into the desktop app (voice roadmap
# Phase 0/2). The model is ~142MB, so it is fetched here rather than committed.
# It lands in resources/models/ (a stable bundle mapping — NOT resources/release/,
# which the build and dev launcher wipe and re-stage).
#
# Run once from the repo root before building the desktop app with voice input:
#   ./scripts/fetch_whisper_model.sh
#
set -euo pipefail

MODEL="ggml-base.en.bin"
# Pinned good speed/accuracy tradeoff for v1 (English-only). To change the model,
# update MODEL here and the path in desktop/tauri/src/main.rs (resolve_voice_model).
URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/${MODEL}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST_DIR="${REPO_ROOT}/desktop/tauri/resources/models"
DEST="${DEST_DIR}/${MODEL}"

mkdir -p "${DEST_DIR}"

if [ -f "${DEST}" ]; then
  echo "==> ${MODEL} already present at ${DEST} ($(du -h "${DEST}" | cut -f1)); skipping."
  exit 0
fi

echo "==> Downloading ${MODEL} (~142MB) from Hugging Face"
echo "    ${URL}"
curl -fL --progress-bar -o "${DEST}.partial" "${URL}"
mv "${DEST}.partial" "${DEST}"

echo "==> Done: ${DEST} ($(du -h "${DEST}" | cut -f1))"
