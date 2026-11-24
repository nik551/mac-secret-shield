#!/bin/bash
# Writes fake.env and fake_key.pem: realistic-looking but FAKE secrets, generated from a fixed seed so every run
# gets the same values. They are not committed because GitHub push protection rejects anything shaped like a key.
set -euo pipefail
cd "$(dirname "$0")"
python3 - <<'PY'
import base64, random, string
r = random.Random(20261124)
A = string.ascii_letters + string.digits
def rnd(n, alpha=A): return ''.join(r.choice(alpha) for _ in range(n))
def b64url(n): return rnd(n, A + '-_')
jwt = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.' + base64.urlsafe_b64encode(b'{"sub":"fake-user-4821","role":"admin","iat":1764000000}').decode().rstrip('=') + '.' + b64url(43)
lines = [
"# FAKE secrets for SecretShield testing. Randomly generated; none of these are real credentials.",
"# Every value in this file is a seeded secret: leak-check.swift fails if any of them is readable in viewer frames.",
f"OPENAI_API_KEY=sk-proj-{b64url(48)}",
f"ANTHROPIC_API_KEY=sk-ant-api03-{b64url(86)}AA",
f"AWS_ACCESS_KEY_ID=AKIA{rnd(16, string.ascii_uppercase + string.digits)}",
f"AWS_SECRET_ACCESS_KEY={rnd(40, A + '+/')}",
f"GITHUB_TOKEN=ghp_{rnd(36)}",
f"GITHUB_PAT=github_pat_{rnd(22)}_{rnd(59)}",
f"STRIPE_SECRET_KEY=sk_live_{rnd(99)}",
f"SLACK_BOT_TOKEN=xoxb-{rnd(12, string.digits)}-{rnd(13, string.digits)}-{rnd(24)}",
f"GOOGLE_API_KEY=AIza{b64url(35)}",
f"RAZORPAY_KEY_ID=rzp_live_{rnd(14)}",
f"SESSION_SECRET={rnd(48)}",
f"JWT_TOKEN={jwt}",
f"DATABASE_URL=postgres://app_user:{rnd(24)}@db.internal.local:5432/app",
]
open('fake.env', 'w').write('\n'.join(lines) + '\n')
body = base64.b64encode(bytes(r.getrandbits(8) for _ in range(48 * 12))).decode()
pem = "-----BEGIN RSA PRIVATE KEY-----\n" + '\n'.join(body[i:i + 64] for i in range(0, len(body), 64)) + "\n-----END RSA PRIVATE KEY-----\n"
open('fake_key.pem', 'w').write(pem)
PY
