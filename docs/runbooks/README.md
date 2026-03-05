# Scaling Incident Runbooks

Use these runbooks when scaling guardrails fail:

- `queue-backlog-emergency.md`
- `node-scaleout-failure.md`
- `worker-oom-recurrence.md`
- `spot-interruption-active-load.md`

Execution rule:
- stabilize production first
- record timeline and commands used
- then update `engineering_story.md` with root cause and corrective action
