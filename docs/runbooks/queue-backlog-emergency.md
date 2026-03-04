# Runbook: Queue Backlog Emergency

Use this when `default_queue` backlog stays high and job completion latency keeps rising.

## Trigger

- `pixtools_rabbitmq_queue_depth{queue="default_queue"}` stays above threshold for `>=10m`
- worker replicas are already at max or not scaling

## Immediate Checks

```bash
kubectl -n pixtools get scaledobject
kubectl -n pixtools get hpa
kubectl -n pixtools get deploy pixtools-worker-standard -o wide
kubectl -n pixtools get pods -o wide
kubectl -n pixtools logs deploy/pixtools-worker-standard --tail=120
```

## Recovery Steps

1. Confirm RabbitMQ is reachable and healthy.
2. If KEDA is not active but backlog is high, inspect KEDA operator logs and scaler errors.
3. Temporarily increase worker capacity:
   - raise `maxReplicaCount` for `pixtools-worker-standard`
   - or increase worker concurrency carefully if CPU/memory headroom exists
4. If nodes are saturated, verify Cluster Autoscaler and ASG activity.
5. If backlog remains dominated by heavy tasks, reduce heavy-job intake or isolate queue pressure.

## Rollback / Normalization

- revert emergency replica/concurrency overrides after backlog drains
- verify queue returns to baseline
- verify no pods remain Pending

## Post-Incident Notes

Capture:
- backlog peak
- time to drain
- worker max replicas reached
- whether node scale-out happened
- corrective action committed
