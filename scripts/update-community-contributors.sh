#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_FILE="${OUTPUT_FILE:-CONTRIBUTORS.md}"
OUT_PATH="$ROOT_DIR/$OUT_FILE"

SOURCE_OWNER="${SOURCE_OWNER:-ambicuity}"
SOURCE_REPO="${SOURCE_REPO:-pomodo-feedback}"

MAINTAINER_NAME="${MAINTAINER_NAME:-Ritesh Rana}"
MAINTAINER_EMAIL="${MAINTAINER_EMAIL:-contact@riteshrana.engineer}"
MAINTAINER_LOGINS="${MAINTAINER_LOGINS:-riteshr19}"

if [[ -z "${GITHUB_TOKEN:-}" ]]; then
  echo "GITHUB_TOKEN is required." >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required." >&2
  exit 1
fi

tmp_logins="$(mktemp)"
tmp_output="$(mktemp)"
trap 'rm -f "$tmp_logins" "$tmp_output"' EXIT

cursor="null"

while :; do
  query='query($owner:String!, $repo:String!, $cursor:String) {
    repository(owner:$owner, name:$repo) {
      issues(first:100, after:$cursor) {
        nodes {
          author {
            login
          }
        }
        pageInfo {
          hasNextPage
          endCursor
        }
      }
    }
  }'

  payload="$(jq -nc \
    --arg q "$query" \
    --arg owner "$SOURCE_OWNER" \
    --arg repo "$SOURCE_REPO" \
    --argjson cursor "$cursor" \
    '{query:$q, variables:{owner:$owner, repo:$repo, cursor:$cursor}}')"

  response="$(curl -fsSL \
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "Content-Type: application/json" \
    -X POST \
    -d "$payload" \
    https://api.github.com/graphql)"

  if [[ "$(jq 'has("errors")' <<<"$response")" == "true" ]]; then
    jq -r '.errors[]?.message' <<<"$response" >&2
    exit 1
  fi

  jq -r '.data.repository.issues.nodes[].author.login // empty' <<<"$response" >> "$tmp_logins"

  has_next="$(jq -r '.data.repository.issues.pageInfo.hasNextPage' <<<"$response")"
  if [[ "$has_next" != "true" ]]; then
    break
  fi

  end_cursor="$(jq -r '.data.repository.issues.pageInfo.endCursor' <<<"$response")"
  cursor="$(jq -nc --arg c "$end_cursor" '$c')"
done

{
  printf '%s\n' '# Pomodo Contributors'
  printf '\n'
  printf '%s\n' 'This file is auto-generated from issue creators in the public feedback repository.'
  printf '\n'
  printf 'Owner and Maintainer: **%s** (`%s`)\n' "$MAINTAINER_NAME" "$MAINTAINER_EMAIL"
  printf '\n'
  printf '%s\n' '## Community Contributors'
  printf '\n'
} > "$tmp_output"

contributors="$(
  awk 'NF {print tolower($0)}' "$tmp_logins" \
    | awk '!seen[$0]++' \
    | awk -v maint="$MAINTAINER_LOGINS" '
BEGIN {
  split(tolower(maint), arr, ",")
  for (i in arr) {
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", arr[i])
    if (arr[i] != "") exclude[arr[i]] = 1
  }
}
{
  if ($0 ~ /\[bot\]$/ || $0 ~ /bot$/ || $0 ~ /github-actions/) next
  if (exclude[$0]) next
  print $0
}
' \
    | LC_ALL=C sort || true
)"

if [[ -n "$contributors" ]]; then
  while IFS= read -r login; do
    printf -- '- [@%s](https://github.com/%s)\n' "$login" "$login" >> "$tmp_output"
  done <<< "$contributors"
else
  printf '%s\n' '- No community issue contributors yet.' >> "$tmp_output"
fi

{
  printf '\n'
  printf 'Last updated: `%s`\n' "$(date -u +'%Y-%m-%d %H:%M UTC')"
} >> "$tmp_output"

mv "$tmp_output" "$OUT_PATH"
