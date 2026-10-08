#!/usr/bin/env bash
# leak-scan.sh: fail when a file carries a secret, a private host, an internal path,
# a .env file or a personal email address. grep only, no dependencies.
#
# Usage:
#   scripts/leak-scan.sh            scan the git repo you are in (tracked + untracked, not ignored)
#   scripts/leak-scan.sh <dir>      scan <dir>; at the looot-public-repos root this scans the
#                                   root files and then every repo below it
#
# A line that must keep a matching string (a rule that names the pattern it bans) carries
# the marker  leak-scan:allow  and is skipped. Use it rarely and say why next to it.
#
# Exit codes: 0 clean, 1 findings, 2 usage error.
#
# This file is the source of truth. Each repo carries an identical copy at
# scripts/leak-scan.sh so it still works when cloned alone; the root run warns on drift.

set -u

# Emails allowed anywhere: documentation placeholders and the public support address.
ALLOWED_EMAIL_RE='@example\.(com|org|net)$|^support@looot\.ai$'
if [ -n "${LEAK_SCAN_ALLOWED_EMAILS:-}" ]; then
  ALLOWED_EMAIL_RE="${ALLOWED_EMAIL_RE}|${LEAK_SCAN_ALLOWED_EMAILS}"
fi

# name|extended regex. Placeholders such as cs_ms_... or <YOUR_AGENT_TOKEN> do not match.
PATTERNS=(
  'stripe secret key|(^|[^A-Za-z0-9])sk_(live|test)_[A-Za-z0-9]{8,}'
  'stripe restricted key|rk_(live|test)_[A-Za-z0-9]{8,}'
  'webhook signing secret|whsec_[A-Za-z0-9]{8,}'
  'looot agent token|cs_ms_[A-Za-z0-9_-]{8,}'
  'openai style key|(^|[^A-Za-z0-9])sk-[A-Za-z0-9_-]{20,}'
  'github token|(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}'
  'aws access key|AKIA[0-9A-Z]{16}'
  'jwt|eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.'
  'bearer token|[Bb]earer [A-Za-z0-9._~+/=-]{24,}'
  'private key block|-----BEGIN [A-Z ]*PRIVATE KEY-----'
  'supabase host|supabase\.(co|com|in)'
  'render host|(^|[^a-z])(onrender|render)\.com'
  'db pooler host|pooler\.[a-z0-9.-]+|:6543'
  'internal coset path|~/\.coset|/\.coset/'
  'gateway source path|coset-gateway/(src|apps|packages)/'
  'local home path|/Users/[A-Za-z0-9._-]+/|/home/[A-Za-z0-9._-]+/'
)

self_name="leak-scan.sh"
findings=0

report() { # file:line:text, rule
  printf '  [%s] %s\n' "$2" "$1"
  findings=$((findings + 1))
}

list_files() { # dir -> NUL separated relative file list
  local dir="$1"
  if git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
     && [ "$(git -C "$dir" rev-parse --show-toplevel)" = "$(cd "$dir" && pwd -P)" ]; then
    git -C "$dir" ls-files -z -co --exclude-standard
  else
    # Root of looot-public-repos: only files that are not inside a repo.
    (cd "$dir" && find . -type f -not -path '*/.git/*' -not -path '*/node_modules/*' \
      -not -path '*/.venv/*' -print0 | while IFS= read -r -d '' f; do
        f="${f#./}"
        top="${f%%/*}"
        if [ "$top" != "$f" ] && [ -d "$top/.git" ]; then continue; fi
        printf '%s\0' "$f"
      done)
  fi
}

scan_dir() {
  local dir="$1" label="$2"
  local files=()
  while IFS= read -r -d '' f; do
    case "$f" in
      */"$self_name"|"$self_name") continue ;;
      node_modules/*|*/node_modules/*|.venv/*|*/.venv/*|dist/*|*/dist/*) continue ;;
    esac
    # .env files never belong in a repo, whatever they contain.
    case "$(basename "$f")" in
      .env.example|.env.sample) ;;
      .env|.env.*) report "$label/$f" ".env file" ;;
    esac
    [ -f "$dir/$f" ] || continue
    grep -Iq . "$dir/$f" 2>/dev/null || continue   # skip binary and empty files
    files+=("$f")
  done < <(list_files "$dir")

  [ "${#files[@]}" -eq 0 ] && return 0

  local entry name re hits
  for entry in "${PATTERNS[@]}"; do
    name="${entry%%|*}"
    re="${entry#*|}"
    hits=$(cd "$dir" && grep -nHE -- "$re" "${files[@]}" 2>/dev/null | grep -v 'leak-scan:allow' || true)
    if [ -n "$hits" ]; then
      while IFS= read -r h; do report "$label/${h:0:200}" "$name"; done <<< "$hits"
    fi
  done

  # Emails: anything outside the allow list is a finding.
  hits=$(cd "$dir" && grep -noHE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' "${files[@]}" 2>/dev/null || true)
  if [ -n "$hits" ]; then
    while IFS= read -r h; do
      addr="${h##*:}"
      line_ref="${h%:*}"
      if printf '%s' "$addr" | grep -qE "$ALLOWED_EMAIL_RE"; then continue; fi
      if (cd "$dir" && sed -n "${line_ref##*:}p" "${line_ref%:*}" | grep -q 'leak-scan:allow'); then continue; fi
      report "$label/$h" "email address"
    done <<< "$hits"
  fi
}

target="${1:-.}"
if [ ! -d "$target" ]; then
  echo "leak-scan: not a directory: $target" >&2
  exit 2
fi
target="$(cd "$target" && pwd -P)"

echo "leak-scan: $(basename "$target")"
scan_dir "$target" "$(basename "$target")"

# At the looot-public-repos root, also scan every repo and check the vendored copies.
if ! git -C "$target" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  root_sum=""
  [ -f "$target/scripts/$self_name" ] && root_sum=$(shasum "$target/scripts/$self_name" | cut -d' ' -f1)
  for repo in "$target"/*/; do
    repo="${repo%/}"
    [ -d "$repo/.git" ] || continue
    echo "leak-scan: $(basename "$repo")"
    scan_dir "$repo" "$(basename "$repo")"
    if [ -n "$root_sum" ] && [ -f "$repo/scripts/$self_name" ]; then
      repo_sum=$(shasum "$repo/scripts/$self_name" | cut -d' ' -f1)
      if [ "$repo_sum" != "$root_sum" ]; then
        report "$(basename "$repo")/scripts/$self_name" "copy differs from the root scanner, re-copy it"
      fi
    fi
  done
fi

if [ "$findings" -gt 0 ]; then
  echo "leak-scan: $findings finding(s). Remove them before committing."
  exit 1
fi
echo "leak-scan: clean"
exit 0
