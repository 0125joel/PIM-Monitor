#!/usr/bin/env bash
# Setup script for the Claude cloud environment of the weekly catalog review routine.
# Installs PowerShell 7 and Pester so the routine can run the scripts in catalog-automation/ and
# docs-site/scripts/ and the Pester tests. Paste this into the environment's setup script field.
#
# Needs network access to github.com (release download) and, for Pester, the PowerShell Gallery.
# The PowerShell version is pinned and its checksum is verified. It does not use api.github.com,
# which answers 403 in restricted environments. Raise PWSH_VERSION on purpose when you want a newer one.
# Safe to run again: it does nothing when pwsh and a recent Pester are already there.
set -euo pipefail

PWSH_VERSION="7.6.6"
PESTER_MIN="5.6.1"

if ! command -v pwsh >/dev/null 2>&1; then
  case "$(uname -m)" in
    x86_64)  arch="x64" ;;
    aarch64) arch="arm64" ;;
    *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
  esac

  base="https://github.com/PowerShell/PowerShell/releases/download/v${PWSH_VERSION}"
  file="powershell-${PWSH_VERSION}-linux-${arch}.tar.gz"
  tmp="$(mktemp -d)"
  echo "Downloading $base/$file"

  curl -fsSL "$base/$file" -o "$tmp/$file"
  curl -fsSL "$base/hashes.sha256" -o "$tmp/hashes.sha256"

  expected="$(grep -F "$file" "$tmp/hashes.sha256" | awk '{print $1}')"
  actual="$(sha256sum "$tmp/$file" | awk '{print $1}')"
  if [ -z "$expected" ] || [ "$expected" != "$actual" ]; then
    echo "Checksum mismatch for $file (expected '$expected', got '$actual')" >&2
    exit 1
  fi

  mkdir -p /opt/microsoft/powershell
  tar -xzf "$tmp/$file" -C /opt/microsoft/powershell
  chmod +x /opt/microsoft/powershell/pwsh
  ln -sf /opt/microsoft/powershell/pwsh /usr/local/bin/pwsh
  rm -rf "$tmp"
fi

echo "PowerShell $(pwsh -NoProfile -Command '$PSVersionTable.PSVersion.ToString()')"

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
  echo "WARNING: Pester could not be installed (PowerShell Gallery blocked?). The routine cannot run the tests." >&2
fi

echo "Ready"
