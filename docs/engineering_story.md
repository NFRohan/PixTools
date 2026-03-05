# PixTools Engineering Story

This is the living build log for PixTools.

It is not a marketing document. It exists to capture:

- what changed
- why it changed
- what broke
- how it was fixed
- what evidence we have
- what is still unresolved

The goal is to preserve the real engineering narrative while the system evolves, so README and resume bullets can be backed by concrete implementation history.

## Current Snapshot

As of 2026-03-05, PixTools is running as:

- Go API edge
- Python Celery worker runtime
- RabbitMQ broker
- Redis idempotency/cache
- PostgreSQL on RDS
- S3 object storage
- K3s on EC2
- Grafana Cloud via Alloy
- queue-driven worker autoscaling with KEDA
- workload-node autoscaling with Cluster Autoscaler
- infra node baseline on `m7i-flex.large`
- RabbitMQ state on EBS-backed `gp3` PVC

Important current scaling reality:

- pod-level autoscaling exists for:
  - `pixtools-api` via HPA
  - `pixtools-worker-standard` via KEDA on RabbitMQ queue depth
- node-level autoscaling now exists for workload nodes via Cluster Autoscaler
- scale-out has been live-validated from an unschedulable probe pod through AWS ASG growth and new K3s node registration
- scale-down behavior has not yet been fully validated over a longer idle window
- infra-node server rotation has been executed and validated on the current baseline instance class

## Why This Document Exists

PixTools stopped being a simple CRUD-style project once the system had:

- a Go-to-Python handoff
- Celery contract compatibility constraints
- managed AWS stateful services
- self-hosted compute
- live deployment and rollout failures
- scaling behavior that needed to be proven, not assumed

At that point, the interesting part of the project became the engineering decisions and the recovery work, not just the final architecture diagram.

## Core Engineering Story

### 1. Start With a Distributed Python System

The original system used a Python API layer and Python workers.

That gave fast initial delivery because:

- request validation
- Celery orchestration
- image processing
- ML placeholders
- operational logic

could all be built in one language.

The cost was that the HTTP edge was carrying more runtime weight than it needed.

### 2. Migrate Only the HTTP Edge to Go

The API edge was migrated to Go while keeping the Python Celery runtime.

That split was intentional.

Go now owns:

- static frontend delivery
- `/api/process`
- `/api/jobs/:id`
- idempotency lookup
- S3 raw upload
- initial Postgres job row creation
- RabbitMQ publish for Celery-compatible tasks

Python still owns:

- Celery task execution
- DAG expansion
- image operations
- ML work
- metadata generation
- archive creation
- final job status updates

This kept the migration narrow. The goal was not "rewrite everything in Go." The goal was to reduce edge overhead without throwing away the worker system that already solved the harder asynchronous problems.

### 3. The Hard Part Was Contract Parity, Not the Rewrite

The first Go migration attempt broke real behavior because the old Python API was doing more implicit work than it looked like from the outside.

The main failure categories were:

- schema drift against the Alembic-managed `jobs` table
- dropped backend validation rules
- incorrect queue publishing behavior when trying to use `gocelery`
- missing request metadata propagation into worker tasks
- Go API and Python worker contract mismatches
- missing Celery task registration for the Go-published router task

The right fix was to treat the migration as a compatibility exercise.

That led to these decisions:

- Alembic remains the schema authority
- Go model must match the existing `jobs` table contract
- Go publishes Celery-compatible AMQP envelopes directly
- Python workers remain the orchestration authority
- new compatibility glue is allowed where it preserves a stable system boundary

### 4. Direct AMQP Publishing Replaced `gocelery`

`gocelery` was not safe for this deployment shape because it did not target the queue topology the live workers actually consumed.

That bug mattered because:

- the API could accept jobs
- publish to the wrong place
- and leave rows stuck in Postgres with no worker ever picking them up

The fix was to replace the abstraction and publish Celery-compatible AMQP messages directly to the expected queue.

That restored a clean contract:

- Go publishes a router task
- Python receives the router task
- Python expands that into the real pipeline

This Go-to-Python Celery handoff is the most technically distinctive part of the project.

### 5. Worker Registration and Runtime Failures Were Real

The first live deploy after the Go handoff exposed that successful publish is not enough.

One critical runtime bug:

- Go published `app.tasks.router.start_pipeline`
- the worker bootstrap did not import `app.tasks.router`
- Celery never registered the task
- result: jobs were accepted but remained stuck

