#!/bin/bash
# Prints the FAKE secrets in this folder slowly, line by line, the way a terminal would during a demo.
# Usage: TestFixtures/print-secrets-slowly.sh [seconds-between-lines]   (default 0.4)
set -euo pipefail
cd "$(dirname "$0")"
[ -f fake.env ] && [ -f fake_key.pem ] || ./make-fixtures.sh
delay="${1:-0.4}"
slow() { while IFS= read -r line; do printf '%s\n' "$line"; sleep "$delay"; done; }

echo '$ cat .env'
slow < fake.env

echo '$ printenv'
{
  printf 'HOME=/Users/dev\nSHELL=/bin/zsh\nPATH=/opt/homebrew/bin:/usr/bin:/bin\nNODE_ENV=production\nPORT=3000\n'
  printf 'API_KEY=your-api-key-here\nMASKED_KEY=sk-proj-****************abcd\n'   # placeholders: must stay visible
  grep -v '^#' fake.env
} | slow

echo '$ cat deploy_key.pem'
slow < fake_key.pem

echo '$ echo $JWT_TOKEN   # one long line: wraps in a narrow window'
grep '^JWT_TOKEN=' fake.env | cut -d= -f2- | slow
