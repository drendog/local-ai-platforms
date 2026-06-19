#!/usr/bin/env bash

set -u

usage() {
  printf 'Usage: %s MACHINE_DIR\n' "${0##*/}" >&2
}

if [ "$#" -ne 1 ] || [ -z "$1" ]; then
  usage
  exit 2
fi

machine_dir=${1%/}
if [ ! -d "$machine_dir" ]; then
  printf 'Machine directory not found: %s\n' "$machine_dir" >&2
  exit 1
fi

system_file="$machine_dir/system.txt"
processor_file="$machine_dir/processor.txt"
memory_file="$machine_dir/memory.txt"
lspci_file="$machine_dir/lspci.txt"
lshw_file="$machine_dir/lshw.json"
readme_file="$machine_dir/README.md"

field_from() {
  local file=$1
  local key=$2

  [ -f "$file" ] || return 0

  awk -v key="$key" '
    function trim(value) {
      gsub(/^[ \t]+|[ \t]+$/, "", value)
      return value
    }
    $0 ~ "^[ \t]*" key ":[ \t]*" {
      sub("^[ \t]*" key ":[ \t]*", "", $0)
      print trim($0)
      exit
    }
  ' "$file"
}

escape_markdown_cell() {
  local value=$1
  value=${value//|/\\|}
  printf '%s' "$value"
}

write_row() {
  local label=$1
  local value=${2:-}

  case "$value" in
    ''|'Default string'|'Unknown'|'Not Specified') return 0 ;;
  esac

  printf '| %s | %s |\n' "$label" "$(escape_markdown_cell "$value")"
}

memory_summary() {
  [ -f "$memory_file" ] || return 0

  awk '
    function trim(value) {
      gsub(/^[ \t]+|[ \t]+$/, "", value)
      return value
    }
    /^[ \t]*Size:[ \t]*/ {
      size = $0
      sub(/^[ \t]*Size:[ \t]*/, "", size)
      size = trim(size)

      if (size == "" || size ~ /No Module Installed|None|Unknown/) {
        next
      }

      split(size, parts, /[ \t]+/)
      value = parts[1] + 0
      unit = parts[2]

      if (value <= 0 || unit == "") {
        next
      }

      if (unit == "GB" || unit == "GiB") {
        value_gib = value
      } else if (unit == "MB" || unit == "MiB") {
        value_gib = value / 1024
      } else {
        next
      }

      count++
      total_gib += value_gib
      total_source += value

      if (first_size == "") {
        first_size = size
        first_unit = unit
      } else if (unit != first_unit) {
        mixed_units = 1
      }

      if (!(size in seen_sizes)) {
        seen_sizes[size] = 1
        unique_sizes++
      }
    }
    END {
      if (count == 0) {
        exit
      }

      if (mixed_units) {
        total = total_gib
        unit = "GiB"
      } else {
        total = total_source
        unit = first_unit
      }

      if (total == int(total)) {
        total_text = sprintf("%d", total)
      } else {
        total_text = sprintf("%.1f", total)
      }

      if (unique_sizes == 1) {
        printf "%s %s (%d x %s)\n", total_text, unit, count, first_size
      } else {
        printf "%s %s (%d populated devices)\n", total_text, unit, count
      }
    }
  ' "$memory_file"
}

lshw_value() {
  local key=$1

  [ -f "$lshw_file" ] || return 0
  command -v python3 >/dev/null 2>&1 || return 0

  python3 - "$lshw_file" "$key" <<'PY'
import json
import sys

path, key = sys.argv[1:3]

try:
    with open(path, encoding="utf-8") as handle:
        data = json.load(handle)
except Exception:
    sys.exit(0)


def walk(node):
    if isinstance(node, dict):
        yield node
        for child in node.get("children", []):
            yield from walk(child)
    elif isinstance(node, list):
        for item in node:
            yield from walk(item)


if key == "chassis":
    value = data.get("configuration", {}).get("chassis") or data.get("description")
    if value:
        print(value)
    sys.exit(0)

for node in walk(data):
    if node.get("id") == "firmware" or node.get("description") == "BIOS":
        value = node.get("version" if key == "bios_version" else "date")
        if value:
            print(value)
        break
PY
}

