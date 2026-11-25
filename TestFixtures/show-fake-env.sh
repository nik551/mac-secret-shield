#!/bin/bash
# Opens a terminal page for the AX probe: titles the window "SecretShield AX probe", prints filler lines (so there
# is scrollback to scroll through), then the FAKE fake.env and fake_key.pem, and stays open without a prompt.
set -euo pipefail
cd "$(dirname "$0")"
[ -f fake.env ] && [ -f fake_key.pem ] || ./make-fixtures.sh
printf '\033]0;SecretShield AX probe\007'
for i in $(seq 1 40); do echo "filler line $i: ordinary terminal output with nothing secret in it"; done
echo '$ cat .env'
cat fake.env
echo '$ cat deploy_key.pem'
cat fake_key.pem
echo '$ # window left open for the SecretShield AX probe'
exec sleep 86400
