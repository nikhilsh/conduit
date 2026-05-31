#!/usr/bin/env bash
set -euo pipefail

# Conduit Sentry triage helper.
# Defaults:
# - org: conduit
# - projects: apple-ios, android
# - unresolved issues query
# - optional recent-event samples
#
# Auth resolution order:
# 1) SENTRY_AUTH_TOKEN env var
# 2) /root/.config/sentry/auth-token

ORG="${SENTRY_ORG:-conduit}"
PROJECTS="${SENTRY_PROJECTS:-apple-ios,android}"
QUERY="${SENTRY_QUERY:-is:unresolved}"
LIMIT="${SENTRY_LIMIT:-20}"
SHOW_EVENTS="${SENTRY_SHOW_EVENTS:-1}"
EVENTS_PER_PROJECT="${SENTRY_EVENTS_PER_PROJECT:-5}"

if [[ -z "${SENTRY_AUTH_TOKEN:-}" ]]; then
  if [[ -f "/root/.config/sentry/auth-token" ]]; then
    SENTRY_AUTH_TOKEN="$(< /root/.config/sentry/auth-token)"
  else
    echo "error: no SENTRY_AUTH_TOKEN in env and /root/.config/sentry/auth-token missing" >&2
    exit 1
  fi
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "error: curl is required" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required" >&2
  exit 1
fi

api() {
  local method="$1"
  local url="$2"
  shift 2
  curl -sS -X "$method" \
    -H "Authorization: Bearer ${SENTRY_AUTH_TOKEN}" \
    "$url" "$@"
}

fetch_projects_json() {
  api GET "https://sentry.io/api/0/organizations/${ORG}/projects/"
}

project_id_for_slug() {
  local slug="$1"
  local projects_json="$2"
  echo "$projects_json" | jq -r --arg slug "$slug" '.[] | select(.slug == $slug) | .id' | head -n1
}

api_with_retry() {
  local out
  out="$("$@")"
  if echo "$out" | rg -q "502 Server Error|temporary error"; then
    sleep 1
    out="$("$@")"
  fi
  echo "$out"
}

echo "Sentry org: ${ORG}"
echo "Projects: ${PROJECTS}"
echo "Query: ${QUERY}"
echo

projects_catalog="$(api_with_retry fetch_projects_json)"
if ! echo "$projects_catalog" | jq -e 'type=="array"' >/dev/null 2>&1; then
  echo "error: failed to list projects for org ${ORG}"
  echo "$projects_catalog"
  exit 1
fi

IFS=',' read -r -a project_arr <<<"${PROJECTS}"
for project in "${project_arr[@]}"; do
  project="$(echo "$project" | xargs)"
  [[ -z "$project" ]] && continue
  project_id="$(project_id_for_slug "$project" "$projects_catalog")"
  if [[ -z "$project_id" || "$project_id" == "null" ]]; then
    echo "== Issues: ${project} =="
    echo "error: project slug not found in org ${ORG}"
    echo
    continue
  fi
  echo "== Issues: ${project} =="
  issues_json="$(api_with_retry api GET "https://sentry.io/api/0/organizations/${ORG}/issues/" \
    --get \
    --data-urlencode "project=${project_id}" \
    --data-urlencode "query=${QUERY}" \
    --data-urlencode "limit=${LIMIT}")"
  if ! echo "$issues_json" | jq -e 'type=="array"' >/dev/null 2>&1; then
    echo "error: failed to fetch issues for ${project}"
    echo "$issues_json"
    echo
    continue
  fi
  issue_count="$(echo "$issues_json" | jq 'length')"
  echo "count=${issue_count}"
  if [[ "$issue_count" -gt 0 ]]; then
    echo "$issues_json" | jq -r '.[] | [
      .shortId,
      .title,
      ("count=" + (.count // "0")),
      ("lastSeen=" + (.lastSeen // "")),
      ("status=" + (.status // ""))
    ] | @tsv'
  fi
  echo

  if [[ "$SHOW_EVENTS" == "1" ]]; then
    echo "== Event Samples: ${project} =="
    events_json="$(api_with_retry api GET "https://sentry.io/api/0/organizations/${ORG}/events/" \
      --get \
      --data-urlencode "project=${project_id}" \
      --data-urlencode "query=timestamp:>=-7d" \
      --data-urlencode "field=title" \
      --data-urlencode "field=timestamp" \
      --data-urlencode "field=project" \
      --data-urlencode "field=message" \
      --data-urlencode "sort=-timestamp" \
      --data-urlencode "per_page=${EVENTS_PER_PROJECT}")"
    if echo "$events_json" | jq -e 'type=="object" and has("data")' >/dev/null 2>&1; then
      sample_count="$(echo "$events_json" | jq '.data | length')"
      echo "samples=${sample_count}"
      if [[ "$sample_count" -gt 0 ]]; then
        echo "$events_json" | jq -r '.data[] | [
          .timestamp,
          .project,
          .title,
          (.message // "")
        ] | @tsv'
      fi
    else
      echo "samples=0 (events query unavailable for this token/scope)"
    fi
    echo
  fi
done

echo "Done."
