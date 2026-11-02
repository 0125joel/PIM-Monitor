#!/usr/bin/env bash
# Brengt wijzigingen die op public main zijn gekomen (bijv. van de wekelijkse review-routine)
# terug naar dev, en zet daarna private main gelijk aan public main.
#
# Volgorde is belangrijk: eerst dev, dan main. Zo kan een volgende release de wijziging nooit
# terugdraaien, want die is dan al in dev.
#
# Omgeving:
#   PUBLIC_REPO_TOKEN   token met contents:write op 0125joel/PIM-Monitor (voor https-URL's)
#   PUBLIC_URL          optioneel, voor tests met een lokaal pad
set -euo pipefail

PUBLIC_URL="${PUBLIC_URL:-https://github.com/0125joel/PIM-Monitor.git}"
PUB_REF="refs/remotes/public/main"

# Zelfde token-aanpak als sync-to-main.sh.
pub_git() {
  if [[ "$PUBLIC_URL" == https://github.com/* ]]; then
    [[ -n "${PUBLIC_REPO_TOKEN:-}" ]] || { echo "FOUT: PUBLIC_REPO_TOKEN niet gezet." >&2; exit 1; }
    local auth
    auth="$(printf 'x-access-token:%s' "$PUBLIC_REPO_TOKEN" | base64 | tr -d '\n')"
    git -c "http.https://github.com/.extraheader=" \
        -c "http.https://github.com/.extraheader=AUTHORIZATION: basic $auth" "$@"
  else
    git "$@"
  fi
}

git fetch --quiet origin dev main
pub_git fetch --quiet "$PUBLIC_URL" "+refs/heads/main:$PUB_REF"

# Staat public main al in dev: niets te doen.
if git merge-base --is-ancestor "$PUB_REF" origin/dev; then
  echo "dev bevat al alles van public main. Niets te doen."
  exit 0
fi

# Merge public main in dev. Bij een conflict stopt de run, en dev blijft ongewijzigd.
git checkout --quiet -B dev origin/dev
if ! git merge --no-ff --quiet -m "chore: bring changes from public main into dev" "$PUB_REF"; then
  git merge --abort
  echo "FOUT: conflict tussen public main en dev. Los dit op in dev. De volgende run pakt het dan op." >&2
  exit 1
fi
git push --quiet origin "HEAD:refs/heads/dev"
echo "Public main gemerged in dev: $(git rev-parse --short HEAD)"

# Main alleen fast-forwarden als public main er bovenop zit. Anders niet aanraken.
if git merge-base --is-ancestor origin/main "$PUB_REF"; then
  git push --quiet origin "$PUB_REF:refs/heads/main"
  echo "Private main gelijk aan public main."
else
  echo "FOUT: main heeft commits die public niet heeft. Main is niet aangeraakt." >&2
  exit 1
fi
