#!/bin/bash
set -euo pipefail

# Read only the published commit's changelog; a later main push must never
# supply notes for an earlier release. --check exercises the same flow read-only.
fail() { echo "error: $*" >&2; exit 1; }
repo=''
tag=''
release_sha=''
check_only=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo|--tag|--sha)
      [[ $# -ge 2 ]] || fail "missing value for $1"
      case "$1" in
        --repo) repo="$2" ;;
        --tag) tag="$2" ;;
        --sha) release_sha="$2" ;;
      esac
      shift 2
      ;;
    --check) check_only=true; shift ;;
    *) fail "unknown argument: $1" ;;
  esac
done
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail 'expected --repo OWNER/REPO'
[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$ ]] || fail 'expected --tag vSEMVER'
[[ "$release_sha" =~ ^[0-9a-f]{40}$ ]] || fail 'expected --sha with the full release commit'

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

# Release Please creates lightweight tags, but dereference annotated tags too.
ref=$(gh api "repos/$repo/git/ref/tags/$tag" --jq '[.object.type, .object.sha] | join(" ")')
for ((depth = 0; depth < 16; depth++)); do
  type=${ref%% *}
  sha=${ref#* }
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || fail 'malformed tag object response'
  if [[ "$type" == commit ]]; then break; fi
  [[ "$type" == tag ]] || fail "unexpected tag object type: $type"
  ref=$(gh api "repos/$repo/git/tags/$sha" --jq '[.object.type, .object.sha] | join(" ")')
done
[[ "$type" == commit && "$sha" == "$release_sha" ]] || fail 'tag does not point to the release commit'
git show "$release_sha:CHANGELOG.md" > "$scratch/changelog.md"

# Match one exact release heading, ignoring examples inside Markdown fences.
# Buffer the section so duplicate/empty entries fail before any public write.
awk -v version="${tag#v}" '
  BEGIN { prefix = "## [" version "]"; matches = 0; count = 0; last = 0; body = 0; active = 0; fence = "" }
  {
    line = $0
    sub(/\r$/, "", line)
    if (line ~ /^ *```/ || line ~ /^ *~~~/) {
      marker = line
      sub(/^ */, "", marker)
      char = substr(marker, 1, 1)
      width = 0
      while (substr(marker, width + 1, 1) == char) width++
      rest = substr(marker, width + 1)
      if (fence == "") { fence = char; fence_width = width }
      else if (fence == char && width >= fence_width && rest ~ /^[[:space:]]*$/) fence = ""
    } else if (fence == "" && line ~ /^## /) {
      active = 0
      if (substr(line, 1, length(prefix)) == prefix &&
          (length(line) == length(prefix) || substr(line, length(prefix) + 1, 1) ~ /[ (]/)) {
        matches++
        active = 1
      }
    }
    if (active) {
      lines[++count] = line
      if (line ~ /[^[:space:]]/) {
        last = count
        if (count > 1) body = 1
      }
    }
  }
  END {
    if (matches != 1 || !body) {
      print "error: expected one non-empty changelog section for " version > "/dev/stderr"
      exit 1
    }
    for (i = 1; i <= last; i++) print lines[i]
  }
' "$scratch/changelog.md" > "$scratch/notes.md"

metadata=$(gh release view "$tag" --repo "$repo" --json tagName,isDraft --jq '[.tagName, (.isDraft | tostring)] | join(" ")')
[[ "$metadata" == "$tag false" ]] || fail 'release is missing, draft, or has the wrong tag'
gh release view "$tag" --repo "$repo" --json body --jq '.body' > "$scratch/before.md"
if [[ "$(cat "$scratch/before.md")" != "$(cat "$scratch/notes.md")" ]]; then
  if [[ "$check_only" == true ]]; then fail 'published release notes differ from the tagged changelog'; fi
  gh release edit "$tag" --repo "$repo" --notes-file "$scratch/notes.md"
fi
# A successful API write is insufficient: detect dropped/partial updates too.
gh release view "$tag" --repo "$repo" --json body --jq '.body' > "$scratch/after.md"
[[ "$(cat "$scratch/after.md")" == "$(cat "$scratch/notes.md")" ]] || fail 'release notes readback differs from the tagged changelog'
echo "Verified $repo $tag release notes against $release_sha"
