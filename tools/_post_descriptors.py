"""POST ItemBridge descriptors at the server's phase-1 validator.

Called by tools/validate-descriptors.sh; not meant to be run directly.

Transport is curl rather than urllib. Python 3.10 ships a CA bundle predating
Let's Encrypt's current intermediate, so urllib reports "certificate has
expired" against a certificate valid for months yet. curl uses a current store
and is already known-good against this host.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import time
import uuid
from collections import Counter

# curl writes the status code after this marker so the body, which may contain
# anything including newlines, can be split off unambiguously.
MARKER = "<<<HTTPSTATUS>>>"

# 60 mutations/min per key -- one per second. Pacing is per request rather than
# per batch: a batch pause lets 25 requests burst through in a couple of
# seconds, which trips the limit and reports rate-limiting as a transport
# error on descriptors that were never actually judged.
REQUEST_INTERVAL = 1.1


def post(api: str, key: str, body_path: str, payload: dict):
    with open(body_path, "w", encoding="utf-8") as fh:
        json.dump(payload, fh)

    proc = subprocess.run(
        [
            "curl", "-s", "--max-time", "25", "-X", "POST",
            "-H", f"Authorization: Bearer {key}",
            "-H", "Content-Type: application/json",
            "--data-binary", f"@{body_path}",
            "-w", MARKER + "%{http_code}",
            f"{api}/listings",
        ],
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        return None, (proc.stderr.strip() or f"curl exit {proc.returncode}")
    if MARKER not in proc.stdout:
        return None, "malformed curl output"
    body, _, code = proc.stdout.rpartition(MARKER)
    return (code.strip(), body), None


def main() -> int:
    api = os.environ["API"]
    key = os.environ["KEY"]
    work = os.environ["WORK"]
    limit = int(os.environ.get("LIMIT", "0"))

    cases = json.load(open(sys.argv[1], encoding="utf-8"))["cases"]
    sent = [c for c in cases if "descriptor" in c]
    refused = [c for c in cases if "refused_locally" in c]
    if limit:
        sent = sent[:limit]

    body_path = os.path.join(work, "body.json")
    accepted = 0
    rejected: list[tuple[str, str, str]] = []
    errors: list[tuple[str, str]] = []

    for i, case in enumerate(sent, 1):
        result, err = post(api, key, body_path, {
            "idempotency_key": str(uuid.uuid4()),
            "descriptor": case["descriptor"],
            "ask_price": 1000,
            "catalog_version": 2,
        })

        if err is not None:
            errors.append((case["label"], err))
        else:
            code, payload = result
            if code.startswith("2"):
                accepted += 1
            elif code == "429":
                time.sleep(2.0)
                errors.append((case["label"], "rate limited"))
            else:
                try:
                    msg = json.loads(payload).get("message", payload)
                except Exception:
                    msg = payload[:200]
                rejected.append((case["label"], code, msg))

        if i % 25 == 0:
            print(f"  ... {i}/{len(sent)}")
        if i < len(sent):
            time.sleep(REQUEST_INTERVAL)

    print()
    print(f"sent      {len(sent)}")
    print(f"accepted  {accepted}")
    print(f"rejected  {len(rejected)}")
    print(f"errors    {len(errors)}")
    print(f"refused client-side (never sent)  {len(refused)}")

    if refused:
        print()
        print("Refused by ItemBridge before sending:")
        counts = Counter((c["item_key"], c["refused_locally"]) for c in refused)
        for (item_key, reason), count in counts.most_common(15):
            print(f"  [{count}x] {item_key}: {reason}")

    if rejected:
        print()
        print("REJECTED BY THE SERVER -- these are ItemBridge bugs:")
        for msg, count in Counter(r[2] for r in rejected).most_common():
            example = next(label for label, _, m in rejected if m == msg)
            print()
            print(f"  [{count}x] {msg}")
            print(f"      e.g. {example}")

    if errors:
        print()
        print("Transport errors:")
        for label, err in errors[:8]:
            print(f"  {label}: {err}")

    # A run that validated nothing is a failed run, not a clean one. Reporting
    # success because zero descriptors were rejected, when zero were actually
    # delivered, is exactly the misleading result this harness exists to avoid.
    ok = (
        not rejected
        and not errors
        and accepted > 0
        and accepted == len(sent)
    )
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
