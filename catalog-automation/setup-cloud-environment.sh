#!/usr/bin/env bash
# Setup script for the Claude cloud environment of the weekly catalog review routine.
# Installs PowerShell 7 and Pester so the routine can run the scripts in catalog-automation/ and
# docs-site/scripts/ and the Pester tests. Paste this into the environment's setup script field.
#
# Needs network access to github.com, api.github.com and the PowerShell Gallery.
# Safe to run again: it does nothing when pwsh and a recent Pester are already there.
set -euo pipefail

PESTER_MIN="5.6.1"

if ! command -v pwsh >/dev/null 2>&1; then
  case "$(uname -m)" in
    x86_64)  arch="x64" ;;
    aarch64) arch="arm64" ;;
    *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
  esac

  url="$(curl -fsSL https://api.github.com/repos/PowerShell/PowerShell/releases/latest | python3 -c "
import json, sys
assets = json.load(sys.stdin)['assets']
want = 'linux-$arch.tar.gz'
print(next(a['browser_download_url'] for a in assets if a['name'].endswith(want) and 'fxdependent' not in a['name'] and 'alpine' not in a['name']))
")"
  echo "Installing PowerShell from $url"

  tmp="$(mktemp -d)"
  curl -fsSL "$url" -o "$tmp/pwsh.tar.gz"
  mkdir -p /opt/microsoft/powershell
  tar -xzf "$tmp/pwsh.tar.gz" -C /opt/microsoft/powershell
  chmod +x /opt/microsoft/powershell/pwsh
  ln -sf /opt/microsoft/powershell/pwsh /usr/local/bin/pwsh
  rm -rf "$tmp"
fi

pwsh -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'

pwsh -NoProfile -Command "
  \$min = [version]'$PESTER_MIN'
  \$have = Get-Module -ListAvailable Pester | Where-Object { \$_.Version -ge \$min } | Select-Object -First 1
  if (-not \$have) {
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
    Install-Module -Name Pester -MinimumVersion \$min -Scope AllUsers -Force -SkipPublisherCheck
  }
  (Get-Module -ListAvailable Pester | Sort-Object Version -Descending | Select-Object -First 1).Version.ToString()
"

echo "Ready: pwsh and Pester >= $PESTER_MIN"
