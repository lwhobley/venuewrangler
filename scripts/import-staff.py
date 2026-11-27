#!/usr/bin/env python3
"""Bulk-create staff accounts for one venue from a BrightHR "Employee Contacts" export.

Run by an admin on their own machine. The service-role key and the starting password are
read from the environment / typed at a prompt, never stored in this file or the output.

    pip install openpyxl
    $env:SUPABASE_URL = "https://<ref>.supabase.co"
    $env:SUPABASE_SERVICE_ROLE_KEY = "<service role key>"   # Dashboard > Project Settings > API
    python scripts/import-staff.py Enish_Houston_Employee_Contacts.xlsx `
        --org-id <uuid> --venue-id <uuid> `
        --role someone@example.com=supervisor --exclude other@example.com `
        --dry-run

What it does for each row (column "Email (account)" and "Name"):
- No account yet: creates one with the starting password, email already confirmed, and
  user_metadata.must_change_password = true, so the app makes them pick their own password
  at first sign-in (app/router.dart holds them on /reset-password).
- Account exists: leaves the password alone and only adds the venue membership.
- Adds a membership (default role "staff") for the venue; an existing one is left as is.

Writes a CSV report (name, email, job title, role, result). The report never contains the
password; hand that out separately and ask people to sign in once soon.
"""

from __future__ import annotations

import argparse
import csv
import getpass
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

VENUE_ROLES = {"staff", "supervisor", "venue_manager"}
UUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", re.I)
EMAIL_RE = re.compile(r"^[^\s@]+@[^\s@]+\.[^\s@]+$")


def password_problem(pw: str) -> str | None:
    """The live project's policy: 12+ chars with lower, upper, digit and symbol (stricter than
    supabase/config.toml, which omits the symbol; the app's passwordPolicyProblem matches)."""
    if len(pw) < 12:
        return "use at least 12 characters"
    if not re.search(r"[a-z]", pw):
        return "add a lowercase letter"
    if not re.search(r"[A-Z]", pw):
        return "add an uppercase letter"
    if not re.search(r"[0-9]", pw):
        return "add a number"
    if not re.search(r"[^A-Za-z0-9]", pw):
        return "add a symbol such as ! or #"
    return None


def read_rows(path: str) -> list[dict]:
    import openpyxl

    ws = openpyxl.load_workbook(path, read_only=True, data_only=True).worksheets[0]
    rows = list(ws.iter_rows(values_only=True))
    header = [str(h or "").strip() for h in rows[0]]
    try:
        name_i = header.index("Name")
        email_i = header.index("Email (account)")
    except ValueError:
        sys.exit(f"Expected 'Name' and 'Email (account)' columns, found: {header}")
    title_i = header.index("Job title") if "Job title" in header else None
    out = []
    for r in rows[1:]:
        email = str(r[email_i] or "").strip().lower()
        if not email:
            continue
        out.append(
            {
                "name": str(r[name_i] or "").strip(),
                "email": email,
                "title": str(r[title_i] or "").strip() if title_i is not None else "",
            }
        )
    return out


class Api:
    def __init__(self, url: str, key: str):
        self.url = url.rstrip("/")
        self.key = key

    def call(self, method: str, path: str, body=None, headers=None):
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(self.url + path, data=data, method=method)
        req.add_header("apikey", self.key)
        req.add_header("Authorization", f"Bearer {self.key}")
        req.add_header("Content-Type", "application/json")
        for k, v in (headers or {}).items():
            req.add_header(k, v)
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                raw = resp.read()
                return resp.status, (json.loads(raw) if raw else None)
        except urllib.error.HTTPError as e:
            raw = e.read()
            try:
                return e.code, json.loads(raw)
            except ValueError:
                return e.code, {"message": raw.decode(errors="replace")}

    def all_users(self) -> dict[str, str]:
        """email -> user id for every auth user (paged)."""
        users: dict[str, str] = {}
        page = 1
        while True:
            status, body = self.call("GET", f"/auth/v1/admin/users?page={page}&per_page=1000")
            if status != 200:
                sys.exit(f"Could not list users ({status}): {body}")
            batch = body.get("users", []) if isinstance(body, dict) else body
            for u in batch:
                if u.get("email"):
                    users[u["email"].lower()] = u["id"]
            if len(batch) < 1000:
                return users
            page += 1

    def venue_org(self, venue_id: str) -> str | None:
        q = urllib.parse.urlencode({"id": f"eq.{venue_id}", "select": "organization_id"})
        status, body = self.call("GET", f"/rest/v1/venues?{q}")
        if status in (401, 403):
            sys.exit(f"The service-role key was rejected ({status}). Check you pasted the whole key.")
        if status != 200:
            sys.exit(f"Could not read the venue ({status}): {body}")
        if not body:
            return None
        return body[0]["organization_id"]

    def create_user(self, email: str, password: str, name: str):
        return self.call(
            "POST",
            "/auth/v1/admin/users",
            {
                "email": email,
                "password": password,
                "email_confirm": True,
                "user_metadata": {"display_name": name, "must_change_password": True},
            },
        )

    def add_membership(self, user_id: str, org_id: str, venue_id: str, role: str):
        return self.call(
            "POST",
            "/rest/v1/memberships?on_conflict=user_id,organization_id,venue_id",
            {"user_id": user_id, "organization_id": org_id, "venue_id": venue_id, "role": role},
            {"Prefer": "resolution=ignore-duplicates,return=representation"},
        )


