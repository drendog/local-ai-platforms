#!/usr/bin/env bash

set -u

usage() {
  printf 'Usage: %s OUTPUT_DIR\n' "${0##*/}" >&2
}

if [ "$#" -ne 1 ] || [ -z "$1" ]; then
  usage
  exit 2
fi

if [ "$EUID" -eq 0 ] && [ -n "${SUDO_UID:-}" ]; then
  printf 'Do not run this script with sudo; run it as your user. It will use sudo internally.\n' >&2
  exit 2
fi

output_dir=$1
if ! mkdir -p "$output_dir"; then
  printf 'Failed to create output directory: %s\n' "$output_dir" >&2
  exit 1
fi

resolve_binary() {
  local binary=$1
  local directory

  if command -v "$binary" >/dev/null 2>&1; then
    command -v "$binary"
    return 0
  fi

  for directory in /usr/sbin /sbin /usr/bin /bin; do
    if [ -x "$directory/$binary" ]; then
      printf '%s/%s\n' "$directory" "$binary"
      return 0
    fi
  done

  return 1
}

collect() {
  local file_name=$1
  local requires_root=$2
  shift 2

  local binary=$1
  local output_file="$output_dir/$file_name"
  local binary_path
  local tmp_file

  if ! binary_path=$(resolve_binary "$binary"); then
    printf 'Skipping %s: %s not found\n' "$file_name" "$binary" >&2
    return 0
  fi

  if [ -e "$output_file" ] && [ ! -w "$output_file" ]; then
    printf 'Skipping %s: %s is not writable\n' "$file_name" "$output_file" >&2
    return 0
  fi

  set -- "$binary_path" "${@:2}"

  if [ "$requires_root" = "yes" ] && [ "$EUID" -ne 0 ]; then
    if ! command -v sudo >/dev/null 2>&1; then
      printf 'Skipping %s: sudo not found\n' "$file_name" >&2
      return 0
    fi

    set -- sudo "$@"
  fi

  if ! tmp_file=$(mktemp "$output_dir/.${file_name}.tmp.XXXXXX"); then
    printf 'Skipping %s: failed to create temporary file\n' "$file_name" >&2
    return 0
  fi

  if "$@" >"$tmp_file"; then
    mv "$tmp_file" "$output_file"
    printf 'Wrote %s\n' "$output_file" >&2
    return 0
  else
    local status=$?
    rm -f "$tmp_file"
    if [ -e "$output_file" ]; then
      printf 'Warning: %s failed with exit status %s; left %s unchanged\n' "$*" "$status" "$output_file" >&2
    else
      printf 'Warning: %s failed with exit status %s; did not write %s\n' "$*" "$status" "$output_file" >&2
    fi
  fi
}

collect system.txt yes dmidecode --type system
collect processor.txt yes dmidecode --type processor
collect memory.txt yes dmidecode --type memory
collect lspci.txt no lspci
collect lshw.json yes lshw -json
