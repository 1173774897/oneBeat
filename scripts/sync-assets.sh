#!/usr/bin/env bash
set -euo pipefail

SRC_ROOT="${ONE_BEAT_ASSET_SRC:-/Users/lizhe/Downloads/onebeatprocessing}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST_ROOT="$REPO_ROOT/entry/src/main/resources/rawfile"
LAMP_FRAME_SRC="$REPO_ROOT/designs/lamp-linework/2026-10-02/lamp-retouched-frames"

mkdir -p "$DEST_ROOT/walk/cloud" "$DEST_ROOT/walk/lamp" "$DEST_ROOT/walk/mismatch" "$DEST_ROOT/walk/lilroll" "$DEST_ROOT/walk/teapot" "$DEST_ROOT/walk/wave" "$DEST_ROOT/walk/scooter" "$DEST_ROOT/road" "$DEST_ROOT/entities"

copy_frames() {
  local name="$1"
  local src_dir="$SRC_ROOT/cycling/${name}_frames/cutout"
  local dest_dir="$DEST_ROOT/walk/${name}"
  if [[ ! -d "$src_dir" ]]; then
    echo "Missing cutout frames: $src_dir" >&2
    exit 1
  fi
  rm -f "$dest_dir"/*.png
  cp "$src_dir"/frame_*.png "$dest_dir/"
  echo "Copied $(ls "$dest_dir" | wc -l | tr -d ' ') frames -> walk/${name}"
}

copy_frames cloud
copy_frames mismatch
copy_frames lilroll
copy_frames teapot
copy_frames wave
copy_frames scooter

if [[ -d "$LAMP_FRAME_SRC" ]]; then
  rm -f "$DEST_ROOT/walk/lamp"/*.png
  cp "$LAMP_FRAME_SRC"/frame_*.png "$DEST_ROOT/walk/lamp/"
  echo "Copied $(ls "$DEST_ROOT/walk/lamp" | wc -l | tr -d ' ') frames -> walk/lamp (designs)"
fi

if [[ -f "$DEST_ROOT/walk/lamp/frame_01.png" ]]; then
  mkdir -p "$DEST_ROOT/comic/characters" "$DEST_ROOT/comic/avatars" "$DEST_ROOT/comic/poses"
  cp "$DEST_ROOT/walk/lamp/frame_01.png" "$DEST_ROOT/comic/characters/lamp.png"
  cp "$DEST_ROOT/walk/lamp/frame_01.png" "$DEST_ROOT/comic/avatars/lamp.png"
  cp "$DEST_ROOT/walk/lamp/frame_01.png" "$DEST_ROOT/comic/poses/lamp.png"
  echo "Comic placeholder -> comic/*/lamp.png"
fi

if [[ -f "$DEST_ROOT/walk/lilroll/frame_01.png" ]]; then
  cp "$DEST_ROOT/walk/lilroll/frame_01.png" "$DEST_ROOT/comic/characters/lilroll.png"
  cp "$DEST_ROOT/walk/lilroll/frame_01.png" "$DEST_ROOT/comic/avatars/lilroll.png"
  echo "Comic placeholder -> comic/*/lilroll.png"
fi

if [[ -f "$DEST_ROOT/walk/teapot/frame_01.png" ]]; then
  cp "$DEST_ROOT/walk/teapot/frame_01.png" "$DEST_ROOT/comic/characters/teapot.png"
  cp "$DEST_ROOT/walk/teapot/frame_01.png" "$DEST_ROOT/comic/avatars/teapot.png"
  echo "Comic placeholder -> comic/*/teapot.png"
fi

if [[ -f "$DEST_ROOT/walk/wave/frame_01.png" ]]; then
  cp "$DEST_ROOT/walk/wave/frame_01.png" "$DEST_ROOT/comic/characters/wave.png"
  cp "$DEST_ROOT/walk/wave/frame_01.png" "$DEST_ROOT/comic/avatars/wave.png"
  echo "Comic placeholder -> comic/*/wave.png"
fi

if [[ -f "$DEST_ROOT/walk/scooter/frame_01.png" ]]; then
  cp "$DEST_ROOT/walk/scooter/frame_01.png" "$DEST_ROOT/comic/characters/scooter.png"
  cp "$DEST_ROOT/walk/scooter/frame_01.png" "$DEST_ROOT/comic/avatars/scooter.png"
  echo "Comic placeholder -> comic/*/scooter.png"
fi

cp "$SRC_ROOT/background/road/"*.png "$DEST_ROOT/road/"
echo "Copied road tiles -> road/"

rm -f "$DEST_ROOT/entities"/*.png
cp "$SRC_ROOT/background/entities/cutout/"*.png "$DEST_ROOT/entities/"
echo "Copied $(ls "$DEST_ROOT/entities" | wc -l | tr -d ' ') entities -> entities/"

NEON_ENTITY_SRC="$SRC_ROOT/background/neon/entities/cutout"
if [[ -d "$NEON_ENTITY_SRC" ]]; then
  mkdir -p "$DEST_ROOT/scenes/neon/entities"
  rm -f "$DEST_ROOT/scenes/neon/entities"/*.png
  cp "$NEON_ENTITY_SRC"/*.png "$DEST_ROOT/scenes/neon/entities/"
  echo "Copied $(ls "$DEST_ROOT/scenes/neon/entities" | wc -l | tr -d ' ') entities -> scenes/neon/entities/"
fi

echo "Asset sync complete: $DEST_ROOT"