def parse_pairs(values: list[str]) -> dict[str, str]:
    out = {}
    for v in values:
        email, _, role = v.partition("=")
        email, role = email.strip().lower(), role.strip()
        if not EMAIL_RE.match(email) or role not in VENUE_ROLES:
            sys.exit(f"--role expects email=staff|supervisor|venue_manager, got {v!r}")
        out[email] = role
    return out


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("xlsx")
    ap.add_argument("--org-id", required=True)
    ap.add_argument("--venue-id", required=True)
    ap.add_argument("--role", action="append", default=[], help="email=role override (repeatable)")
    ap.add_argument("--exclude", action="append", default=[], help="email to skip (repeatable)")
    ap.add_argument("--out", default="staff-import-report.csv")
    ap.add_argument("--dry-run", action="store_true", help="show the plan; change nothing")
    args = ap.parse_args()

    for label, value in (("--org-id", args.org_id), ("--venue-id", args.venue_id)):
        if not UUID_RE.match(value):
            sys.exit(f"{label} must be a UUID")
    url = os.environ.get("SUPABASE_URL", "")
    if not url.startswith("https://"):
        sys.exit("Set SUPABASE_URL (https://...) first.")
    key = os.environ.get("SUPABASE_SERVICE_ROLE_KEY", "")
    if not key:
        # Typed at a hidden prompt so it never lands in shell history or a file.
        key = getpass.getpass("Supabase service-role key (Dashboard > Project Settings > API): ").strip()
    if not key:
        sys.exit("No service-role key given.")

    roles = parse_pairs(args.role)
    excluded = {e.strip().lower() for e in args.exclude}
    rows = read_rows(args.xlsx)
    unknown = (set(roles) | excluded) - {r["email"] for r in rows}
    if unknown:
        sys.exit(f"Not in the sheet: {', '.join(sorted(unknown))}")

    api = Api(url, key)
    if api.venue_org(args.venue_id) != args.org_id:
        sys.exit("That venue does not belong to that organization.")
    existing = api.all_users()

    plan = []
    for r in rows:
        if r["email"] in excluded:
            plan.append({**r, "role": "", "action": "skip (excluded)"})
            continue
        if not EMAIL_RE.match(r["email"]):
            plan.append({**r, "role": "", "action": "skip (bad email)"})
            continue
        role = roles.get(r["email"], "staff")
        action = "add membership (account exists)" if r["email"] in existing else "create account"
        plan.append({**r, "role": role, "action": action})

    creating = sum(p["action"] == "create account" for p in plan)
    print(f"{len(plan)} rows: {creating} new accounts, "
          f"{sum(p['action'].startswith('add') for p in plan)} existing, "
          f"{sum(p['action'].startswith('skip') for p in plan)} skipped")
    for p in plan:
        print(f"  {p['action']:<32} {p['role']:<14} {p['name']} <{p['email']}>")
    if args.dry_run:
        print("Dry run: nothing changed.")
        return

    password = ""
    if creating:
        while True:
            password = getpass.getpass("Starting password for new accounts: ")
            problem = password_problem(password)
            if problem:
                print(f"  Rejected: {problem}.")
                continue
            if getpass.getpass("Type it again: ") != password:
                print("  They don't match.")
                continue
            break
    if input(f"Apply to the live project? Type YES: ") != "YES":
        sys.exit("Cancelled.")

    report = []
    for p in plan:
        result = p["action"]
        if p["action"] == "create account":
            status, body = api.create_user(p["email"], password, p["name"])
            if status not in (200, 201):
                msg = (body or {}).get("msg") or (body or {}).get("message") or body
                report.append({**p, "result": f"FAILED creating account ({status}): {msg}"})
                continue
            existing[p["email"]] = body["id"]
            result = "account created"
        if p["action"].startswith("skip"):
            report.append({**p, "result": result})
            continue
        status, body = api.add_membership(existing[p["email"]], args.org_id, args.venue_id, p["role"])
        if status not in (200, 201):
            report.append({**p, "result": f"{result}; FAILED adding membership ({status}): {body}"})
        elif not body:
            report.append({**p, "result": f"{result}; already a member (unchanged)"})
        else:
            report.append({**p, "result": f"{result}; added as {p['role']}"})

    with open(args.out, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=["name", "email", "title", "role", "result"])
        w.writeheader()
        for r in report:
            w.writerow({k: r.get(k, "") for k in w.fieldnames})
    failed = sum("FAILED" in r["result"] for r in report)
    print(f"Done. {len(report) - failed} ok, {failed} failed. Report: {args.out}")


if __name__ == "__main__":
    main()
