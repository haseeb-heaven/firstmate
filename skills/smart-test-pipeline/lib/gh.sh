#!/usr/bin/env bash
# lib/gh.sh — GitHub API helpers
set -euo pipefail

require_pr_open() {
  local owner="$1" repo="$2" pr_num="$3" state
  state=$(gh api "/repos/$owner/$repo/pulls/$pr_num" --jq '.state' 2>/dev/null) || return 1
  [[ "$state" == open ]] || { echo "ERROR: PR #$pr_num is $state; mutation refused" >&2; return 1; }
}

get_review_thread_comments() {
  local thread_id="$1" cursor="null" response tmp
  tmp=$(mktemp "${TMPDIR:-/tmp}/smart-review-thread.XXXXXX") || return 1
  : > "$tmp"
  while :; do
    response=$(gh api graphql \
      -f query='query($id:ID!, $after:String) {
        node(id:$id) {
          ... on PullRequestReviewThread {
            comments(first:100, after:$after) {
              pageInfo { hasNextPage endCursor }
              nodes { databaseId body path line originalLine author { login } }
            }
          }
        }
      }' -f id="$thread_id" -F after="$cursor" 2>/dev/null) || {
        rm -f "$tmp"
        echo "ERROR: unable to paginate comments for review thread $thread_id" >&2
        return 1
      }
    if ! jq -c '.data.node.comments.nodes[]?' <<<"$response" >> "$tmp"; then
      rm -f "$tmp"
      return 1
    fi
    if [[ "$(jq -r '.data.node.comments.pageInfo.hasNextPage // false' <<<"$response")" != true ]]; then
      break
    fi
    cursor=$(jq -r '.data.node.comments.pageInfo.endCursor // empty' <<<"$response")
    if [[ -z "$cursor" ]]; then
      rm -f "$tmp"
      return 1
    fi
  done
  jq -s '.' "$tmp"
  local rc=$?
  rm -f "$tmp"
  return "$rc"
}

