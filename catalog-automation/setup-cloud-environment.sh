#!/usr/bin/env bash
# Setup script for the Claude cloud environment of the weekly catalog review routine.
# Installs PowerShell 7 and Pester so the routine can run the scripts in catalog-automation/ and
# docs-site/scripts/ and the Pester tests. Paste this into the environment's setup script field.
#
# Route 1: pinned release from github.com, checksum verified (no api.github.com, it answers 403).
# Route 2: the Microsoft package feed through apt, on Debian and Ubuntu.
# When both fail it prints which hosts the environment can reach, so the network setting can be fixed.
# Safe to run again: it does nothing when pwsh and a recent Pester are already there.
set -uo pipefail

PWSH_VERSION="7.6.6"
PESTER_MIN="5.6.1"

say() { echo "[setup] $*"; }

probe() { # host-url -> prints the HTTP status or the curl error
  local code
  code="$(curl -sS -L -o /dev/null -w '%{http_code}' --max-time 20 "$1" 2>&1)" || code="curl failed: $code"
  say "  $1 -> $code"
}

diagnose() {
  say "Network check:"
  probe https://github.com/PowerShell/PowerShell/releases/download/v${PWSH_VERSION}/hashes.sha256
  probe https://release-assets.githubusercontent.com/
  probe https://objects.githubusercontent.com/
  probe https://packages.microsoft.com/
  probe https://www.powershellgallery.com/api/v2/
  say "Proxy variables: HTTPS_PROXY=${HTTPS_PROXY:-<unset>} https_proxy=${https_proxy:-<unset>}"
}

install_from_github() {
  local arch base file tmp expected actual
  case "$(uname -m)" in
    x86_64)  arch="x64" ;;
    aarch64) arch="arm64" ;;
    *) say "Unsupported architecture: $(uname -m)"; return 1 ;;
  esac
  base="https://github.com/PowerShell/PowerShell/releases/download/v${PWSH_VERSION}"
  file="powershell-${PWSH_VERSION}-linux-${arch}.tar.gz"
  tmp="$(mktemp -d)"
  say "Route 1: downloading $base/$file"

  curl -fL --show-error --silent --retry 2 --max-time 300 "$base/$file" -o "$tmp/$file" || { say "download failed (curl exit $?)"; return 1; }
  curl -fL --show-error --silent --retry 2 --max-time 60 "$base/hashes.sha256" -o "$tmp/hashes.sha256" || { say "checksum download failed (curl exit $?)"; return 1; }

  expected="$(grep -F "$file" "$tmp/hashes.sha256" | awk '{print $1}')"
  actual="$(sha256sum "$tmp/$file" | awk '{print $1}')"
  if [ -z "$expected" ] || [ "$expected" != "$actual" ]; then
    say "checksum mismatch for $file (expected '$expected', got '$actual')"
    return 1
  fi

  mkdir -p /opt/microsoft/powershell
  tar -xzf "$tmp/$file" -C /opt/microsoft/powershell || return 1
  chmod +x /opt/microsoft/powershell/pwsh
  ln -sf /opt/microsoft/powershell/pwsh /usr/local/bin/pwsh
  rm -rf "$tmp"
}

install_from_apt() {
  [ -r /etc/os-release ] || { say "no /etc/os-release"; return 1; }
  . /etc/os-release
  case "${ID:-}" in debian|ubuntu) ;; *) say "Route 2 needs Debian or Ubuntu, this is '${ID:-unknown}'"; return 1 ;; esac
  say "Route 2: Microsoft package feed for ${ID} ${VERSION_ID:-}"
  local tmp; tmp="$(mktemp -d)"
  curl -fL --show-error --silent --retry 2 --max-time 120 \
    "https://packages.microsoft.com/config/${ID}/${VERSION_ID}/packages-microsoft-prod.deb" -o "$tmp/ms.deb" || { say "feed package download failed (curl exit $?)"; return 1; }
  dpkg -i "$tmp/ms.deb" || return 1
  apt-get update -qq || return 1
  apt-get install -y -qq powershell || return 1
  rm -rf "$tmp"
}

if ! command -v pwsh >/dev/null 2>&1; then
  install_from_github || install_from_apt || {
    say "Could not install PowerShell."
    diagnose
    exit 1
  }
fi

say "PowerShell $(pwsh -NoProfile -Command '$PSVersionTable.PSVersion.ToString()')"

# Pester is best effort: the compare and build scripts run without it, only the tests need it.
if ! pwsh -NoProfile -Command "
  \$min = [version]'$PESTER_MIN'
  \$have = Get-Module -ListAvailable Pester | Where-Object { \$_.Version -ge \$min } | Select-Object -First 1
  if (-not \$have) {
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
    Install-Module -Name Pester -MinimumVersion \$min -Scope AllUsers -Force -SkipPublisherCheck
  }
  'Pester ' + (Get-Module -ListAvailable Pester | Sort-Object Version -Descending | Select-Object -First 1).Version.ToString()
"; then
  say "WARNING: Pester could not be installed (PowerShell Gallery blocked?). The routine cannot run the tests."
fi

say "Ready"
