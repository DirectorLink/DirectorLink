#!/usr/bin/env bash
# Installs Lua 5.1.5 as lua5.1 and luac5.1 (and lua, luac) for CI (.github/workflows/validate.yml),
# without Ubuntu's package mirror: once a mirror hung and a job waited 25 minutes for apt-get.
#
# The official tarball from lua.org (or Debian's copy of the very same file, if lua.org does not
# answer) is checked against its SHA-256, the one lua.org lists, and built as Debian builds its
# lua5.1 (POSIX and dlopen), without readline, which only the interactive prompt uses. The
# workflow caches PREFIX (actions/cache, keyed on this file), so a run usually only checks that the
# cached lua5.1 works; then nothing is downloaded or built.
#
#   bash scripts/install_lua.sh [PREFIX]      (default ~/.lua-5.1.5; adds PREFIX/bin to $GITHUB_PATH)

set -euo pipefail

VERSION="5.1.5"
SHA256="2640fc56a795f29d28ef15e13c34a47e223960b0240e8cb0a82d9b0738695333"
SOURCES=(
  "https://www.lua.org/ftp/lua-$VERSION.tar.gz"
  "https://deb.debian.org/debian/pool/main/l/lua5.1/lua5.1_$VERSION.orig.tar.gz"
)
PREFIX="${1:-$HOME/.lua-$VERSION}"
BIN="$PREFIX/bin"

works() {
  [ -x "$BIN/lua5.1" ] && [ -x "$BIN/luac5.1" ] &&
    [ "$("$BIN/lua5.1" -e 'io.write(_VERSION)' 2>/dev/null)" = "Lua 5.1" ] &&
    "$BIN/luac5.1" -v >/dev/null 2>&1
}

if works; then
  echo "Lua $VERSION is here already (cached): $BIN"
else
  rm -rf "$PREFIX"
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT
  tarball="$work/lua-$VERSION.tar.gz"
  for source in "${SOURCES[@]}"; do
    echo "Downloading $source"
    if curl --fail --silent --show-error --location --retry 2 --connect-timeout 10 --max-time 60 \
      --output "$tarball" "$source"; then
      break
    fi
    rm -f "$tarball"
  done
  if [ ! -f "$tarball" ]; then
    echo "::error::Could not download Lua $VERSION from lua.org or Debian."
    exit 1
  fi
  if ! echo "$SHA256  $tarball" | sha256sum --check --strict -; then
    echo "::error::lua-$VERSION.tar.gz does not have the SHA-256 lua.org lists ($SHA256): not built."
    exit 1
  fi
  tar -xzf "$tarball" -C "$work"
  make -C "$work/lua-$VERSION/src" -j "$(nproc)" all MYCFLAGS="-DLUA_USE_POSIX -DLUA_USE_DLOPEN" MYLIBS="-Wl,-E -ldl"
  mkdir -p "$BIN"
  install -m 755 "$work/lua-$VERSION/src/lua" "$BIN/lua5.1"
  install -m 755 "$work/lua-$VERSION/src/luac" "$BIN/luac5.1"
  ln -sf lua5.1 "$BIN/lua"
  ln -sf luac5.1 "$BIN/luac"
  if ! works; then
    echo "::error::The Lua $VERSION just built does not run."
    exit 1
  fi
fi

"$BIN/lua5.1" -v
if [ -n "${GITHUB_PATH:-}" ]; then
  echo "$BIN" >> "$GITHUB_PATH"
fi
