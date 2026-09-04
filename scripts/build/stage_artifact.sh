#!/usr/bin/env bash
set -euo pipefail

# Stage build artifacts under names accepted by GitHub Actions artifacts
# (Windows — where a downloading runner might later run — forbids
# " % < > : | ? * and ASCII control characters in filenames). Was
# scripts/build/stage_artifact.py; zero Arch-specific content, ported
# straight across.
#
# Usage:
#   stage_artifact.sh stage <source-dir> <artifact-dir>
#   stage_artifact.sh restore <artifact-dir>

MAP_FILENAME="artifact-name-map.json"
UNSAFE_CHARACTERS='"%<>:|?*'

# Percent-encodes (as %XX, uppercase hex) any character in
# UNSAFE_CHARACTERS or any ASCII control character (ordinal < 32);
# everything else passes through unchanged.
artifact_safe_name() {
  local name="$1" out="" i char ord hex
  for (( i = 0; i < ${#name}; i++ )); do
    char="${name:$i:1}"
    ord=$(printf '%d' "'$char")
    if [[ "$UNSAFE_CHARACTERS" == *"$char"* ]] || (( ord < 32 )); then
      printf -v hex '%02X' "$ord"
      out+="%$hex"
    else
      out+="$char"
    fi
  done
  printf '%s' "$out"
}

# Rejects anything that isn't a single plain path component.
validate_filename() {
  local name="$1"
  if [[ -z "$name" || "$name" == "." || "$name" == ".." || "$name" == */* ]]; then
    echo "error: invalid artifact filename: $name" >&2
    return 1
  fi
}

stage() {
  local source_dir="$1" artifact_dir="$2"
  [[ -d "$source_dir" ]] || { echo "error: source directory does not exist: $source_dir" >&2; return 1; }
  if [[ -d "$artifact_dir" ]] && [[ -n "$(ls -A "$artifact_dir" 2>/dev/null)" ]]; then
    echo "error: artifact directory must be empty: $artifact_dir" >&2
    return 1
  fi

  mkdir -p "$artifact_dir"

  local name_map="{}"
  local entry_file source_name staged_name
  while IFS= read -r -d '' entry_file; do
    source_name="$(basename "$entry_file")"
    if [[ ! -f "$entry_file" ]]; then
      echo "error: artifact source must be a file: $entry_file" >&2
      return 1
    fi
    if [[ "$source_name" == "$MAP_FILENAME" ]]; then
      echo "error: reserved artifact filename: $source_name" >&2
      return 1
    fi
    staged_name="$(artifact_safe_name "$source_name")"
    if [[ "$staged_name" != "$source_name" ]]; then
      name_map="$(jq --arg k "$staged_name" --arg v "$source_name" '. + {($k): $v}' <<<"$name_map")"
    fi
    cp -p "$entry_file" "$artifact_dir/$staged_name"
  done < <(find "$source_dir" -mindepth 1 -maxdepth 1 -print0 | sort -z)

  jq -n --argjson files "$name_map" '{files: $files}' > "$artifact_dir/$MAP_FILENAME"
}

restore() {
  local artifact_dir="$1"
  local map_path="$artifact_dir/$MAP_FILENAME"
  [[ -f "$map_path" ]] || return 0

  if ! jq -e '.files? and (.files | type == "object")' "$map_path" >/dev/null 2>&1; then
    echo "error: invalid artifact name map: $map_path" >&2
    return 1
  fi

  local staged_name original_name staged_path original_path
  while IFS=$'\t' read -r staged_name original_name; do
    [[ -z "$staged_name" && -z "$original_name" ]] && continue
    validate_filename "$staged_name"
    validate_filename "$original_name"
    staged_path="$artifact_dir/$staged_name"
    original_path="$artifact_dir/$original_name"
    if [[ ! -f "$staged_path" ]]; then
      echo "error: staged artifact file does not exist: $staged_path" >&2
      return 1
    fi
    if [[ -e "$original_path" ]]; then
      echo "error: original artifact path already exists: $original_path" >&2
      return 1
    fi
    mv "$staged_path" "$original_path"
  done < <(jq -r '.files | to_entries[] | "\(.key)\t\(.value)"' "$map_path")
}

operation="${1:?usage: stage_artifact.sh <stage|restore> ...}"
case "$operation" in
  stage)
    source_dir="${2:?stage requires SOURCE_DIR and ARTIFACT_DIR}"
    artifact_dir="${3:?stage requires SOURCE_DIR and ARTIFACT_DIR}"
    stage "$source_dir" "$artifact_dir"
    ;;
  restore)
    artifact_dir="${2:?restore requires ARTIFACT_DIR}"
    restore "$artifact_dir"
    ;;
  *)
    echo "error: unknown operation: $operation (expected stage or restore)" >&2
    exit 1
    ;;
esac
