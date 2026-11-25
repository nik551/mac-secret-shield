#!/bin/bash
# Gate 2 stress page: prints the FAKE fixture as fast as possible for ~5 s (fast printing, scrolling output), then
# leaves it on screen for the stress run (window title "SecretShield AX probe", same as the probe page).
set -euo pipefail
cd "$(dirname "$0")"
[ -f fake.env ] && [ -f fake_key.pem ] || ./make-fixtures.sh
printf '\033]0;SecretShield AX probe\007'
end=$((SECONDS + 5))
while [ $SECONDS -lt $end ]; do
  for i in $(seq 1 10); do echo "filler line $i: ordinary terminal output with nothing secret in it"; done
  echo '$ cat .env'; cat fake.env
  echo '$ cat deploy_key.pem'; cat fake_key.pem
done
echo '$ echo $JWT_TOKEN'; grep '^JWT_TOKEN=' fake.env | cut -d= -f2-
echo '$ # window left open for the SecretShield AX probe'
exec sleep 86400
