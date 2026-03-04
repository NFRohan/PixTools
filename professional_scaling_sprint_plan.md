# Professional Scaling Sprint Plan

This converts `professional_scaling_plan.md` into an execution plan with discrete sprints.

Scope:

- production-grade scaling for the current PixTools architecture
- K3s on EC2
- AWS ASGs for node capacity
- RabbitMQ-driven asynchronous workloads
- benchmark readiness as the end goal

Non-goals for this plan:

- rewriting the platform around EKS
- replacing RabbitMQ
- replacing Celery
- adopting Karpenter in the first implementation pass

## Sprint 0: Baseline Hardening

Duration:

- 2 to 3 days

Objective:

Make the current cluster safe to autoscale by fixing observability, scheduling, and disruption preconditions.

Why this sprint exists:

- autoscaling on top of weak requests/limits and bad scheduling rules creates noisy, misleading results
- benchmark work is pointless if the cluster cannot report why it scaled or failed

Tasks:

1. Verify `metrics-server` is installed and healthy.
2. Confirm `pixtools-api` HPA and `pixtools-worker-standard` HPA both read metrics without errors.
3. Audit requests and limits for:
   - `pixtools-api`
   - `pixtools-worker-standard`
   - `pixtools-worker-ml`
   - `pixtools-beat`
   - `rabbitmq`
   - `redis`
   - `alloy`
4. Add `PriorityClass` resources:
   - `pixtools-infra-critical`
   - `pixtools-app-standard`
   - `pixtools-app-ml`
5. Add PodDisruptionBudgets for:
   - `pixtools-api`
   - `rabbitmq`
   - `redis`
   - keep `rabbitmq` and `redis` non-strict while they are single-replica infra workloads, so infra-node drains are still possible
6. Ensure app nodes join K3s with labels from EC2 user data, not from later reconciliation only.
7. Add topology spread constraints or anti-affinity for the API deployment.
8. Document the current stable worker sizing and why it exists.

Repository changes:

- `k8s/priorityclasses.yaml`
- `k8s/pdb/api-pdb.yaml`
- `k8s/pdb/rabbitmq-pdb.yaml`
- `k8s/pdb/redis-pdb.yaml`
- `k8s/api/deployment.yaml`
- `k8s/workers/worker-standard.yaml`
- `infra/templates/k3s_agent_user_data.sh.tftpl`
- `scripts/deploy/reconcile-cluster.sh`
- `README.md`

Acceptance criteria:

- no HPA reports `FailedGetResourceMetric`
- no critical workload is missing requests/limits
- no rollout can evict RabbitMQ or Redis accidentally, but infra-node maintenance is still possible
- node labels survive instance replacement without manual repair

Exit artifacts:

- healthy `kubectl get hpa`
- clean rollout output from CD
- updated architecture docs

## Sprint 1: Queue-Driven Worker Autoscaling

Duration:

- 2 to 4 days

Objective:

Replace CPU-first worker scaling with queue-driven worker scaling.

Why this sprint exists:

- PixTools is queue-driven, not request-thread-driven
- standard worker scale should follow RabbitMQ backlog on `default_queue`

Tasks:

1. Add KEDA to the cluster.
2. Create the RabbitMQ auth path KEDA will use.
3. Create a `ScaledObject` for `pixtools-worker-standard`.
4. Replace or disable the standard worker HPA after KEDA is validated.
5. Tune the first scaling policy:
   - `minReplicaCount = 1`
   - `maxReplicaCount = 3` or `4`
   - activation threshold around `3-5`
   - first queue target around `8-12` messages per worker replica
6. Add alert conditions for:
   - queue backlog remains above threshold for too long
   - scaler cannot create worker pods
   - worker pods remain `Pending`
7. Keep `pixtools-worker-ml` fixed at one replica for this sprint.

Repository changes:

- `k8s/autoscaling/keda-install.yaml` or Helm install logic
- `k8s/autoscaling/keda-trigger-auth.yaml`
- `k8s/autoscaling/worker-standard-scaledobject.yaml`
- remove or supersede `k8s/workers/worker-standard-hpa.yaml`
- `scripts/deploy/reconcile-cluster.sh`
- `k8s/README.md`

Acceptance criteria:

- pushing backlog into `default_queue` increases standard worker replica count automatically
- worker replica count returns to baseline after backlog drains
- worker scaling is driven by queue pressure, not only CPU noise
- no worker flapping under a small baseline stress test

Exit artifacts:

- `kubectl get scaledobject -n pixtools`
- screenshots or logs showing queue backlog and worker replica growth
- updated runbook notes for expected scaling behavior

## Sprint 2: True Node Autoscaling

Duration:

- 3 to 4 days

Objective:

Enable automatic EC2 workload-node scale-out when pods cannot be scheduled.

Why this sprint exists:

- today, ASG `max > 1` exists, but node count does not increase automatically from in-cluster demand
- this is the main missing piece before claiming true elastic scaling

Tasks:

1. Add Cluster Autoscaler IAM permissions.
2. Tag the workload ASG for Cluster Autoscaler auto-discovery.
3. Deploy Cluster Autoscaler into K3s.
4. Scope Cluster Autoscaler to workload ASGs only.
5. Keep the infra ASG fixed and unmanaged.
6. Tune scale-down conservatively for the first pass.
7. Verify new workload nodes:
   - join the cluster correctly
   - carry the required app labels immediately
   - accept app workloads without manual intervention

Repository changes:

- `infra/compute.tf`
- `infra/iam.tf` or `infra/iam_cluster_autoscaler.tf`
- `infra/variables.tf`
- `infra/outputs.tf`
- `infra/dev.tfvars`
- `k8s/autoscaling/cluster-autoscaler.yaml`
- `scripts/deploy/reconcile-cluster.sh`

