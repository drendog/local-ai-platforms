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

  for directory in /usr/sbin /sbin /usr/bin /bin; do
    if [ -x "$directory/$binary" ]; then
      printf '%s/%s\n' "$directory" "$binary"
      return 0
    fi
  done

  if command -v "$binary" >/dev/null 2>&1; then
    command -v "$binary"
    return 0
  fi

  return 1
}

redact_dmidecode() {
  local path=$1
  local tmp

  if ! tmp=$(mktemp "${path}.redact.XXXXXX"); then
    return 1
  fi

  if sed -E '
        s/^([[:space:]]*Serial Number:[[:space:]]*).*/\1[REDACTED]/
        s/^([[:space:]]*UUID:[[:space:]]*).*/\1[REDACTED]/
        s/^([[:space:]]*Asset Tag:[[:space:]]*).*/\1[REDACTED]/
        s/^([[:space:]]*Option [0-9]+:[[:space:]]*).*/\1[REDACTED]/
      ' "$path" >"$tmp"; then
    mv "$tmp" "$path"
    printf 'Redacted serial/UUID/asset fields in %s\n' "${path##*/}" >&2
    return 0
  fi

  rm -f "$tmp"
  return 1
}

redact_lshw_json() {
  local path=$1
  local tmp

  if ! command -v awk >/dev/null 2>&1; then
    printf 'Cannot redact lshw JSON: awk not found\n' >&2
    return 1
  fi

  if ! tmp=$(mktemp "${path}.redact.XXXXXX"); then
    return 1
  fi

  if awk '
    function redact_value(line) {
      sub(/: *"[^"]*"/, ": \"[REDACTED]\"", line)
      return line
    }
    {
      line = $0
      if (line ~ /^ *"id" *:/) {
        match(line, /^ */)
        if (!root_set) { root_indent = RLENGTH; root_set = 1 }
        if (RLENGTH == root_indent) { print redact_value(line); next }
      }
      if (line ~ /^ *"(serial|uuid|ip|ip6|mac|nqn|wwid|guid)" *:/) {
        print redact_value(line); next
      }
      if (line ~ /^ *"handle" *: *"GUID:/) {
        print redact_value(line); next
      }
      print line
    }
  ' "$path" >"$tmp"; then
    mv "$tmp" "$path"
    printf 'Redacted serials/UUID/MAC/IP and disk identifiers in %s\n' "${path##*/}" >&2
    return 0
  fi

  rm -f "$tmp"
  printf 'Cannot redact lshw JSON: scrub failed\n' >&2
  return 1
}

scan_for_identifiers() {
  local path=$1
  local stripped
  local hits
  local pattern
  local -a patterns grep_args

  if ! command -v grep >/dev/null 2>&1; then
    printf 'Cannot verify redaction: grep not found\n' >&2
    return 1
  fi

  if ! stripped=$(mktemp "${path}.scan.XXXXXX"); then
    return 1
  fi

  sed 's/\[REDACTED\]//g' "$path" >"$stripped"

  patterns=(
    # MAC address: six colon-separated hex octets (e.g. ec:3a:56:52:0b:c8).
    '([0-9a-f]{2}:){5}[0-9a-f]{2}'
    # UUID/GUID in canonical 8-4-4-4-12 form: SMBIOS UUID, filesystem/partition GUIDs.
    '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
    # IPv4 address: four dotted octets each capped at 0-255, standing alone
    # (the boundaries reject version strings like 1.2.3.4.5 or ...EAC.307).
    '(^|[^0-9.])(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)(\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)){3}([^0-9.]|$)'
    # Full (uncompressed) IPv6 address: eight colon-separated hex groups
    # (strict 8 groups so it ignores shorter colon-hex like PCI handles 0000:c2:00.0).
    '([0-9a-f]{1,4}:){7}[0-9a-f]{1,4}'
    # NVMe WWID in EUI-64 form (e.g. eui.002538ca5150e244) -- a unique drive id.
    'eui\.[0-9a-f]{16,}'
    # NVMe Qualified Name prefix (e.g. nqn.1994-11.com.samsung:...) -- embeds the drive serial.
    'nqn\.[0-9]{4}-[0-9]{2}\.'
    # 32+ contiguous hex chars: a raw 128-bit identifier with its separators stripped.
    '[0-9a-f]{32,}'
  )

  for pattern in "${patterns[@]}"; do
    grep_args+=(-e "$pattern")
  done

  hits=$(grep -niE "${grep_args[@]}" "$stripped")

  rm -f "$stripped"

  if [ -n "$hits" ]; then
    printf 'Identifier-shaped data survived redaction in %s:\n%s\n' \
      "${path##*/}" "$hits" >&2
    return 1
  fi

  return 0
}

redact() {
  local file_name=$1
  local path=$2

  case "$file_name" in
    system.txt | processor.txt | memory.txt)
      redact_dmidecode "$path" || return 1
      ;;
    lshw.json)
      redact_lshw_json "$path" || return 1
      ;;
  esac

  scan_for_identifiers "$path"
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
    if ! redact "$file_name" "$tmp_file"; then
      rm -f "$tmp_file"
      printf 'Skipping %s: redaction failed; refusing to write unredacted data\n' "$file_name" >&2
      return 0
    fi
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
