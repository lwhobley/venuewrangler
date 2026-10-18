# Prowler Compliance & Security Scanning Guide

> **Status (2026-10-17): manual-only, and out of date for the current stack.** The current product runs on Supabase and Cloudflare, not Google Cloud or AWS, so this scan covers infrastructure the product no longer depends on. The weekly schedule was removed and the fallback to the backup job's AWS keys was deleted. Run the workflow by hand only if a GCP/AWS account is back in scope. Cloud-security evidence for the current stack is collected from the Supabase and Cloudflare dashboards and the evidence log in `soc2-controls-matrix.md`. The text below is retained for reference.

## Overview

[Prowler](https://github.com/prowler-cloud/prowler) is an open-source security tool that assesses cloud infrastructure (Google Cloud Platform, AWS, Azure, and Kubernetes) against cybersecurity and compliance frameworks, including **SOC 2**, **CIS Benchmarks**, and **ISO 27001**.

Venue Wrangler uses Prowler as a **zero-cost alternative** to continuous compliance platforms (such as Vanta or Drata) to continuously scan infrastructure, generate compliance scorecards, and provide audit-ready evidence for SOC 2 Type 1 and Type 2 examinations.

---

## 1. Automated GitHub Actions Scanning

The repository includes a manually triggered workflow [`.github/workflows/prowler-compliance.yml`](../../.github/workflows/prowler-compliance.yml) that:
- Runs **on demand only** via `workflow_dispatch` (the former Monday 06:00 UTC schedule was removed).
- Performs read-only scans across GCP (Cloud Run, IAM, KMS, GCS, Cloud Logging) and AWS (S3, IAM).
- Generates interactive **HTML dashboards**, **CSV matrices**, and **JSON-OCSF data**.
- Stores the reports as downloadable GitHub artifacts retained for 90 days.

### Required GitHub Secrets

| Secret Name | Configuration Status | Description |
| :--- | :---: | :--- |
| `GCP_PROJECT_ID` | ✅ Configured | GCP Project ID (`venuewrangler`). |
| `GCP_WORKLOAD_IDENTITY_PROVIDER` | ✅ Configured | Keyless OIDC provider (`projects/922889404273/locations/global/workloadIdentityPools/github-pool/providers/github-provider`). |
| `GCP_SERVICE_ACCOUNT` | ✅ Configured | Dedicated auditor service account (`prowler-auditor@venuewrangler.iam.gserviceaccount.com`). |
| `PROWLER_AWS_ACCESS_KEY_ID` | Optional | AWS Access Key (falls back to `BACKUP_AWS_ACCESS_KEY_ID`). |
| `PROWLER_AWS_SECRET_ACCESS_KEY` | Optional | AWS Secret Key (falls back to `BACKUP_AWS_SECRET_ACCESS_KEY`). |

---

## 2. GCP Infrastructure Architecture (Configured)

The GCP environment is configured using **Workload Identity Federation (WIF)**, eliminating long-lived service account keys in accordance with SOC 2 CC6.1 least-privilege standards:

1. **Service Account**: `prowler-auditor@venuewrangler.iam.gserviceaccount.com`
2. **Assigned Roles**:
   - `roles/viewer`: Broad read-only visibility for infrastructure assets.
   - `roles/iam.securityReviewer`: Read-only access to audit IAM roles and permissions.
3. **Workload Identity Federation**:
   - **Pool**: `projects/922889404273/locations/global/workloadIdentityPools/github-pool`
   - **Provider**: `github-provider` (`https://token.actions.githubusercontent.com`)
   - **Access Restricted To**: `lwhobley/venueflow-app` repository.

---

## 3. Running Prowler Locally

You can run Prowler on your local development machine at any time using Docker or Python.

### Option A: Using Docker (Quickest, No Python Setup Needed)

#### 1. Scan GCP (using local gcloud login):
```bash
# Authenticate gcloud Application Default Credentials
gcloud auth application-default login

# Run Prowler Docker container against GCP with SOC 2 checks
docker run -ti --name prowler \
  --volume "$HOME/.config/gcloud:/root/.config/gcloud:ro" \
  --volume "$(pwd)/prowler_output:/home/prowler/output" \
  prowlercloud/prowler:latest gcp --compliance soc2_gcp -M html,csv
```

#### 2. Scan AWS (using local AWS profile):
```bash
docker run -ti --name prowler \
  --volume "$HOME/.aws:/root/.aws:ro" \
  --volume "$(pwd)/prowler_output:/home/prowler/output" \
  prowlercloud/prowler:latest aws --compliance soc2_aws -M html,csv
```

---

### Option B: Using Python (`pip`)

```bash
# 1. Install Prowler
pip install prowler

# 2. Run GCP SOC 2 Scan
prowler gcp --compliance soc2_gcp -M html,csv --output-directory ./prowler_output

# 3. Run AWS SOC 2 Scan
prowler aws --compliance soc2_aws -M html,csv --output-directory ./prowler_output

# 4. View the report
open prowler_output/*.html   # On macOS
start prowler_output/*.html  # On Windows
```

---

## 4. How to Use Prowler Output for SOC 2 Audits

When conducting a SOC 2 Type 1 or Type 2 audit with a CPA firm:

1. **Download the Artifact**: Go to GitHub **Actions > Continuous Security & Compliance Scan > Latest Run > Artifacts** and download the `prowler-compliance-reports-*.zip`.
2. **Review the Findings**:
   * Open the `.html` report in your browser to review the overall compliance score and summary graphs.
   * Filter by status `FAIL` to see which cloud configurations need attention.
   * Use the **Remediation** column to apply recommended GCP/AWS configuration adjustments.
3. **Submit to Auditor**:
   * The `.html` and `.csv` reports provide timestamped evidence of automated continuous security testing, fulfilling TSC controls **CC7.1**, **CC7.2**, and **CC8.1**.