That was fixed by explicitly registering the router task in worker bootstrap.

Another class of live issues came from worker resource pressure:

- the standard worker pod was OOM-killed
- jobs looked stuck even though the request path was fine
- reducing concurrency and increasing worker memory stabilized the pod

This is important because it shows the bottleneck moved from correctness to capacity, which is what should happen once the integration layer is fixed.

### 6. Deployment Hardening Became Necessary

Real deployment work exposed problems that local correctness would never surface:

- stale Kubernetes node objects after instance churn
- pods stuck `Terminating` on dead nodes
- rollout deadlocks caused by `Recreate` strategy
- SSM-based reconciliation edge cases

Those were fixed by:

- cleaning stale node objects during reconciliation
- force-deleting already-terminating pods before rollout
- switching worker deployments to `RollingUpdate`
- making the reconcile flow more deterministic

The result is a deployment path that is much less dependent on manual cluster cleanup.

### 7. Pod-Level Scaling Is Now Real

The system now has two different autoscaling modes:

- API scales from CPU and memory signals
- standard worker scales from RabbitMQ backlog via KEDA

That is the correct direction for this architecture.

PixTools is queue-driven. Worker scaling should respond to queue depth, not just CPU noise.

The first live bounded stress run confirmed:

- `pixtools-worker-standard` scaled from `1 -> 2 -> 3`
- KEDA moved from `ACTIVE=False` to `ACTIVE=True`
- the API also scaled from `1 -> 3`
- no request failures occurred in that run

That is the first real evidence that scaling is functioning as designed.

### 8. True Node Scale-Out Required Terraform, RBAC, and Recovery Work

Adding Cluster Autoscaler was not just a Kubernetes manifest task.

The controller needed three layers to line up:

- AWS ASG autodiscovery tags
- IAM permissions for scaling and read APIs
- in-cluster RBAC for the resources Cluster Autoscaler inspects

The first live pass exposed that deploying only the Kubernetes side was not enough. Cluster Autoscaler came up, but could not discover the workload ASG and still lacked read permissions for some resources.

That was fixed by:

- applying Terraform changes for workload ASG autodiscovery tags
- adding the required IAM permissions
- completing RBAC for:
  - `jobs.batch`
  - `volumeattachments.storage.k8s.io`
  - `configmaps` in `kube-system`

After that, a controlled unschedulable probe workload proved the full scale-out path:

- scheduler marked the probe pod `Pending`
- Cluster Autoscaler increased workload ASG desired capacity from `1 -> 2`
- AWS launched a new workload EC2 instance
- the new agent joined K3s and became `Ready`

That is the first point where PixTools could honestly claim elastic node growth instead of just pod churn within a fixed cluster.

### 9. Reconciliation Had to Become Resilient to Control-Plane and Helm Failure Modes

Live autoscaling work exposed two operational realities:

- the K3s API on the infra node can briefly flap during disruptive events
- Helm releases can remain stuck in `pending-upgrade` and poison later deploys

Those are not design-diagram problems. They are the kind of problems that make a seemingly correct system fail in CI/CD.

The reconciliation path was hardened to handle that:

- wait for the K3s API before applying manifests
- retry `kubectl apply` instead of failing on a brief API restart
- retry KEDA Helm upgrades when the release is busy
- detect stale pending Helm states and roll back to the last stable revision before retrying

One live KEDA release had to be manually recovered during this work:

- a revision was left in `pending-upgrade`
- the release was rolled back to the last stable deployed revision
- reconciliation logic was then updated so future deploys can recover automatically

This work is less glamorous than the Go migration, but it matters just as much. A system that scales but cannot deploy cleanly is still operationally weak.

### 10. Capacity-Class Separation Is Now Explicit

Once pod and node autoscaling both existed, the next problem was making placement policy deterministic.

Sprint 3 did not introduce a new ML node pool yet. Instead, it made the current intent explicit:

- infra-critical services stay on infra nodes
- standard app services stay on app nodes
- ML stays on the general app pool for now

That decision was backed by policy changes, not just documentation:

- `celery-exporter` is now treated as infra-critical
- standard workers prefer to spread across app nodes
- standard and ML workers both prefer not to co-locate when spare app capacity exists
- the shared-pool ML choice is written down explicitly so future changes can be justified against a known baseline

