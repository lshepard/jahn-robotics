#!/bin/bash
#
# convert-media.sh — Convert raw photos/videos to web-ready formats
#
# Usage: npm run convert-media
#
# Drop raw files into public/images/teams/{team-slug}/raw/
# This script converts them to optimized formats in the parent folder.
#
# Videos → v-{shortname}.mp4  (720p, 10s max, no audio, H.264)
# Photos → p-{shortname}.jpg  (max 1920px wide, JPEG)
#
# Already-converted files are skipped. Safe to run repeatedly.
#

set -euo pipefail

TEAMS_DIR="public/images/teams"
VIDEO_EXTS_RE="^(MOV|MP4|mp4|mov|avi|m4v|MTS|mts)$"
PHOTO_EXTS_RE="^(jpeg|jpg|png|JPEG|JPG|PNG|HEIC|heic)$"

converted=0
skipped=0
errors=0

# Derive a short, filesystem-safe name from a filename
shortname() {
  local base
  base="$(basename "$1")"
  # Remove extension
  base="${base%.*}"
  # Lowercase, replace spaces/special chars with hyphens, collapse multiple hyphens, trim
  echo "$base" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g; s/-\{2,\}/-/g; s/^-//; s/-$//'
}

echo "=== Media Conversion ==="
echo ""

# Find all raw/ directories under teams
found_raw=false
for raw_dir in "$TEAMS_DIR"/*/raw; do
  [ -d "$raw_dir" ] || continue
  found_raw=true

  team_dir="$(dirname "$raw_dir")"
  team_slug="$(basename "$team_dir")"
  echo "--- $team_slug ---"

  # Use glob instead of find|pipe to avoid stdin conflicts with ffmpeg
  for file in "$raw_dir"/*; do
    [ -f "$file" ] || continue

    ext="${file##*.}"
    base_name="$(shortname "$file")"

    # Check if it's a video
    if echo "$ext" | grep -qE "$VIDEO_EXTS_RE"; then
      output="$team_dir/v-${base_name}.mp4"
      if [ -f "$output" ]; then
        echo "  skip  v-${base_name}.mp4 (exists)"
        skipped=$((skipped + 1))
      else
        echo "  video $(basename "$file") -> v-${base_name}.mp4"
        if ffmpeg -nostdin -y -i "$file" \
          -vf "scale=-2:720" \
          -c:v libx264 -preset slow -crf 28 \
          -an -movflags +faststart \
          -t 10 \
          "$output" \
          -loglevel warning 2>&1; then
          size=$(du -h "$output" 2>/dev/null | cut -f1 | xargs)
          echo "        done ($size)"
          converted=$((converted + 1))
        else
          echo "        FAILED"
          rm -f "$output"
          errors=$((errors + 1))
        fi
      fi

    # Check if it's a photo
    elif echo "$ext" | grep -qE "$PHOTO_EXTS_RE"; then
      output="$team_dir/p-${base_name}.jpg"
      if [ -f "$output" ]; then
        echo "  skip  p-${base_name}.jpg (exists)"
        skipped=$((skipped + 1))
      else
        echo "  photo $(basename "$file") -> p-${base_name}.jpg"
        if sips -s format jpeg -Z 1920 "$file" --out "$output" > /dev/null 2>&1; then
          size=$(du -h "$output" 2>/dev/null | cut -f1 | xargs)
          echo "        done ($size)"
          converted=$((converted + 1))
        else
          echo "        FAILED"
          rm -f "$output"
          errors=$((errors + 1))
        fi
      fi
    else
      echo "  ???   Skipping unknown format: $(basename "$file")"
    fi
  done

  echo ""
done

if [ "$found_raw" = false ]; then
  echo "No raw/ folders found under $TEAMS_DIR/."
  echo "Create a folder like $TEAMS_DIR/team-slug/raw/ and drop files there."
  exit 0
fi

echo "=== Summary ==="
echo "  Converted: $converted"
echo "  Skipped:   $skipped"
echo "  Errors:    $errors"
