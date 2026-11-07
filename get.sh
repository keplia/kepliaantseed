# Satu perintah: unduh script, lalu jalankan.
#   curl -fsSL https://raw.githubusercontent.com/<user>/<repo>/main/get.sh | sudo bash
#
# Opsi:
#   curl -fsSL .../get.sh | sudo bash -s -- --token 'cf_...' --domain example.com --count 2
#
set -Eeuo pipefail

REPO="${ANTSEED_FLEET_REPO:-keplia/kepliaantseed}"
REF="${ANTSEED_FLEET_REF:-main}"
BASE="https://raw.githubusercontent.com/$REPO/$REF"

[[ $EUID -eq 0 ]] || { echo "run as root (sudo bash)" >&2; exit 1; }
command -v curl >/dev/null || { echo "curl is required" >&2; exit 1; }

dir=/opt/antseed-fleet
mkdir -p "$dir"
for f in install.sh antseed-fleet; do
  curl -fsSL "$BASE/$f" -o "$dir/$f"
done
curl -fsSL "$BASE/README.md" -o "$dir/README.md" || true
chmod +x "$dir/install.sh" "$dir/antseed-fleet"
ln -sf "$dir/antseed-fleet" /usr/local/bin/antseed-fleet

if [[ "$REPO" == "keplia/kepliaantseed" ]]; then
  echo "note: get.sh is still using the placeholder repository (keplia/kepliaantseed)." >&2
  echo "      set ANTSEED_FLEET_REPO=owner/repo or host the files yourself." >&2
fi

# The manager CLI is available now; the installer reads the rest from the terminal.
exec bash "$dir/install.sh" "$@"