Suggested first config:

- workload ASG:
  - `min = 1`
  - `desired = 1`
  - `max = 4`

Acceptance criteria:

- unschedulable standard worker pods trigger new workload-node provisioning
- new nodes join K3s and become schedulable without manual fixes
- extra workload nodes scale back down after idle time
- infra node remains stable and untouched

Exit artifacts:

- ASG activity history showing scale-out from cluster demand
- `kubectl get nodes -w` capture during a scale event
- benchmark note proving node count increased automatically

## Sprint 3: Capacity-Class Separation

Duration:

- 2 to 3 days

Objective:

Make scheduling deterministic across infra, standard app, and ML workloads.

Why this sprint exists:

- mixed workloads should not compete on the wrong node class
- stateful infra should never drift onto spot nodes

Tasks:

1. Harden infra-node placement for:
   - `rabbitmq`
   - `redis`
   - `pixtools-beat`
   - monitoring components that must survive worker churn
2. Harden app-node placement for:
   - `pixtools-api`
   - `pixtools-worker-standard`
3. Decide whether ML remains on the general workload pool or gets a dedicated node class.
4. If ML gets a dedicated class:
   - add separate node labels
   - add tolerations and affinity to `pixtools-worker-ml`
   - optionally add a dedicated ASG
5. Validate rolling deploy behavior with the new placement rules.

Repository changes:

- `k8s/workers/worker-standard.yaml`
- `k8s/workers/worker-ml.yaml`
- `k8s/workers/beat.yaml`
- `k8s/rabbitmq/statefulset.yaml`
- `k8s/redis/deployment.yaml`
- `k8s/monitoring/*.yaml`
- `infra/templates/k3s_server_user_data.sh.tftpl`
- `infra/templates/k3s_agent_user_data.sh.tftpl`
- optional extra Terraform files if a dedicated ML pool is introduced

Acceptance criteria:

- infra services only land on infra nodes
- standard app workloads only land on workload app nodes
- ML placement is explicit and documented
- no rollout or scale event causes infra services to land on spot capacity

Exit artifacts:

- `kubectl get pods -o wide` showing clean placement by node class
- updated architecture and runbook docs

## Sprint 4: Scaling Safety and Guardrails

Duration:

- 2 to 3 days

Objective:

Turn autoscaling from â€œfunctionally worksâ€ into â€œoperationally safe.â€

Why this sprint exists:

- autoscaling without stabilization and alerts becomes a source of new incidents

Tasks:

1. Add stabilization windows to HPA and KEDA policies where appropriate.
2. Tune deployment strategies so autoscalers and rollouts do not fight each other.
3. Add alerting or at least dashboard panels for:
   - worker replica saturation
   - node saturation
   - sustained queue backlog
   - pods Pending because of CPU or memory
   - failed scale-up events
4. Define benchmark pass/fail thresholds:
   - max acceptable queue drain time
   - max acceptable failed job ratio
   - target p95 API latency band
5. Write runbooks for:
   - queue backlog emergency
   - node scale-out failure
   - worker OOM recurrence
   - spot interruption during active load

Repository changes:

- `k8s/api/hpa.yaml`
- `k8s/autoscaling/*.yaml`
- `bench/README.md`
- `bench/templates/benchmark-report-template.md`
- new runbook markdown under repo root or `docs/`
- `README.md`

Acceptance criteria:

- scale events are visible in telemetry
- sustained overload produces clear alertable signals
- benchmark results can be judged against explicit thresholds

Exit artifacts:

- alert list
- benchmark readiness checklist
- updated operational docs

## Sprint 5: Benchmark Readiness Validation

Duration:

- 2 to 3 days

Objective:

Prove the scaling implementation works before formal benchmark reporting.

Why this sprint exists:

- scaling claims should be verified before they appear in resume bullets or README performance sections

Tasks:

1. Run a controlled baseline load test.
2. Run a short spike test.
3. Validate:
   - API pod scaling
   - standard worker scaling
   - node scaling
   - queue drain behavior
4. Capture:
   - worker replica count over time
   - node count over time
   - queue depth over time
   - failed job count
   - any OOM or Pending events
5. Record findings in benchmark report format.
6. Decide whether ML queue scaling is needed for the next sprint.

Repository touchpoints:

- `bench/run-k6.ps1`
- `bench/collect-grafana-metrics.ps1`
- `bench/results/`
- `bench/templates/benchmark-report-template.md`
- `README.md` if benchmark results are ready to publish

Acceptance criteria:

- baseline run completes without stuck jobs
- spike run demonstrates replica growth
- node scale-out is observed automatically when needed
- system returns close to baseline after load subsides

Exit artifacts:

- `bench/results/*`
- benchmark markdown report
- decision note on next optimization target

## Recommended Order

Execute the sprints in this order:

1. Sprint 0
2. Sprint 1
3. Sprint 2
4. Sprint 3
5. Sprint 4
6. Sprint 5

Do not skip Sprint 2 if the goal is to claim true elastic scaling.

## First Sprint Recommendation

Start with Sprint 0 immediately.

Why:

- it is the lowest-risk work
- it removes ambiguity from later scaling failures
- it gives a clean foundation for KEDA and Cluster Autoscaler

If you want the fastest path to visible payoff, do:

1. finish Sprint 0
2. do Sprint 1
3. run a tiny validation test
4. then do Sprint 2

That sequence gives you real progress without pretending node elasticity already exists.

## Definition of Success

This scaling program is complete when all of the following are true:

1. API pods autoscale from load.
2. standard workers autoscale from RabbitMQ backlog.
3. workload nodes autoscale from unschedulable pods.
4. infra and app workloads are isolated by policy.
5. scale events are observable and alertable.
6. benchmark runs can produce credible scaling claims.

