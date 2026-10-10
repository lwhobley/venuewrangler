# Business Continuity & Disaster Recovery (BC/DR) Plan

**Document Owner**: Infrastructure Lead  
**Effective Date**: August 2026  
**Review Cycle**: Annual  

---

## 1. Objectives & Metrics

Venue Wrangler is engineered to ensure continuous business operations and rapid recovery in the event of major infrastructure disruptions, cloud provider outages, or catastrophic data corruption.

### Service Recovery Targets
* **Recovery Time Objective (RTO)**: **< 4 hours** (Maximum acceptable duration to restore service following a total region/database failure).
* **Current Recovery Point Objective (RPO)**: **< 24 hours**, based on the nightly verified logical backup. The target becomes **< 1 hour** only after Supabase PITR is enabled and tested.

---

## 2. Infrastructure Architecture & Redundancy

* **API Compute Layer**: Google Cloud Run (`venue-wrangler-api` in `us-east1`) with automated multi-zone container replication, autoscaling (up to 8 instances), and instant zero-downtime revision rollbacks.
* **Database Layer**: Managed PostgreSQL on the Supabase Free plan. Scheduled provider backups and PITR are not currently available; the nightly off-site logical backup is the recovery source.
* **Media & File Storage**: Amazon Web Services (AWS S3) in `us-east-1` with cross-zone durability (99.999999999% durability SLA) and SSE-S3 encryption.
* **DNS & Web Routing**: Cloudflare Anycast edge network with automated SSL and DDoS mitigation.

---

## 3. Database Backup & Recovery Strategy

### 3.1 Point-in-Time Recovery (PITR)
* PITR is a launch prerequisite, not a current control. Upgrade Supabase, enable PITR, and record a restore drill before changing the stated RPO.

### 3.2 Nightly Logical Backups (Cloudflare R2)
* Automated GitHub Action (`.github/workflows/supabase-database-backup.yml`) runs nightly logical dumps (`pg_dump`) of the Supabase database to a dedicated Cloudflare R2 bucket, the only backup destination. R2 encrypts all objects at rest.
* The workflow verifies archive readability and the uploaded object size. Backups expire through a **30-day R2 object lifecycle rule**. Bucket locks are not claimed unless separately enabled and evidenced in Cloudflare.

### 3.3 Backup Restoration Drill Protocol
* **Cadence**: Conducted semi-annually (every 6 months).
* **Procedure**:
  1. Pull latest nightly backup snapshot from R2.
  2. Restore database into an isolated staging Postgres container/cluster.
  3. Execute Prisma schema migration checks and automated integration test suite (`npm run test:integration`).
  4. Record drill timestamp, duration, RTO achievement, and sign-off in SOC 2 evidence logs.

---

## 4. Disaster Recovery Scenarios & Playbooks

### Scenario A: Cloud Run Service Disruption or Bad Release
1. List available immutable revisions:
   ```bash
   gcloud run revisions list --service=venue-wrangler-api --region=us-east1 --project=venuewrangler
   ```
2. Shift 100% of traffic to the last verified revision:
   ```bash
   gcloud run services update-traffic venue-wrangler-api --to-revisions=LAST_KNOWN_GOOD_REV=100 --region=us-east1 --project=venuewrangler
   ```
3. Verify `/api/health` and mobile login flows.

### Scenario B: Primary Database Outage or Data Corruption
1. Pause API traffic or enable maintenance mode.
2. Restore the latest R2 logical backup into an isolated replacement database. Once PITR is enabled and tested, a point-in-time restore may be used instead.
3. Update `DATABASE_URL` in GCP Secret Manager.
4. Deploy a new Cloud Run revision pointing to the restored database.
5. Run Prisma migrations: `npm run prisma:migrate:deploy`.
6. Verify smoke tests and restore public traffic.
