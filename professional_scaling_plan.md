# Professional-Grade Scaling Plan

This plan upgrades PixTools from a manually tuned demo deployment into a cluster that can scale predictably under load, recover cleanly from burst traffic, and support defensible benchmark results.

It is written against the current repository and deployment model as of March 2026.

## 1. Current State

What exists today:

- Go API pod autoscaling via `k8s/api/hpa.yaml`
- standard worker pod autoscaling via `k8s/workers/worker-standard-hpa.yaml`
- fixed single-replica ML worker
- EC2 Auto Scaling Group capacity range for workload nodes in `infra/compute.tf`
- workload ASG sizing in `infra/dev.tfvars`
- K3s on EC2, not EKS
- RabbitMQ as the async control point

What is still missing for true scaling:

- queue-driven autoscaling for Celery workers
- automatic node provisioning when pods become unschedulable
- capacity-class separation between infra, standard work, and ML work
- disruption controls strong enough for rolling deploys and scale-down events
- scaling SLOs and benchmark gates
- autoscaling driven by business load instead of CPU-only heuristics

## 2. Target End State

Professional-grade scaling for PixTools means all of the following are true:

1. API pods scale from request pressure.
2. standard workers scale from RabbitMQ backlog, not only CPU and memory.
3. ML workers scale by a separate policy or remain intentionally fixed with explicit capacity limits.
4. unschedulable pods trigger new workload EC2 nodes automatically.
5. empty or underutilized nodes are drained and removed automatically.
6. scale-up and scale-down behavior are observable and testable.
7. deployments do not stall because of missing nodes, bad affinities, or stale labels.
8. node classes are explicit:
   - infra node class
   - general app/worker node class
   - optional ML node class

## 3. Recommended Architecture

### 3.1 Pod autoscaling: KEDA for queue consumers

Use KEDA to scale Celery workers from RabbitMQ queue depth.

Why:

- PixTools is queue-driven.
- CPU-based HPA is a weak signal for async workers.
- RabbitMQ backlog is the correct scaling trigger for `default_queue` and later for `ml_inference_queue`.

Recommended workloads:

- `pixtools-worker-standard`
  - KEDA ScaledObject on `default_queue`
- optional later: `pixtools-worker-ml`
  - separate KEDA ScaledObject on `ml_inference_queue`
  - only if memory and model constraints justify >1 replica

The KEDA RabbitMQ scaler supports queue-length-based scaling and is explicitly designed for this model. Source: `https://keda.sh/docs/2.12/scalers/rabbitmq-queue/`

### 3.2 Node autoscaling: Cluster Autoscaler first

Use Cluster Autoscaler against the existing workload Auto Scaling Group.

Why this is the recommended first implementation:

- the current repo already uses AWS ASGs in `infra/compute.tf`
- Cluster Autoscaler is designed for pre-configured node groups
- it is the lower-risk path for this existing architecture
- it fits K3s on EC2 better than forcing a larger node-lifecycle redesign immediately

Kubernetes documents Cluster Autoscaler as the node autoscaler that scales pre-configured node groups. Source: `https://kubernetes.io/docs/concepts/cluster-administration/node-autoscaling/`

Cluster Autoscaler should manage:

- the workload ASG only
- not the infra/control-plane node

Important AWS auto-discovery tags will be required on the workload ASG.

### 3.3 Karpenter: optional phase 2, not phase 1

Karpenter is a valid future path. AWS states Karpenter 1.0 can be used with EKS or any conformant Kubernetes cluster. Source: `https://aws.amazon.com/about-aws/whats-new/2024/08/karpenter-1-0/`

However, for PixTools, Karpenter should be treated as a later optimization, not the first scaling implementation, because:

- the current stack already models node capacity through ASGs
- Cluster Autoscaler is the least disruptive next step
- Karpenter would be a node-lifecycle redesign, not just a scaling enhancement

Recommendation:

- phase 1: Cluster Autoscaler
- phase 2: revisit Karpenter only if you want stronger spot diversification and node consolidation logic later

## 4. Scaling Layers and Ownership

### Layer A: Request-driven HTTP scale

Owner:

- HPA on `pixtools-api`

Signals:

- CPU
- memory
- later: custom request rate or latency if metrics pipeline is hardened

Files:

- `k8s/api/hpa.yaml`
- `k8s/api/deployment.yaml`

### Layer B: Queue-driven worker scale

Owner:

- KEDA ScaledObject on `pixtools-worker-standard`

Signals:

- RabbitMQ `default_queue` backlog
- later: `default_queue` message rate if backlog proves too laggy as a signal

Files to add or change:

- `k8s/autoscaling/` new folder
- `k8s/autoscaling/keda-namespace.yaml` if you want isolation
- `k8s/autoscaling/keda-install.yaml` or Helm-based install logic
- `k8s/autoscaling/worker-standard-scaledobject.yaml`
- `scripts/deploy/reconcile-cluster.sh`
- possibly `k8s/workers/worker-standard.yaml`

### Layer C: Node-driven capacity scale

Owner:

