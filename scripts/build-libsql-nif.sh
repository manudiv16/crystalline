#!/usr/bin/env bash
# Build the libsql_gleam Rust NIF from source and install it where the
# bundled FFI loads it.
#
# Why this exists:
#   - The `libsql_gleam` hex package (0.1.0) ships no precompiled NIF and its
#     download URL points at a placeholder repository, so no release assets
#     exist anywhere.
#   - libsql itself provides Turso remote mode (`open_remote`), which the
#     Crystalline remote database mode depends on.
#
# The FFI (see README "Development") loads the NIF from the user cache
# directory:
#
#   <user_cache>/libsql/libsql_nif-0.1.0-<os>-<arch>
#
# This script builds that file from a pinned upstream commit and installs it.
# CI must run this before `gleam test`.
set -euo pipefail

UPSTREAM_REPO="https://github.com/felstormrage/libsql-gleam.git"
UPSTREAM_COMMIT="4f3d375d04aaf4696da1d3e1595a89e52aff29d8"
NIF_VERSION="0.1.0"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

echo "==> Cloning libsql-gleam at $UPSTREAM_COMMIT"
git clone --quiet --filter=blob:none "$UPSTREAM_REPO" "$WORKDIR/libsql-gleam"
git -C "$WORKDIR/libsql-gleam" checkout --quiet "$UPSTREAM_COMMIT"

echo "==> Building the NIF (cargo --release)"
cargo build --release \
	--manifest-path "$WORKDIR/libsql-gleam/native/libsql_nif/Cargo.toml"

# Resolve the cache directory exactly as Erlang's filename:basedir does.
CACHE_DIR="$(erl -noshell -eval \
	'io:format("~s", [filename:basedir(user_cache, "libsql")]), halt().')"
mkdir -p "$CACHE_DIR"

# Map uname output to the FFI's platform identifiers.
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)"
case "$OS" in
darwin) OS="macos" ;;
linux) OS="linux" ;;
*)
	echo "unsupported OS: $OS" >&2
	exit 1
	;;
esac
case "$ARCH" in
arm64 | aarch64) ARCH="aarch64" ;;
x86_64 | amd64) ARCH="x86_64" ;;
i386 | i686) ARCH="x86_64" ;;
*)
	echo "unsupported arch: $ARCH" >&2
	exit 1
	;;
esac

SRC=""
case "$OS" in
macos) SRC="liblibsql_nif.dylib" ;;
linux) SRC="liblibsql_nif.so" ;;
esac

DEST="$CACHE_DIR/libsql_nif-$NIF_VERSION-$OS-$ARCH"
echo "==> Installing NIF to $DEST"
cp "$WORKDIR/libsql-gleam/native/libsql_nif/target/release/$SRC" "$DEST"
chmod 755 "$DEST"
echo "==> Done. libsql NIF installed: $DEST"