write_pci_section() {
  [ -f "$lspci_file" ] || return 0

  awk '
    /Display controller|VGA compatible controller|3D controller|Network controller|Ethernet controller|Non-Volatile memory controller|Neural Processing Unit|USB4/ {
      print "- `" $0 "`"
    }
  ' "$lspci_file"
}

write_source_files_section() {
  local file
  local path

  for file in system.txt processor.txt memory.txt lspci.txt lshw.json; do
    path="$machine_dir/$file"
    if [ -f "$path" ]; then
      printf -- '- `%s`\n' "$file"
    fi
  done
}

manufacturer=$(field_from "$system_file" 'Manufacturer')
product=$(field_from "$system_file" 'Product Name')
family=$(field_from "$system_file" 'Family')
sku=$(field_from "$system_file" 'SKU Number')
system_version=$(field_from "$system_file" 'Version')
chassis=$(lshw_value chassis)

cpu=$(field_from "$processor_file" 'Version')
cpu_manufacturer=$(field_from "$processor_file" 'Manufacturer')
cores=$(field_from "$processor_file" 'Core Count')
threads=$(field_from "$processor_file" 'Thread Count')
max_speed=$(field_from "$processor_file" 'Max Speed')

memory=$(memory_summary)
memory_type=$(field_from "$memory_file" 'Type')
memory_speed=$(field_from "$memory_file" 'Speed')
configured_memory_speed=$(field_from "$memory_file" 'Configured Memory Speed')
memory_manufacturer=$(field_from "$memory_file" 'Manufacturer')
memory_part=$(field_from "$memory_file" 'Part Number')

bios_version=$(lshw_value bios_version)
bios_date=$(lshw_value bios_date)

title=$(printf '%s %s' "$manufacturer" "$product" | awk '{$1=$1; print}')
if [ -z "$title" ]; then
  title=${machine_dir##*/}
  title=${title//_/ }
fi

if ! tmp_file=$(mktemp "$machine_dir/.README.md.tmp.XXXXXX"); then
  printf 'Failed to create temporary README in: %s\n' "$machine_dir" >&2
  exit 1
fi

if ! {
  printf '# %s\n\n' "$title"
  printf 'Hardware summary generated from collected system outputs in this directory.\n\n'

  printf '## System\n\n'
  printf '| Field | Value |\n'
  printf '| --- | --- |\n'
  write_row 'Manufacturer' "$manufacturer"
  write_row 'Product' "$product"
  write_row 'Family' "$family"
  write_row 'SKU' "$sku"
  write_row 'Version' "$system_version"
  write_row 'Chassis' "$chassis"
  write_row 'BIOS' "$bios_version"
  write_row 'BIOS date' "$bios_date"

  printf '\n## Processor\n\n'
  printf '| Field | Value |\n'
  printf '| --- | --- |\n'
  write_row 'CPU' "$cpu"
  write_row 'Manufacturer' "$cpu_manufacturer"
  write_row 'Cores' "$cores"
  write_row 'Threads' "$threads"
  write_row 'Max speed' "$max_speed"

  printf '\n## Memory\n\n'
  printf '| Field | Value |\n'
  printf '| --- | --- |\n'
  write_row 'Total' "$memory"
  write_row 'Type' "$memory_type"
  write_row 'Speed' "$memory_speed"
  write_row 'Configured speed' "$configured_memory_speed"
  write_row 'Manufacturer' "$memory_manufacturer"
  write_row 'Part number' "$memory_part"

  pci_section=$(write_pci_section)
  if [ -n "$pci_section" ]; then
    printf '\n## PCI Highlights\n\n'
    printf '%s\n' "$pci_section"
  fi

  source_files=$(write_source_files_section)
  if [ -n "$source_files" ]; then
    printf '\n## Source Files\n\n'
    printf '%s\n' "$source_files"
  fi
} >"$tmp_file"
then
  rm -f "$tmp_file"
  printf 'Failed to write temporary README: %s\n' "$tmp_file" >&2
  exit 1
fi

if ! mv "$tmp_file" "$readme_file"; then
  rm -f "$tmp_file"
  printf 'Failed to write README: %s\n' "$readme_file" >&2
  exit 1
fi

printf 'Wrote %s\n' "$readme_file" >&2