That keeps the current architecture simple while making future dedicated-ML capacity a deliberate tradeoff instead of an accidental omission.

## Timeline

## 2026-03-04

### Established a living engineering narrative

Created this document so future work can be appended instead of reconstructed from memory later.

### Validated queue-driven worker scaling in the live cluster

Bounded smoke test:

- scenario: `spike`
- VUs: `12`
- duration: `2m`

Observed:

- `2195` accepted requests from the local run
- `0.00%` request failure rate
- KEDA worker scale-up `1 -> 2 -> 3`
- API HPA scale-up `1 -> 3`

Artifacts:

- `bench/results/small-stress-20260304-140230/report.md`

### Measured cross-region latency tax

A temporary `t3.micro` runner was launched in `us-east-1` to compare in-region timings against Bangladesh-run client timings.

Observed:

- local `/api/health` floor: about `549ms` to `595ms`
- in-region `/api/health` floor: about `27ms` to `76ms`
- local spike run:
  - avg `656.86ms`
  - p95 `1201.66ms`
- in-region spike run:
  - avg `321.64ms`
  - p95 `668.95ms`

Conclusion:

- a large fraction of local `k6` latency is cross-region network cost
- client-observed latency from Bangladesh should not be treated as pure backend processing time

Artifacts:

- `bench/results/us-east-1-latency-comparison-20260304.md`

### Implemented and validated workload-node autoscaling

Cluster Autoscaler was added as the node autoscaling layer for workload capacity only.

That work required:

- Terraform changes for workload ASG autodiscovery tags
- Terraform/IAM changes for autoscaler AWS permissions
- in-cluster RBAC fixes for resource inspection

Validation was done with a controlled unschedulable probe deployment.

Observed:

- probe pod went `Pending` due to real CPU and memory pressure
- workload ASG desired capacity increased from `1 -> 2`
- AWS launched a new app instance
- the new K3s agent joined the cluster and became `Ready`

Conclusion:

- PixTools now has real workload-node scale-out, not just pod rescheduling within fixed node count

### Hardened reconciliation against K3s API and Helm lock failures

The autoscaling work exposed deploy-path failures that had to be fixed before the cluster could be treated as stable:

- K3s API readiness gaps during reconciliation
- KEDA Helm release stuck in `pending-upgrade`

Observed:

- repeated deploy failures while Helm reported `another operation (install/upgrade/rollback) is in progress`
- one live KEDA release needed manual rollback to recover a stuck revision

Fixes:

- API readiness gating before and after disruptive steps
- retry wrapper around `kubectl apply`
- KEDA Helm retry logic
- KEDA Helm rollback logic to the last stable revision when the release is stuck pending

Conclusion:

- deploy resilience had to be improved before the new autoscaling layers were operationally usable

### Established explicit capacity classes

Sprint 3 made the scheduling policy explicit:

- infra-critical workloads stay on infra nodes
- standard app workloads stay on app nodes
- ML remains on the shared app node pool for now

Observed changes:

- `celery-exporter` moved under infra-critical priority treatment
- standard workers now prefer node spread and avoid ML co-location when possible
- ML workers also prefer to avoid standard workers when spare capacity exists

Conclusion:

- scheduling intent is now written down and encoded in manifests instead of being partially implicit

## 2026-03-05

### Completed infra server rotation to a stronger baseline instance

The original hardening plan targeted `t3.medium`, but this AWS account rejected that class for launch in this environment.

Observed:

- server ASG repeatedly failed launch attempts with free-tier eligibility errors for `t3.medium`
- the cluster had to be recovered by reverting to a launchable class first

Resolution:

- switched the server baseline to `m7i-flex.large`
- executed a coordinated server+agent rotation sequence
- revalidated cluster health on the new server and agent instances

Outcome:

- control plane now runs on the intended stronger baseline class
- rotation runbook proved workable with current SSM/ASG orchestration

### Converted RabbitMQ storage from node-local path to EBS `gp3`

Why this work was necessary:

- RabbitMQ on `local-path` was coupled to the infra node
- infra-node replacement could strand the broker volume and make rotations disruptive

What changed:

- installed AWS EBS CSI driver
- added `gp3` StorageClass
- moved RabbitMQ StatefulSet PVC target to `gp3`
- introduced explicit migration path outside normal CD flow

### Resolved a migration outage caused by IAM and StatefulSet immutability

Two independent failure modes happened during migration:

1. CD attempted to patch StatefulSet `volumeClaimTemplates` in place and failed on Kubernetes immutability.
2. EBS CSI controller could not create volumes due to `ec2:CreateVolume` authorization failures.

Resolutions:

- reconciliation was updated to skip immutable RabbitMQ storage-class changes during routine deploys and require explicit maintenance migration
- node IAM was updated with explicit EC2 EBS permissions in the inline policy
- EBS CSI controller was restarted after IAM change so new credentials were used
- RabbitMQ PVC was reprovisioned and bound on `gp3`, and broker pod returned to `Running`

Outcome:

- RabbitMQ storage is now decoupled from infra-node local disk
- future infra rotations are materially safer
- migration path is explicit and recoverable

### Post-migration service recovery

During broker downtime, API startup failed because RabbitMQ dial happens at API boot.

Observed:

- API pod entered `CrashLoopBackOff` with `failed to dial rabbitmq`

Resolution:

- restarted `pixtools-api` deployment after broker recovery

Outcome:

- API, workers, autoscalers, and broker all returned to healthy running state

### Built a formal in-region production performance suite

Ad-hoc stress runs were replaced with a repeatable in-region test pipeline:

- temporary EC2 load-generator in `us-east-1`
- orchestrated scenario matrix (`baseline`, `spike`, `retry_storm`, `starvation_mix`)
- pre/post cluster snapshots
- post-run runtime log collection (`api`, workers, RabbitMQ, Cluster Autoscaler, KEDA)
- structured summary JSON + markdown report generation

Primary run snapshot (`2026-03-04 UTC`, `dev`):

- baseline (`30 VUs`, `10m`): `3779` submitted, `0%` HTTP fail, p95 `651.65ms`
- spike (`120 VUs`, `5m`): `6119` submitted, `3.65%` HTTP fail, p95 `8538.94ms`
- retry storm (`60 VUs`, `5m`): `6461` submitted, `0.22%` HTTP fail, p95 `3618.04ms`
- starvation mix (`8m`, heavy `8 rps`, light `4 rps`): `1.33%` HTTP fail, light p95 `5469.43ms`

Failure classification from this run:

- observed: `500` and transport-level `0` errors
- not observed: `409`, `429`, `502`, `503`, `504`

Outcome:

- we now have a defensible benchmark baseline with raw artifacts, not just one-off load screenshots
- scaling bottlenecks are now quantified instead of inferred

### Closed KEDA metrics auth and API scrape parity gaps

Two observability/control-plane issues were fixed as part of performance hardening:

1. Go API now exposes `/metrics`, so scrape traffic no longer gets 404 from the API edge.
2. KEDA metrics adapter RBAC prerequisites are explicitly applied before KEDA Helm install:
   - `tokenreviews` + `subjectaccessreviews` delegation
   - `extension-apiserver-authentication-reader` binding in `kube-system`

Implementation notes:

- added `k8s/autoscaling/keda-metrics-rbac.yaml`
- reconcile now applies that RBAC file before KEDA install/upgrade
- added `scripts/deploy/ssm-keda-rbac-check.ps1` for remote fix + verification

Verification:

- remote `kubectl auth can-i` checks for `keda:keda-metrics-server` returned `yes` for all required verbs/resources
- metrics-apiserver deployment remained healthy after RBAC application

## Hard Problems and Resolutions

### Problem: Go API accepted jobs that workers never executed

Why it happened:

- task publish path and worker task registration were not aligned

Resolution:

- direct Celery-compatible AMQP publish
- explicit router task registration in worker bootstrap

### Problem: migration introduced schema drift

Why it happened:

- Go ORM model diverged from the Alembic-managed Python schema

Resolution:

- Alembic kept as schema authority
- Go model aligned to live schema contract

### Problem: rollout deadlocks after node churn

Why it happened:

- dead nodes remained in cluster state
- `Recreate` strategy blocked new worker pods

Resolution:

- stale node cleanup in reconciliation
- force prune of stuck terminating pods
- move worker deployments to `RollingUpdate`

### Problem: standard worker died under real load

Why it happened:

- concurrency and memory limits were too aggressive for the actual workload shape

Resolution:

- lower standard worker concurrency
- increase worker memory request and limit

### Problem: Cluster Autoscaler was deployed but could not act

Why it happened:

