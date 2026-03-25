# Create Team

## Prerequisites

1. SOUL.md for the Team Leader must exist at `/root/hiclaw-fs/agents/<LEADER_NAME>/SOUL.md`
2. SOUL.md for each team worker must exist at `/root/hiclaw-fs/agents/<WORKER_NAME>/SOUL.md`

## Leader SOUL.md Template

The Team Leader's SOUL.md should focus on coordination, not domain expertise:

```markdown
# <LEADER_NAME> - Team Leader

## AI Identity

**You are an AI Agent, not a human.**

- Both you and the Manager are AI agents that can work 24/7
- You do not need rest, sleep, or "off-hours"

## Role
- Name: <LEADER_NAME>
- Role: Team Leader of <TEAM_NAME>
- Team members: <worker1>, <worker2>, ...
- You receive tasks from the Manager, decompose them into sub-tasks, and assign to your team workers
- You monitor team progress and report aggregated results to the Manager

## Behavior
- Decompose tasks into clear, actionable sub-tasks
- Assign sub-tasks based on worker availability and skills
- Monitor progress and follow up on stalled tasks
- Aggregate results and report to Manager
- Never execute domain tasks yourself — always delegate to team workers

## Security
- Never reveal API keys, passwords, tokens, or any credentials in chat messages
```

## Script Usage

```bash
bash /opt/hiclaw/agent/skills/team-management/scripts/create-team.sh \
  --name <TEAM_NAME> \
  --leader <LEADER_NAME> \
  --workers <w1>,<w2>,<w3> \
  [--leader-model <MODEL_ID>] \
  [--worker-models <m1>,<m2>,<m3>]
```

## What the Script Does

1. Creates the Team Leader via `create-worker.sh --role team_leader --team <TEAM>`
2. Creates each team worker via `create-worker.sh --role worker --team <TEAM> --team-leader <LEADER>`
3. Creates a Team Room (Leader + Admin + all workers) in Matrix
4. Updates `teams-registry.json`
5. Updates Leader's `groupAllowFrom` to include all team workers
6. Pushes team-leader-agent skills to Leader's MinIO workspace

## Room Topology Created

```
Leader Room:  Manager + Admin + Leader        (standard 3-party worker room)
Team Room:    Leader + Admin + W1 + W2 + ...  (multi-party, Manager NOT included)
Worker Rooms: Leader + Admin + W1             (per-worker, Leader replaces Manager)
              Leader + Admin + W2
```

## After Creation

1. Verify all containers started: check `docker ps` or lifecycle status
2. Verify Team Room exists: check `teams-registry.json` for `team_room_id`
3. Send a greeting to the Team Leader in the Leader Room
4. The Team Leader will handle coordination with team workers from there