get_unresolved_comments() {
  local owner="$1" repo="$2" pr_num="$3" cursor="null" response
  local body_limit="${REVIEW_THREAD_BODY_LIMIT:-262144}"
  local total_limit="${REVIEW_FINDINGS_TOTAL_LIMIT:-4194304}"
  [[ "$body_limit" =~ ^[1-9][0-9]*$ && "$total_limit" =~ ^[1-9][0-9]*$ ]] || {
    echo "ERROR: review payload limits must be positive integers" >&2
    return 2
  }

  local threads_file results_file comments_file
  threads_file=$(mktemp "${TMPDIR:-/tmp}/smart-review-threads.XXXXXX") || return 1
  results_file=$(mktemp "${TMPDIR:-/tmp}/smart-review-results.XXXXXX") || { rm -f "$threads_file"; return 1; }
  comments_file=$(mktemp "${TMPDIR:-/tmp}/smart-review-comments.XXXXXX") || { rm -f "$threads_file" "$results_file"; return 1; }
  : > "$threads_file"
  : > "$results_file"

  while :; do
    response=$(gh api graphql \
      -f query='query($owner:String!, $repo:String!, $number:Int!, $after:String) {
        repository(owner:$owner, name:$repo) {
          pullRequest(number:$number) {
            reviewThreads(first:100, after:$after) {
              pageInfo { hasNextPage endCursor }
              nodes { id isResolved isOutdated }
            }
          }
        }
      }' -f owner="$owner" -f repo="$repo" -F number="$pr_num" -F after="$cursor" 2>/dev/null) || {
        rm -f "$threads_file" "$results_file" "$comments_file"
        echo "ERROR: unable to query GitHub review threads" >&2
        return 1
      }
    if ! jq -c '.data.repository.pullRequest.reviewThreads.nodes[]?' <<<"$response" >> "$threads_file"; then
      rm -f "$threads_file" "$results_file" "$comments_file"
      return 1
    fi
    if [[ "$(jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage // false' <<<"$response")" != true ]]; then
      break
    fi
    cursor=$(jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.endCursor // empty' <<<"$response")
    if [[ -z "$cursor" ]]; then
      rm -f "$threads_file" "$results_file" "$comments_file"
      return 1
    fi
  done

  local thread thread_id result_size
  while IFS= read -r thread; do
    [[ -n "$thread" ]] || continue
    thread_id=$(jq -r '.id // empty' <<<"$thread")
    [[ -n "$thread_id" ]] || continue
    if ! get_review_thread_comments "$thread_id" > "$comments_file"; then
      rm -f "$threads_file" "$results_file" "$comments_file"
      return 1
    fi
    [[ "$(jq 'length' "$comments_file")" -gt 0 ]] || continue
    if ! jq -c --arg id "$thread_id" --argjson limit "$body_limit" '
      (map((.author.login // "unknown") + ":\n" + (.body // "")) | join("\n\n---\n\n")) as $joined
      | ($joined | if length > $limit then .[0:$limit] + "\n\n[thread body truncated by smart-test-pipeline]" else . end) as $bounded
      | {id:$id,
         path: (.[0].path // "unknown"),
         line: (.[0].line // .[0].originalLine),
         body: $bounded,
         author: (.[0].author.login // "unknown")}' "$comments_file" >> "$results_file"; then
      rm -f "$threads_file" "$results_file" "$comments_file"
      return 1
    fi
    result_size=$(wc -c < "$results_file" | tr -d ' ')
    [[ "$result_size" =~ ^[0-9]+$ ]] || result_size=0
    if [[ "$result_size" -gt "$total_limit" ]]; then
      rm -f "$threads_file" "$results_file" "$comments_file"
      echo "ERROR: unresolved review payload exceeds REVIEW_FINDINGS_TOTAL_LIMIT=$total_limit" >&2
      return 1
    fi
  done < <(jq -c 'select(.isResolved == false and .isOutdated == false)' "$threads_file")

  jq -s '.' "$results_file"
  local rc=$?
  rm -f "$threads_file" "$results_file" "$comments_file"
  return "$rc"
}

capture_review_baseline() {
  local owner="$1" repo="$2" pr_num="$3" bots="$4" baseline_file="$5"
  : > "$baseline_file"
  local bot login review_comments issue_comments review_id issue_id
  for bot in $bots; do
    case "$bot" in
      coderabbit) login="coderabbitai[bot]" ;;
      greptile) login="greptile-apps[bot]" ;;
      *) echo "ERROR: unsupported review bot: $bot" >&2; return 1 ;;
    esac
    review_comments=$(gh api --paginate --slurp "/repos/$owner/$repo/pulls/$pr_num/comments") || return 1
    issue_comments=$(gh api --paginate --slurp "/repos/$owner/$repo/issues/$pr_num/comments") || return 1
    review_id=$(jq --arg login "$login" '[.[][] | select(.user.login == $login) | .id] | max // 0' <<<"$review_comments")
    issue_id=$(jq --arg login "$login" '[.[][] | select(.user.login == $login) | .id] | max // 0' <<<"$issue_comments")
    printf '%s %s %s\n' "$bot" "$review_id" "$issue_id" >> "$baseline_file"
  done
}

is_review_bot_done() {
  local bot="$1" owner="$2" repo="$3" pr_num="$4" baseline_file="$5" login review_baseline issue_baseline
  case "$bot" in
    coderabbit) login="coderabbitai[bot]" ;;
    greptile) login="greptile-apps[bot]" ;;
    *) return 1 ;;
  esac
  review_baseline=$(awk -v bot="$bot" '$1 == bot { print $2 }' "$baseline_file")
  issue_baseline=$(awk -v bot="$bot" '$1 == bot { print $3 }' "$baseline_file")
  [[ -n "$review_baseline" && -n "$issue_baseline" ]] || return 1
  local review_comments issue_comments bodies
  review_comments=$(gh api --paginate --slurp "/repos/$owner/$repo/pulls/$pr_num/comments") || return 1
  issue_comments=$(gh api --paginate --slurp "/repos/$owner/$repo/issues/$pr_num/comments") || return 1
  bodies=$(jq -r --arg login "$login" --argjson baseline "$review_baseline" '[.[][] | select(.user.login == $login and .id > $baseline) | .body] | .[]' <<<"$review_comments")$'\n'
  bodies+=$(jq -r --arg login "$login" --argjson baseline "$issue_baseline" '[.[][] | select(.user.login == $login and .id > $baseline) | .body] | .[]' <<<"$issue_comments")
  case "$bot" in
    coderabbit) grep -Eiq '^[[:space:]]*(✅[[:space:]]*)?(review complete(d)?|all comments resolved|no issues found)[.![:space:]]*$' <<<"$bodies" ;;
    greptile) grep -Eiq '^[[:space:]]*(✅[[:space:]]*)?(review complete(d)?|no issues found|no findings|lgtm)[.![:space:]]*$' <<<"$bodies" ;;
  esac
}

trigger_coderabbit() { require_pr_open "$1" "$2" "$3" && gh api --method POST -f body='@coderabbitai review' "/repos/$1/$2/issues/$3/comments" >/dev/null; }
trigger_greptile() { require_pr_open "$1" "$2" "$3" && gh api --method POST -f body='@greptile review' "/repos/$1/$2/issues/$3/comments" >/dev/null; }
get_pr_state() { gh api "/repos/$1/$2/pulls/$3" --jq '.state'; }
