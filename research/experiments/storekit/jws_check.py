#!/usr/bin/env python3
"""Check a StoreKit JWS (compact serialization) the way any verifier would:
decode the header, take the x5c leaf certificate, and verify the ES256
signature over "header.payload" with openssl. Prints the header fields, the
leaf certificate's subject/issuer/fingerprint and the verification result.
Prints no key material. Usage: python3 -I jws_check.py FILE.jws [...]
"""
import base64, json, subprocess, sys, tempfile, os


def b64u(s):
    s += "=" * (-len(s) % 4)
    return base64.urlsafe_b64decode(s)


def der_int(b):
    b = b.lstrip(b"\x00") or b"\x00"
    if b[0] & 0x80:
        b = b"\x00" + b
    return b"\x02" + bytes([len(b)]) + b


def raw_to_der(sig):
    n = len(sig) // 2
    body = der_int(sig[:n]) + der_int(sig[n:])
    return b"\x30" + bytes([len(body)]) + body


def check(path):
    tok = open(path).read().strip()
    h, p, s = tok.split(".")
    hdr = json.loads(b64u(h))
    x5c = hdr.get("x5c", [])
    print(path)
    print("  header:", {k: v for k, v in hdr.items() if k != "x5c"}, "x5c certs:", len(x5c))
    with tempfile.TemporaryDirectory() as td:
        for i, c in enumerate(x5c):
            der = base64.b64decode(c)
            cp = os.path.join(td, f"c{i}.der")
            open(cp, "wb").write(der)
            out = subprocess.run(["openssl", "x509", "-inform", "DER", "-in", cp, "-noout",
                                  "-subject", "-issuer", "-dates", "-fingerprint", "-sha256"],
                                 capture_output=True, text=True).stdout
            print(f"  x5c[{i}] {len(der)} bytes:", " | ".join(out.strip().splitlines()))
        if x5c:
            cp = os.path.join(td, "c0.der")
            pub = os.path.join(td, "pub.pem")
            subprocess.run(["openssl", "x509", "-inform", "DER", "-in", cp, "-pubkey", "-noout", "-out", pub], check=True)
            msg = os.path.join(td, "msg")
            open(msg, "wb").write((h + "." + p).encode())
            sg = os.path.join(td, "sig")
            open(sg, "wb").write(raw_to_der(b64u(s)))
            r = subprocess.run(["openssl", "dgst", "-sha256", "-verify", pub, "-signature", sg, msg],
                               capture_output=True, text=True)
            print("  signature:", (r.stdout + r.stderr).strip())


for f in sys.argv[1:]:
    check(f)
