#!/bin/bash
ISO=/mnt/d/ai/prj/trae/HuaWei/RetroEmuPouch/build/mame-ohos-src
UP=/mnt/d/ai/prj/trae/HuaWei/RetroEmuPouch/build/mame-src
OUT=/tmp/tree.txt
{
  echo "=== isolated tree: top level (non-src) ==="
  ls -1 "$ISO" 2>&1 | grep -vE '^(src|3rdparty)$'
  echo
  echo "=== ohos-tc wrappers still present? ==="
  ls -la "$ISO/ohos-tc/" 2>&1 | head -12
  echo
  echo "=== strformat.h patch marker (safe_make_signed) ==="
  grep -c 'safe_make_signed' "$ISO/src/lib/util/strformat.h" 2>&1
  echo "=== strformat.h bool exclusion present? ==="
  grep -c 'is_same_v<U, bool>' "$ISO/src/lib/util/strformat.h" 2>&1
  echo
  echo "=== uicmd14.png present? ==="
  ls -la "$ISO/src/frontend/mame/ui/uicmd14.png" 2>&1
  ls -la "$UP/src/frontend/mame/ui/uicmd14.png" 2>&1
  echo
  echo "=== build dir: objects / generated .fh ==="
  echo "objects: $(find "$ISO/build" -name '*.o' 2>/dev/null | wc -l)"
  ls -la "$ISO/build/generated/emu/ui/uicmd14.fh" 2>&1
  find "$ISO" -maxdepth 2 -name 'mamearcade_libretro.so' 2>/dev/null
  echo
  echo "=== native SDK still there? ==="
  ls -d "$HOME/ohos-sdk/ohos-tc-linux" 2>&1
  ls -1 "$HOME/ohos-sdk/ohos-tc-linux" 2>&1 | head -8
} > "$OUT" 2>&1
cat "$OUT"
