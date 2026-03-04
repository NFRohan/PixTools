# Runbook: Node Scale-Out Failure

Use this when pods stay Pending and workload node count does not increase.

## Trigger

- pods in `pixtools` remain `Pending` with `Insufficient cpu` or `Insufficient memory`
- Cluster Autoscaler does not increase workload ASG desired capacity

## Immediate Checks

```bash
kubectl get nodes -o wide
kubectl -n pixtools get pods
kubectl -n pixtools describe pod <pending-pod-name>
kubectl -n pixtools logs deploy/cluster-autoscaler --tail=200
```

AWS checks:

```bash
aws autoscaling describe-auto-scaling-groups --region us-east-1 --auto-scaling-group-names pixtools-dev-k3s-agent
aws autoscaling describe-scaling-activities --region us-east-1 --auto-scaling-group-name pixtools-dev-k3s-agent
```

## Recovery Steps

1. Verify Cluster Autoscaler pod is `Running` and on infra node.
2. Verify workload ASG still has required autodiscovery tags:
   - `k8s.io/cluster-autoscaler/enabled=true`
   - `k8s.io/cluster-autoscaler/pixtools-dev-k3s=owned`
3. Verify node role IAM still allows autoscaler actions and describe APIs.
4. Check ASG launch failures (capacity unavailable, launch template issue, instance type restriction).
5. If ASG launch is blocked, temporarily raise desired capacity manually with a known-good instance class.

## Rollback / Normalization

- remove temporary manual ASG overrides
- ensure CA regains control
- confirm new node joins K3s and receives required app label

## Post-Incident Notes

Capture:
- failing pod names and reasons
- ASG activity failure messages
- time to first new node Ready
- infra change required (if any)