- Cluster Autoscaler deployment in-cluster
- workload ASG in AWS

Signals:

- unschedulable pods
- underutilized nodes

Files to add or change:

- `infra/compute.tf`
- `infra/iam.tf` or dedicated CA IAM file
- `infra/outputs.tf`
- `infra/variables.tf`
- `k8s/autoscaling/cluster-autoscaler.yaml`
- `scripts/deploy/reconcile-cluster.sh`

### Layer D: Capacity-class separation

Owner:

- node labels, taints, and affinity rules

Goal:

- infra services stay on infra node
- general workload runs on workload nodes
- ML workload optionally gets its own node class later

Files to add or change:

- `infra/templates/k3s_server_user_data.sh.tftpl`
- `infra/templates/k3s_agent_user_data.sh.tftpl`
- `k8s/workers/worker-ml.yaml`
- `k8s/workers/worker-standard.yaml`
- `k8s/monitoring/*.yaml`
- `scripts/deploy/reconcile-cluster.sh`

## 5. Implementation Phases

## Phase 0: Preconditions and hardening

Goal:

Make scaling decisions trustworthy before adding more automation.

Tasks:

1. Ensure `metrics-server` is deployed and healthy.
2. Confirm HPA metrics are stable for `pixtools-api` and `pixtools-worker-standard`.
3. Audit every workload for realistic resource requests and limits.
4. Add or validate PodDisruptionBudgets for:
   - `pixtools-api`
   - `rabbitmq`
   - `redis`
   - note: do not use a strict PDB for single-replica `rabbitmq` on the infra node; `minAvailable: 1` or `maxUnavailable: 0` would block node drains and future infra maintenance
5. Add PriorityClasses:
   - infra-critical
   - app-standard
   - app-ml
6. Ensure all app nodes join with the correct labels directly from user data, not post-hoc scripts only.
7. Add topology spread constraints or anti-affinity for the API when more than one workload node exists.

Definition of done:

- no HPA errors from missing metrics
- no critical workload without requests/limits
- no rollout blocked by disruption policy ambiguity

## Phase 1: Queue-driven worker autoscaling with KEDA

Goal:

Scale `pixtools-worker-standard` from actual queue load.

Tasks:

1. Deploy KEDA into the cluster.
2. Create a TriggerAuthentication or direct secret reference for RabbitMQ auth.
3. Replace or supersede the standard worker CPU/memory HPA with a KEDA ScaledObject.
4. Scale policy for `default_queue`:
   - start conservative
   - min replicas: `1`
   - max replicas: `3` or `4`
   - activation threshold > `0`
   - target backlog per pod based on benchmark observations
5. Keep ML worker fixed at `1` initially.
6. Add alerts for:
   - queue backlog sustained above target
   - scaler unable to create replicas
   - worker pods Pending for >2 minutes

Suggested first policy:

- one standard worker pod per ~`8-12` queued messages
- activation threshold around `3-5` messages

Definition of done:

- enqueue load causes worker replica count to increase automatically
- queue depth returns to baseline after load subsides
- worker pods do not flap excessively

## Phase 2: Node autoscaling with Cluster Autoscaler

Goal:

Allow new EC2 workload nodes to appear automatically when pods cannot be scheduled.

Tasks:

1. Tag the workload ASG for Cluster Autoscaler auto-discovery.
2. Create a least-privilege IAM policy for Cluster Autoscaler.
3. Deploy Cluster Autoscaler in-cluster.
4. Scope it only to workload ASGs.
5. Keep infra ASG fixed and unmanaged by CA.
6. Tune scale-down timing conservatively to avoid churn during benchmarks.
7. Confirm new nodes join K3s with the required labels immediately.

Suggested initial workload ASG envelope:

- `min=1`
- `desired=1`
- `max=4`

Definition of done:

- pending standard worker pods trigger workload node scale-out automatically
- underutilized extra workload nodes are drained and removed automatically
- infra node remains untouched

## Phase 3: Explicit node classes and taints

Goal:

Make scheduling deterministic under mixed workloads.

Tasks:

1. Keep the infra node tainted for infra workloads only.
2. Keep standard app nodes tainted/labelled for API and standard workers.
3. Optionally introduce a dedicated ML workload class:
   - separate ASG or separate node group
   - larger memory profile
   - only `pixtools-worker-ml` tolerates it
4. Move RabbitMQ, Redis, Beat, and core monitoring to infra-only placement.
5. Keep Alloy placement intentional so telemetry survives worker churn.

Definition of done:

- no accidental scheduling of RabbitMQ/Redis onto spot workload nodes
- no API starvation due to ML memory pressure
- no worker class ambiguity

## Phase 4: Professional-grade scaling behavior

Goal:

Turn scaling from “it works” into “it behaves safely under stress.”

Tasks:

1. Add scale-up and scale-down stabilization windows.
2. Define max surge and disruption budgets per workload.
3. Add rollout safeguards so deploys do not fight autoscalers.
4. Add alerts for:
   - replica saturation
   - node saturation
   - pod Pending due to insufficient CPU or memory
   - RabbitMQ queue age and backlog
