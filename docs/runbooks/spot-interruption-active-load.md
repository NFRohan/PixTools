# Runbook: Spot Interruption During Active Load

Use this when app workload nodes receive Spot interruption and active load is in progress.

## Trigger

- AWS Node Termination Handler events appear
- app node disappears or starts draining
- backlog climbs while worker replica availability drops

## Immediate Checks

```bash
kubectl get nodes -o wide
kubectl -n pixtools get pods -o wide
kubectl -n pixtools get events --sort-by=.lastTimestamp | tail -n 80
kubectl -n pixtools logs -l app=aws-node-termination-handler --tail=120
```

AWS checks:

```bash
aws autoscaling describe-scaling-activities --region us-east-1 --auto-scaling-group-name pixtools-dev-k3s-agent
```

## Recovery Steps

1. Verify infra services remain healthy on infra node (`rabbitmq`, `redis`, `beat`).
2. Confirm Cluster Autoscaler detects unschedulable app workloads and scales workload ASG.
3. If scale-out lags, temporarily raise workload ASG desired capacity manually.
4. Monitor KEDA worker scaling and queue backlog while replacement node joins.
5. Restart only degraded app workloads after replacement node is Ready.

## Rollback / Normalization

- return any temporary ASG override to autoscaler-managed baseline
- verify node count and placement policy are back to normal
- confirm queue backlog returns to steady-state

## Post-Incident Notes

Capture:
- interruption timestamp
- affected node(s)
- replacement node ready time
- queue backlog peak during interruption window
- whether autoscaler actions were automatic or manual
