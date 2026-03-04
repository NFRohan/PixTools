# Runbook: Worker OOM Recurrence

Use this when workers restart with `OOMKilled` and jobs stall or fail.

## Trigger

- pod restarts increase on worker deployments
- `kubectl describe pod` shows `Reason: OOMKilled` / exit code `137`

## Immediate Checks

```bash
kubectl -n pixtools get pods -o wide
kubectl -n pixtools describe pod <worker-pod-name>
kubectl -n pixtools logs <worker-pod-name> --previous --tail=120
kubectl -n pixtools top pods
```

## Recovery Steps

1. Lower load pressure immediately:
   - reduce benchmark traffic, or pause heavy job submission
2. Confirm queue isolation is still active (`default_queue` vs `ml_inference_queue`).
3. For standard worker OOM:
   - lower `--concurrency` if CPU/memory contention is high
   - increase memory request/limit in `k8s/workers/worker-standard.yaml`
4. For ML worker OOM:
   - keep `--pool=solo`
   - raise ML memory limit conservatively
5. If node pressure is global, verify autoscaler behavior and provision additional app node capacity.

## Rollback / Normalization

- deploy tuned worker config
- confirm restart count stabilizes
- verify queue drains and new jobs complete

## Post-Incident Notes

Capture:
- which worker class OOMed
- memory usage at failure time
- queue depth at failure time
- final tuned concurrency and limits
