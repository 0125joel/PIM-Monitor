#!/usr/bin/env bash
# Brengt wijzigingen die op public main zijn gekomen (bijv. van de wekelijkse review-routine)
# terug naar dev, en zet daarna private main gelijk aan public main.
#
# Volgorde is belangrijk: eerst dev, dan main. Zo kan een volgende release de wijziging nooit
# terugdraaien, want die is dan al in dev.
#
# Omgeving:
#   PUBLIC_REPO_TOKEN   token met contents:write op 0125joel/PIM-Monitor (voor https-URL's)
#   SYNC_REPO_TOKEN     token met contents:write en workflows:write op PIM-Monitor-private
#   PUBLIC_URL          optioneel, voor tests met een lokaal pad
set -euo pipefail

PUBLIC_URL="${PUBLIC_URL:-https://github.com/0125joel/PIM-Monitor.git}"
PUB_REF="refs/remotes/public/main"

token_git() {
  local token="$1"
  shift
  if [[ -n "$token" ]]; then
    local auth
    auth="$(printf 'x-access-token:%s' "$token" | base64 | tr -d '\n')"
    git -c "http.https://github.com/.extraheader=" \
      -c "http.https://github.com/.extraheader=AUTHORIZATION: basic $auth" "$@"
  else
    git "$@"
  fi
}

# Dezelfde token houdt af en toe alleen het publieke repo open, daarom mag de private
# push-token apart worden gezet. De fallback bewaart compatibiliteit met de oude secret.
PUBLIC_REPO_TOKEN="${PUBLIC_REPO_TOKEN:-}"
SYNC_REPO_TOKEN="${SYNC_REPO_TOKEN:-$PUBLIC_REPO_TOKEN}"
[[ -n "$PUBLIC_REPO_TOKEN" ]] || { echo "FOUT: PUBLIC_REPO_TOKEN niet gezet." >&2; exit 1; }
[[ -n "$SYNC_REPO_TOKEN" ]] || { echo "FOUT: SYNC_REPO_TOKEN niet gezet." >&2; exit 1; }

token_git "$SYNC_REPO_TOKEN" fetch --quiet origin dev main
token_git "$PUBLIC_REPO_TOKEN" fetch --quiet "$PUBLIC_URL" "+refs/heads/main:$PUB_REF"

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
token_git "$SYNC_REPO_TOKEN" push --quiet origin "HEAD:refs/heads/dev"
echo "Public main gemerged in dev: $(git rev-parse --short HEAD)"

# Main alleen fast-forwarden als public main er bovenop zit. Anders niet aanraken.
if git merge-base --is-ancestor origin/main "$PUB_REF"; then
  token_git "$SYNC_REPO_TOKEN" push --quiet origin "$PUB_REF:refs/heads/main"
  echo "Private main gelijk aan public main."
else
  echo "FOUT: main heeft commits die public niet heeft. Main is niet aangeraakt." >&2
  exit 1
fi
