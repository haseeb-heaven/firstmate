#!/usr/bin/env bash
# lib/gh.sh — GitHub API helpers
set -euo pipefail

require_pr_open() {
  local owner="$1" repo="$2" pr_num="$3" state
  state=$(gh api "/repos/$owner/$repo/pulls/$pr_num" --jq '.state' 2>/dev/null) || return 1
  [[ "$state" == open ]] || { echo "ERROR: PR #$pr_num is $state; mutation refused" >&2; return 1; }
}

get_review_thread_comments() {
  local thread_id="$1" cursor="null" response page comments='[]'
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
        echo "ERROR: unable to paginate comments for review thread $thread_id" >&2
        return 1
      }
    page=$(jq '.data.node.comments.nodes // []' <<<"$response") || return 1
    comments=$(jq -s '.[0] + .[1]' <(printf '%s\n' "$comments") <(printf '%s\n' "$page"))
    if [[ "$(jq -r '.data.node.comments.pageInfo.hasNextPage // false' <<<"$response")" != true ]]; then
      break
    fi
    cursor=$(jq -r '.data.node.comments.pageInfo.endCursor // empty' <<<"$response")
    [[ -n "$cursor" ]] || return 1
  done
  printf '%s\n' "$comments"
}

get_unresolved_comments() {
  local owner="$1" repo="$2" pr_num="$3" cursor="null" response page threads='[]'
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
        echo "ERROR: unable to query GitHub review threads" >&2
        return 1
      }
    page=$(jq '.data.repository.pullRequest.reviewThreads.nodes // []' <<<"$response") || return 1
    threads=$(jq -s '.[0] + .[1]' <(printf '%s\n' "$threads") <(printf '%s\n' "$page"))
    if [[ "$(jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage' <<<"$response")" != true ]]; then break; fi
    cursor=$(jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.endCursor' <<<"$response")
    [[ -n "$cursor" && "$cursor" != null ]] || return 1
  done

  local results='[]' thread thread_id comments item
  while IFS= read -r thread; do
    [[ -n "$thread" ]] || continue
    thread_id=$(jq -r '.id // empty' <<<"$thread")
    [[ -n "$thread_id" ]] || continue
    comments=$(get_review_thread_comments "$thread_id") || return 1
    [[ "$(jq 'length' <<<"$comments")" -gt 0 ]] || continue
    item=$(jq -n --arg id "$thread_id" --argjson comments "$comments" '
      {id:$id,
       path: ($comments[0].path // "unknown"),
       line: ($comments[0].line // $comments[0].originalLine),
       body: ($comments | map((.author.login // "unknown") + ":\n" + (.body // "")) | join("\n\n---\n\n")),
       author: ($comments[0].author.login // "unknown")}' )
    results=$(jq -s '.[0] + [.[1]]' <(printf '%s\n' "$results") <(printf '%s\n' "$item"))
  done < <(jq -c '.[] | select(.isResolved == false and .isOutdated == false)' <<<"$threads")

  printf '%s\n' "$results"
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