- the Kubernetes deployment existed before the AWS and RBAC prerequisites were fully aligned
- the workload ASG was not yet discoverable
- in-cluster permissions were missing for some inspected resources

Resolution:

- apply Terraform changes for ASG tags and IAM permissions
- add RBAC for:
  - `jobs.batch`
  - `volumeattachments.storage.k8s.io`
  - `configmaps` in `kube-system`
- validate with a controlled pending-pod scale-out probe

### Problem: KEDA Helm release got stuck in `pending-upgrade`

Why it happened:

- overlapping or interrupted Helm activity during SSM-driven reconciliation left the release locked

Resolution:

- add Helm busy-release retry logic
- add recovery logic that rolls back to the last stable revision
- manually recover the live stuck release once, then codify the recovery path in reconciliation

### Problem: RabbitMQ StatefulSet storage change broke CD

Why it happened:

- Kubernetes does not allow in-place mutation of StatefulSet `volumeClaimTemplates`

Resolution:

- changed reconciliation to detect storage-class drift on RabbitMQ StatefulSet and skip apply in normal CD
- required one-time explicit maintenance migration for PVC class cutover

### Problem: EBS CSI still got `ec2:CreateVolume` denied after policy attachment

Why it happened:

- managed CSI policy conditions were not sufficient for this self-managed runtime path at migration time

Resolution:

- added explicit EC2 EBS actions (`CreateVolume`, `AttachVolume`, `DeleteVolume`, `CreateTags`, related describe actions) in the node inline policy
- restarted CSI controller to pick up fresh credentials
- reprovisioned RabbitMQ PVC

### Problem: KEDA metrics API emitted auth/RBAC errors during benchmark windows

Why it happened:

- metrics-apiserver permissions were not consistently established before/after KEDA upgrade paths
- the adapter needed explicit delegated auth review permissions and configmap reader access

Resolution:

- added dedicated RBAC manifest for the metrics adapter
- applied RBAC as a prereq step in reconciliation before KEDA Helm install/upgrade
- added SSM-driven auth verification helper and validated required `can-i` checks remotely

Outcome:

- KEDA metrics auth path is now explicit, versioned, and deploy-order-safe

## Evidence We Have

Current evidence worth citing:

- live deployment is green
- single-op and multi-op jobs both work
- all operations work in single and multi-op modes
- standard worker scales from RabbitMQ backlog through KEDA
- workload ASG scales out from in-cluster unschedulable demand through Cluster Autoscaler
- API scales under burst traffic
- in-region latency is materially lower than Bangladesh-run latency

Evidence artifacts:

- `system_workflow.md`
- `predeploy_blockers.md`
- `professional_scaling_plan.md`
- `professional_scaling_sprint_plan.md`
- `bench/results/small-stress-20260304-140230/report.md`
- `bench/results/us-east-1-latency-comparison-20260304.md`
- `bench/run-production-performance-suite.ps1`
- `bench/collect-prod-run-logs.ps1`
- `bench/results/prod-perf-suite-20260305-041336/production-performance-summary.json`
- `bench/results/prod-perf-suite-20260305-041336/production-performance-report.md`
- `bench/results/prod-perf-suite-20260305-041336/performance-engineering-report.md`

## Known Limits

These are still true:

- formal in-region benchmark evidence now exists, but aggressive burst profiles still fail target reliability/latency envelopes
- node scale-down behavior has not yet been fully validated over a longer cooldown window
- control-plane behavior under repeated disruptive maintenance still needs continued observation
- ML does not have a dedicated node class yet
- API and worker scale ceilings (`max=3`) are still a hard bottleneck under high fan-in
- heavy/light mix performance remains coupled under sustained denoise pressure

## Next Engineering Steps

1. Raise and retune API/worker scaling ceilings, then rerun the production suite and compare error/latency deltas.
2. Validate Cluster Autoscaler scale-down over a real idle window with artifact capture.
3. Add explicit load-shedding/backpressure behavior so overload fails predictably (instead of late `500`/transport timeout noise).
4. Run denoise-heavy focused tests to decide whether ML needs a dedicated node class/ASG.
5. Keep benchmark reports as a release gate and track regression against the current in-region baseline.

## Update Rules

When adding to this document, prefer:

- date-stamped entries
- concrete changes
- concrete failures
- concrete fixes
- links to artifacts

Avoid:

- vague status updates
- unsupported claims
- retrospective rewriting that hides what actually broke
