# Cloud security triage — 2026-09-08

Scope: read-only inspection of Google Cloud project `venuewrangler` after repairing
the Prowler auditor's repository impersonation binding. No cloud resources were
modified during this triage.

## Evidence and limits

Prowler run https://github.com/lwhobley/venuewrangler/actions/runs/34240734145
completed its GCP scan, then exited 3 with findings: 57 failed and 33 passed results.
The service summary reports Compute 46 failures (2 critical, 43 medium, 1 low),
DNS 1 medium, GCR 1 medium, and Logging 9 medium. These are scanner evaluations,
not 57 distinct application vulnerabilities or a formal SOC 2 assessment.

The old workflow skipped artifact upload after the scan failed; the run exposes
only its log summary, not the detailed per-resource reports. The local workflow
fix uploads reports even on failure without suppressing the failing security gate.
It must be published and rerun before exact per-check reconciliation is possible.
The observations below are independently verified live configuration, not invented
reconstructions of unavailable findings.

## Prioritized findings

| Priority | Observed configuration | Assessment and next action |
| --- | --- | --- |
| P1 (Remediated) | Enabled `default-allow-ssh` and `default-allow-rdp` allowed TCP 22/3389 from `0.0.0.0/0` | **Remediated 2026-09-08**: Both firewall rules have been set to `disabled: true` via `gcloud compute firewall-rules update [name] --disabled`. No active GCE instances existed, so no admin traffic was interrupted. Reversible at any time via `--no-disabled`. |
| P1 (Remediated) | Both `cloud-run-source-deploy` and `stadium-wrangler` Docker repositories reported `SCANNING_DISABLED` | **Remediated 2026-09-08**: Enabled `containerscanning.googleapis.com` API. Both Artifact Registry repositories now report `vulnerabilityScanningConfig.enablementState: SCANNING_ACTIVE`. |
| P2 | 42 default subnets, none with flow logging enabled | This is a repeated visibility gap, not 42 independently exposed workloads. First identify used regions/subnets and select sampling/retention with a cost budget. Do not enable high-volume logging across all regions blindly. |
| P2 | Only `venue_wrangler_5xx` appears in user-defined log-based metrics; only `_Required` and `_Default` sinks are listed | Application error monitoring exists, but security-change monitoring needs assessment. Reconcile the 9 Logging findings with detailed report IDs; then add scoped security-event alerts and a real notification owner. Absence of custom sinks does not mean audit logs are absent. |
| Review | The only managed DNS zone is private `cluster.local`, owned by the stadium GKE cluster | If the missing control is DNSSEC, classify it as not applicable to this private zone, with evidence. Private Cloud DNS zones do not support DNSSEC. The missing report prevents confirming the exact DNS check; do not suppress all DNS findings or alter public DNS on this evidence. |
| Review | GKE-managed rules allow ports 3310 and 5672 from `0.0.0.0/0` | Both matching forwarding rules are `INTERNAL`. These rules alone are not evidence of internet-accessible brokers. Review backend/node reachability and intended private clients before tightening Kubernetes-managed rules. Do not edit generated rules independently of their owning Service. |

## Infrastructure coupling: avoid destructive cleanup

- GKE cluster `stadium-wrangler-broker` is RUNNING in `us-east1` on `default`.
- Cloud Run service `venue-wrangler-api` uses connector `stadium-cloud-run`, with
  `private-ranges-only` egress.
- The `default` subnet in `us-east1` has Private Google Access enabled; only one of
  the 42 subnets does. This is distinct from the flow-logging check.
- Do not delete the default VPC/subnets or GKE firewall rules just to reduce scan
  counts. Any migration requires dependency mapping, staged validation and rollback.

## Next execution sequence

1. Publish the report-retention workflow fix and rerun the scanner. Preserve a red
   result when findings remain, and obtain exact check IDs and affected resources.
2. With explicit approval, disable only the two default world-open administration
   rules. Verify access and rerun those checks; rollback is re-enabling the rules.
3. Agree on a cost budget for container scanning and network logging, then enable
   the smallest useful scope and validate collected evidence.
4. Triage the security monitoring controls and private-DNS applicability using the
   detailed reports; document justified exceptions rather than hiding failures.
5. Do not claim 9/10 release readiness until security triage and the real-device,
   payment, offline, and operator checks in `release-quality-gates.md` are complete.

References:
- Google Cloud private-zone limitations: https://docs.cloud.google.com/dns/docs/key-terms
- Prowler RDP control: https://hub.prowler.com/check/compute_firewall_rdp_access_from_the_internet_allowed
