#!/bin/bash
# Called only when Start needs to build an installation.
set -euo pipefail
export PATH="${CARGO_HOME:-$HOME/.cargo}/bin:/opt/homebrew/opt/rustup/bin:/opt/homebrew/bin:/opt/homebrew/opt/llvm/bin:/opt/homebrew/opt/bison/bin:$PATH"
if ! /usr/bin/arch -x86_64 /usr/bin/true 2>/dev/null; then
  printf 'Installing Rosetta. Follow Apple’s license prompt below.\n'
  /usr/sbin/softwareupdate --install-rosetta
fi
if [ ! -x "/opt/homebrew/bin/brew" ]; then
  printf 'Installing Homebrew. It may ask for your Mac password.\n'
  installer=$(mktemp -t bedrock-homebrew)
  trap 'rm -f "$installer"' EXIT
  /usr/bin/curl --fail --location --proto '=https' --proto-redir '=https' \
    https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh -o "$installer"
  /bin/bash "$installer"
  rm -f "$installer"
  trap - EXIT
fi
missing=()
for formula in llvm bison gnutls freetype protobuf; do
  if ! "/opt/homebrew/bin/brew" list --versions "$formula" >/dev/null 2>&1; then
    missing+=("$formula")
  fi
done
if ! command -v rustup >/dev/null 2>&1; then
  missing+=(rustup)
fi
if [ "${#missing[@]}" -gt 0 ]; then
  HOMEBREW_NO_AUTO_UPDATE=1 "/opt/homebrew/bin/brew" install "${missing[@]}"
fi
if ! rustup run 1.98.0 rustc --version >/dev/null 2>&1; then
  rustup toolchain install 1.98.0 --profile minimal
fi
rustup run 1.98.0 rustc --version
