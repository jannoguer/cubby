#!/bin/sh
# Installs the newest Mutagen with its agents bundle into <dir>, checked against the release's SHA256SUMS.
# Needs write access to <dir>.
# Run: sh .github/install-mutagen.sh <dir>
set -eu
[ $# -eq 1 ] || { echo "usage: $0 <dir>" >&2; exit 2; }
dir=$1

# The redirect names the release without an API call, so there is no rate limit to hit.
v=$(curl -fsSLo /dev/null -w '%{url_effective}' https://github.com/mutagen-io/mutagen/releases/latest)
v=${v##*/}
[ -n "$v" ] || { echo "no Mutagen version found" >&2; exit 1; }

case $(uname -s) in
    Linux) os=linux ;;
    Darwin) os=darwin ;;
    *) echo "unsupported OS: $(uname -s)" >&2; exit 1 ;;
esac
case $(uname -m) in
    x86_64) arch=amd64 ;;
    aarch64 | arm64) arch=arm64 ;;
    *) echo "unsupported CPU: $(uname -m)" >&2; exit 1 ;;
esac

f=mutagen_${os}_${arch}_$v.tar.gz
base=https://github.com/mutagen-io/mutagen/releases/download/$v
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
curl -fsSL "$base/$f" -o "$t/$f"
curl -fsSL "$base/SHA256SUMS" -o "$t/SHA256SUMS"
if command -v sha256sum > /dev/null; then sum="sha256sum -c -"; else sum="shasum -a 256 -c -"; fi
(cd "$t" && grep "  $f\$" SHA256SUMS | $sum)
tar -xzf "$t/$f" -C "$dir"
echo "Installed Mutagen $v ($os/$arch) in $dir"