5. Add benchmark guardrails in CI/CD or runbooks:
   - acceptable queue drain time
   - acceptable p95 latency
   - acceptable failed job ratio
6. Add runbooks for:
   - queue backlog emergency
   - stuck Pending pods
   - node scale-out failure
   - spot interruption surge

Definition of done:

- autoscaling events are observable
- scale failures are alertable
- benchmark runs can be interpreted against explicit success thresholds

## 6. Concrete Repository Plan

## 6.1 Terraform changes

Files:

- `infra/compute.tf`
- `infra/variables.tf`
- `infra/outputs.tf`
- `infra/iam.tf`
- `infra/dev.tfvars`

Changes:

1. Add ASG tags required for Cluster Autoscaler auto-discovery.
2. Add IAM permissions for Cluster Autoscaler to inspect and resize workload ASGs.
3. Add variables for:
   - enabling CA
   - CA cluster name
   - workload ASG max size
4. Increase `workload_asg_max` above the current benchmarking ceiling if needed.
5. Emit outputs for autoscaler discovery and validation.

## 6.2 Kubernetes changes

Files to add:

- `k8s/autoscaling/cluster-autoscaler.yaml`
- `k8s/autoscaling/keda-trigger-auth.yaml`
- `k8s/autoscaling/worker-standard-scaledobject.yaml`
- optional later: `k8s/autoscaling/worker-ml-scaledobject.yaml`
- `k8s/pdb/api-pdb.yaml`
- `k8s/pdb/rabbitmq-pdb.yaml`
- `k8s/pdb/redis-pdb.yaml`
- `k8s/priorityclasses.yaml`

Files to modify:

- `k8s/workers/worker-standard.yaml`
- `k8s/workers/worker-ml.yaml`
- `k8s/api/deployment.yaml`
- `k8s/monitoring/*.yaml`
- `scripts/deploy/reconcile-cluster.sh`

## 6.3 Worker policy changes

Standard worker:

- keep low per-pod concurrency
- scale by replica count first
- avoid solving burst traffic by raising concurrency aggressively

ML worker:

- keep fixed initially
- only scale after memory data proves it is safe
- if scaled later, do it on a dedicated node class

## 7. Operational Rules

These rules should govern scaling decisions.

1. Prefer horizontal scaling over raising Celery concurrency.
2. Keep infra stateful services off spot workload nodes.
3. Do not use strict PDBs on single-replica infra stateful services unless you are intentionally accepting manual node maintenance.
4. Scale standard workers from queue backlog, not CPU alone.
5. Do not autoscale ML workers until memory headroom is well understood.
6. Do not benchmark multi-node claims until node autoscaling exists and is proven.
7. Do not treat ASG `max > 1` as real autoscaling without a node autoscaler.

## 8. Benchmark Readiness Gates

Before formal benchmark work begins, these must be true:

1. standard worker replicas increase automatically under queue load
2. pending worker pods can trigger new workload nodes
3. scale-down returns the system to baseline after idle time
4. no jobs get stuck in `PENDING` due to missing capacity
5. no worker pods are repeatedly OOMKilled under baseline stress
6. Grafana Cloud shows queue depth, worker count, pod count, and node count during the run

## 9. Rollout Order

Recommended order of execution:

1. Phase 0 hardening
2. KEDA for `pixtools-worker-standard`
3. Cluster Autoscaler for workload ASG
4. node labels, taints, and disruption policies
5. benchmark validation
6. optional dedicated ML node class
7. optional Karpenter evaluation

## 10. Recommended First Sprint

This is the next concrete sprint, not the whole roadmap.

Sprint goal:

Enable honest queue-driven pod scaling and automatic workload-node scale-out.

Sprint tasks:

1. Add Cluster Autoscaler ASG tags and IAM in Terraform.
2. Deploy Cluster Autoscaler on K3s.
3. Deploy KEDA.
4. Replace standard worker HPA with a KEDA ScaledObject.
5. Add PDBs and PriorityClasses.
6. Validate with a controlled k6 baseline run.
7. Record:
   - queue depth over time
   - worker replica count
   - node count
   - drain time after test stop

Sprint acceptance criteria:

- a queue backlog causes standard worker replicas to increase
- if pods become unschedulable, a new workload node is provisioned automatically
- after the queue drains, excess replicas and nodes are eventually removed
- no manual `kubectl scale` or Terraform apply is required during the test window

## 11. Sources

This plan is informed by current official guidance:

- Kubernetes node autoscaling overview: `https://kubernetes.io/docs/concepts/cluster-administration/node-autoscaling/`
- Kubernetes workload autoscaling overview: `https://kubernetes.io/docs/concepts/workloads/autoscaling/`
- KEDA RabbitMQ scaler: `https://keda.sh/docs/2.12/scalers/rabbitmq-queue/`
- AWS announcement for Karpenter 1.0 support beyond EKS: `https://aws.amazon.com/about-aws/whats-new/2024/08/karpenter-1-0/`

