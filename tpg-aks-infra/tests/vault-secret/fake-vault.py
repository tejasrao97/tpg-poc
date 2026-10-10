#!/usr/bin/env python3
"""The vault CLI subset scripts/vault-secret.sh runs inside vault-0 (through the
stub kubectl): status, the tpg-setup login, kv put/get/list/metadata delete and
write -wrap-ttl sys/wrapping/wrap. State in $FAKE_VAULT_STATE; token in VAULT_TOKEN.
Refuses argument forms the real CLI would not accept in the way the script uses them."""
import json, os, sys

state_f = os.environ["FAKE_VAULT_STATE"]
st = json.load(open(state_f)) if os.path.exists(state_f) else {"kv": {}, "wrapped": None}
a = sys.argv[1:]


def save():
    json.dump(st, open(state_f, "w"))


def die(msg, code=2):
    print(msg, file=sys.stderr)
    sys.exit(code)


if a[:2] == ["status", "-format=json"]:
    print(json.dumps({"initialized": True, "sealed": False, "type": "shamir"}))
    sys.exit(0)
if a[:2] == ["write", "-field=token"] and a[2] == "auth/kubernetes/login":
    if "role=tpg-setup" in a and "jwt=-" in a and sys.stdin.read() == "jwt-tpg-setup":
        print("tok-admin", end="")
        sys.exit(0)
    die("permission denied")
if os.environ.get("VAULT_TOKEN") != "tok-admin":
    die("permission denied")
if a[:2] == ["token", "lookup"]:
    print("{}")
    sys.exit(0)
if a[:1] == ["kv"]:
    if a[1] == "metadata" and a[2] == "delete":
        assert a[3] == "-mount=tpg", a
        st["kv"].pop(a[4], None); save(); sys.exit(0)
    assert a[2] == "-mount=tpg", a
    if a[1] == "put":
        assert a[3:5] and a[4] == "-" and len(a) == 5, a
        st["kv"][a[3]] = json.loads(sys.stdin.read()); save(); sys.exit(0)
    if a[1] == "get":
        assert a[3] == "-format=json", a
        if a[4] not in st["kv"]:
            die("No value found at tpg/data/" + a[4])
        print(json.dumps({"data": {"data": st["kv"][a[4]]}})); sys.exit(0)
    if a[1] == "list":
        assert a[3] == "-format=json", a
        keys = sorted(k[len(a[4]) + 1:] for k in st["kv"] if k.startswith(a[4] + "/"))
        if not keys:
            die("No value found")
        print(json.dumps(keys)); sys.exit(0)
if a == ["write", "-wrap-ttl=10m", "-format=json", "sys/wrapping/wrap", "-"]:
    st["wrapped"] = json.loads(sys.stdin.read()); save()
    print(json.dumps({"wrap_info": {"token": "hvs.wrapped-exec", "ttl": 600}}))
    sys.exit(0)
die("fake vault: unsupported " + " ".join(a))
