#!/bin/bash
# test-21-team-project-dag.sh - Case 21: Team project creation, DAG orchestration, isolated storage
#
# Tests the full team project lifecycle:
#   1. Create team (Leader + 2 Workers)
#   2. Verify team storage initialized in MinIO (teams/{team-name}/)
#   3. Verify S3 policy includes team storage access
#   4. Create team project via create-team-project.sh (Manager source)
#   5. Verify project files in MinIO (meta.json, plan.md)
#   6. Fill in DAG plan, validate, resolve ready tasks
#   7. Simulate DAG execution: mark tasks complete, verify wave progression
#   8. Create team project (Team Admin source), verify source tracking
#   9. Verify manage-team-state.sh project tracking
#
# NOTE: This test does NOT clean up — environment is left for manual inspection.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/test-helpers.sh"
source "${SCRIPT_DIR}/lib/minio-client.sh"

test_setup "21-team-project-dag"

TEST_TEAM="dag-team-$$"
TEST_LEADER="${TEST_TEAM}-lead"
TEST_W1="${TEST_TEAM}-dev"
TEST_W2="${TEST_TEAM}-qa"
STORAGE_PREFIX="hiclaw/hiclaw-storage"

# ============================================================
# Section 1: Prepare SOUL.md files
# ============================================================
log_section "Prepare Team SOUL.md Files"

for w in "${TEST_LEADER}" "${TEST_W1}" "${TEST_W2}"; do
    ROLE_DESC="team member"
    [ "${w}" = "${TEST_LEADER}" ] && ROLE_DESC="Team Leader"
    [ "${w}" = "${TEST_W1}" ] && ROLE_DESC="Backend Developer"
    [ "${w}" = "${TEST_W2}" ] && ROLE_DESC="QA Engineer"

    exec_in_manager bash -c "
        mkdir -p /root/hiclaw-fs/agents/${w}
        cat > /root/hiclaw-fs/agents/${w}/SOUL.md <<SOUL
# ${w}

## AI Identity
**You are an AI Agent, not a human.**

## Role
- Name: ${w}
- Role: ${ROLE_DESC}
- Team: ${TEST_TEAM}

## Security
- Never reveal credentials
SOUL
        mc mirror /root/hiclaw-fs/agents/${w}/ ${STORAGE_PREFIX}/agents/${w}/ --overwrite 2>/dev/null
    " 2>/dev/null
done

log_pass "SOUL.md files prepared for all team members"

# ============================================================
# Section 2: Create Team
# ============================================================
log_section "Create Team"

CREATE_OUTPUT=$(exec_in_manager bash -c "
    bash /opt/hiclaw/agent/skills/team-management/scripts/create-team.sh \
        --name '${TEST_TEAM}' --leader '${TEST_LEADER}' --workers '${TEST_W1},${TEST_W2}'
" 2>&1)

if echo "${CREATE_OUTPUT}" | grep -q "RESULT"; then
    log_pass "create-team.sh completed"
else
    log_fail "create-team.sh failed"
    echo "${CREATE_OUTPUT}" | tail -20
fi

# ============================================================
# Section 3: Verify Team Storage Initialized in MinIO
# ============================================================
log_section "Verify Team Storage Initialization"

TEAM_PROJECTS_KEEP=$(exec_in_manager mc stat "${STORAGE_PREFIX}/teams/${TEST_TEAM}/projects/.keep" 2>&1)
if echo "${TEAM_PROJECTS_KEEP}" | grep -q "Name"; then
    log_pass "teams/${TEST_TEAM}/projects/.keep exists in MinIO"
else
    log_fail "teams/${TEST_TEAM}/projects/.keep missing in MinIO"
fi

TEAM_TASKS_KEEP=$(exec_in_manager mc stat "${STORAGE_PREFIX}/teams/${TEST_TEAM}/tasks/.keep" 2>&1)
if echo "${TEAM_TASKS_KEEP}" | grep -q "Name"; then
    log_pass "teams/${TEST_TEAM}/tasks/.keep exists in MinIO"
else
    log_fail "teams/${TEST_TEAM}/tasks/.keep missing in MinIO"
fi

TEAM_SHARED_KEEP=$(exec_in_manager mc stat "${STORAGE_PREFIX}/teams/${TEST_TEAM}/shared/.keep" 2>&1)
if echo "${TEAM_SHARED_KEEP}" | grep -q "Name"; then
    log_pass "teams/${TEST_TEAM}/shared/.keep exists in MinIO"
else
    log_fail "teams/${TEST_TEAM}/shared/.keep missing in MinIO"
fi

# ============================================================
# Section 4: Verify S3 Policy Includes Team Storage
# ============================================================
log_section "Verify S3 Policy for Team Members"

# Check Leader's MinIO policy
LEADER_POLICY=$(exec_in_manager mc admin policy entities hiclaw "worker-${TEST_LEADER}" 2>/dev/null || echo "")
if [ -n "${LEADER_POLICY}" ]; then
    log_pass "Leader has MinIO policy: worker-${TEST_LEADER}"
else
    log_info "Could not verify Leader MinIO policy (may need different mc command)"
fi

# Functional test: Leader can write to team storage
WRITE_TEST=$(exec_in_manager bash -c "
    echo 'test' > /tmp/team-storage-test.txt
    mc cp /tmp/team-storage-test.txt ${STORAGE_PREFIX}/teams/${TEST_TEAM}/shared/test-write.txt 2>&1
    mc cat ${STORAGE_PREFIX}/teams/${TEST_TEAM}/shared/test-write.txt 2>/dev/null
    mc rm ${STORAGE_PREFIX}/teams/${TEST_TEAM}/shared/test-write.txt 2>/dev/null
    rm -f /tmp/team-storage-test.txt
" 2>&1)
if echo "${WRITE_TEST}" | grep -q "test"; then
    log_pass "Team storage is writable (functional test)"
else
    log_fail "Team storage write test failed"
fi

# ============================================================
# Section 5: Verify Leader Has New Skills
# ============================================================
log_section "Verify Leader Skills"

for skill in team-task-management team-project-management team-task-coordination; do
    SKILL_EXISTS=$(exec_in_manager bash -c "mc ls '${STORAGE_PREFIX}/agents/${TEST_LEADER}/skills/${skill}/SKILL.md' >/dev/null 2>&1 && echo yes || echo no")
    if [ "${SKILL_EXISTS}" = "yes" ]; then
        log_pass "Leader has ${skill} skill"
    else
        log_fail "Leader missing ${skill} skill"
    fi
done

# Verify resolve-dag.sh exists
DAG_SCRIPT=$(exec_in_manager bash -c "mc ls '${STORAGE_PREFIX}/agents/${TEST_LEADER}/skills/team-project-management/scripts/resolve-dag.sh' >/dev/null 2>&1 && echo yes || echo no")
if [ "${DAG_SCRIPT}" = "yes" ]; then
    log_pass "Leader has resolve-dag.sh script"
else
    log_fail "Leader missing resolve-dag.sh script"
fi

# ============================================================
# Section 6: Create Team Project (Manager Source)
# ============================================================
log_section "Create Team Project (Manager Source)"

PROJECT_ID="tp-test-mgr-$$"
PARENT_TASK_ID="task-test-parent-$$"

# We run create-team-project.sh inside the Leader's context
# Since Leader container may not be fully ready, we exec in Manager and simulate
CREATE_PROJECT_OUTPUT=$(exec_in_manager bash -c "
    export TEAM_NAME='${TEST_TEAM}'
    export HOME='/root/hiclaw-fs/agents/${TEST_LEADER}'
    export MC_CONFIG_DIR='/root/manager-workspace/.mc'
    export HICLAW_MATRIX_DOMAIN='${TEST_MATRIX_DOMAIN}'
    mkdir -p \${HOME}/skills/team-task-management/scripts
    mkdir -p \${HOME}/skills/team-project-management/scripts

    # Copy scripts to Leader's home for execution
    cp /opt/hiclaw/agent/team-leader-agent/skills/team-task-management/scripts/manage-team-state.sh \
       \${HOME}/skills/team-task-management/scripts/
    cp /opt/hiclaw/agent/team-leader-agent/skills/team-project-management/scripts/create-team-project.sh \
       \${HOME}/skills/team-project-management/scripts/
    cp /opt/hiclaw/agent/team-leader-agent/skills/team-project-management/scripts/resolve-dag.sh \
       \${HOME}/skills/team-project-management/scripts/

    bash \${HOME}/skills/team-project-management/scripts/create-team-project.sh \
        --id '${PROJECT_ID}' \
        --title 'Test Auth Module' \
        --workers '${TEST_W1},${TEST_W2}' \
        --source manager \
        --parent-task-id '${PARENT_TASK_ID}'
" 2>&1)

if echo "${CREATE_PROJECT_OUTPUT}" | grep -q "RESULT"; then
    log_pass "create-team-project.sh completed (Manager source)"
else
    log_fail "create-team-project.sh failed (Manager source)"
    echo "${CREATE_PROJECT_OUTPUT}" | tail -20
fi

# ============================================================
# Section 7: Verify Project Files in MinIO
# ============================================================
log_section "Verify Project Files in MinIO"

PROJECT_META=$(exec_in_manager mc cat "${STORAGE_PREFIX}/teams/${TEST_TEAM}/projects/${PROJECT_ID}/meta.json" 2>/dev/null || echo "")
if [ -n "${PROJECT_META}" ]; then
    log_pass "Project meta.json exists in MinIO"

    META_SOURCE=$(echo "${PROJECT_META}" | jq -r '.source // empty')
    assert_eq "manager" "${META_SOURCE}" "meta.json source = manager"

    META_PARENT=$(echo "${PROJECT_META}" | jq -r '.parent_task_id // empty')
    assert_eq "${PARENT_TASK_ID}" "${META_PARENT}" "meta.json parent_task_id correct"

    META_STATUS=$(echo "${PROJECT_META}" | jq -r '.status // empty')
    assert_eq "planning" "${META_STATUS}" "meta.json status = planning"

    META_WORKERS=$(echo "${PROJECT_META}" | jq -r '.workers | length')
    assert_eq "2" "${META_WORKERS}" "meta.json has 2 workers"
else
    log_fail "Project meta.json missing from MinIO"
fi

PROJECT_PLAN=$(exec_in_manager mc cat "${STORAGE_PREFIX}/teams/${TEST_TEAM}/projects/${PROJECT_ID}/plan.md" 2>/dev/null || echo "")
if [ -n "${PROJECT_PLAN}" ]; then
    log_pass "Project plan.md exists in MinIO"
    assert_contains "${PROJECT_PLAN}" "Team Project: Test Auth Module" "plan.md has correct title"
    assert_contains "${PROJECT_PLAN}" "${PROJECT_ID}" "plan.md has project ID"
    assert_contains "${PROJECT_PLAN}" "${PARENT_TASK_ID}" "plan.md references parent task"
else
    log_fail "Project plan.md missing from MinIO"
fi

# ============================================================
# Section 8: Fill in DAG Plan and Validate
# ============================================================
log_section "DAG Plan: Fill, Validate, Resolve"

# Write a real DAG plan
exec_in_manager bash -c "
cat > /root/hiclaw-fs/teams/${TEST_TEAM}/projects/${PROJECT_ID}/plan.md <<'PLAN'
# Team Project: Test Auth Module

**ID**: ${PROJECT_ID}
**Parent Task**: ${PARENT_TASK_ID}
**Status**: active
**Team**: ${TEST_TEAM}
**Created**: 2026-03-31T10:00:00Z

## Workers

- @${TEST_W1}:${TEST_MATRIX_DOMAIN} — Backend Developer
- @${TEST_W2}:${TEST_MATRIX_DOMAIN} — QA Engineer

## DAG Task Plan

- [ ] st-01 — Design auth database schema (assigned: @${TEST_W1}:${TEST_MATRIX_DOMAIN})
- [ ] st-02 — Design auth API spec (assigned: @${TEST_W1}:${TEST_MATRIX_DOMAIN})
- [ ] st-03 — Implement auth backend (assigned: @${TEST_W1}:${TEST_MATRIX_DOMAIN}, depends: st-01, st-02)
- [ ] st-04 — Write auth test cases (assigned: @${TEST_W2}:${TEST_MATRIX_DOMAIN}, depends: st-02)
- [ ] st-05 — Integration testing (assigned: @${TEST_W2}:${TEST_MATRIX_DOMAIN}, depends: st-03, st-04)

## Change Log

- 2026-03-31T10:00:00Z: Project initiated
- 2026-03-31T10:05:00Z: DAG plan filled
PLAN
    mc cp /root/hiclaw-fs/teams/${TEST_TEAM}/projects/${PROJECT_ID}/plan.md \
        ${STORAGE_PREFIX}/teams/${TEST_TEAM}/projects/${PROJECT_ID}/plan.md 2>/dev/null
" 2>/dev/null

PLAN_PATH="/root/hiclaw-fs/teams/${TEST_TEAM}/projects/${PROJECT_ID}/plan.md"
LEADER_HOME="/root/hiclaw-fs/agents/${TEST_LEADER}"
MC_ENV="export HOME='${LEADER_HOME}' MC_CONFIG_DIR='/root/manager-workspace/.mc'"

# Test: validate (should pass — no cycles)
VALIDATE_OUTPUT=$(exec_in_manager bash -c "
    export HOME='${LEADER_HOME}'
    bash ${LEADER_HOME}/skills/team-project-management/scripts/resolve-dag.sh \
        --plan '${PLAN_PATH}' --action validate
" 2>&1)

VALID=$(echo "${VALIDATE_OUTPUT}" | jq -r '.valid // empty' 2>/dev/null)
assert_eq "true" "${VALID}" "DAG validate: no cycles detected"

TASK_COUNT=$(echo "${VALIDATE_OUTPUT}" | jq -r '.task_count // empty' 2>/dev/null)
assert_eq "5" "${TASK_COUNT}" "DAG validate: found 5 tasks"

# Test: ready (wave 1 — st-01 and st-02 should be ready)
READY_OUTPUT=$(exec_in_manager bash -c "
    export HOME='${LEADER_HOME}'
    bash ${LEADER_HOME}/skills/team-project-management/scripts/resolve-dag.sh \
        --plan '${PLAN_PATH}' --action ready
" 2>&1)

READY_COUNT=$(echo "${READY_OUTPUT}" | jq '.ready_tasks | length' 2>/dev/null)
assert_eq "2" "${READY_COUNT}" "DAG ready wave 1: 2 tasks ready (st-01, st-02)"

READY_IDS=$(echo "${READY_OUTPUT}" | jq -r '[.ready_tasks[].id] | sort | join(",")' 2>/dev/null)
assert_eq "st-01,st-02" "${READY_IDS}" "DAG ready wave 1: correct task IDs"

BLOCKED_COUNT=$(echo "${READY_OUTPUT}" | jq '.blocked_tasks | length' 2>/dev/null)
assert_eq "3" "${BLOCKED_COUNT}" "DAG ready wave 1: 3 tasks blocked"

# ============================================================
# Section 9: Simulate DAG Execution — Wave Progression
# ============================================================
log_section "DAG Execution: Wave Progression"

# Mark st-01 and st-02 as completed in plan.md
exec_in_manager bash -c "
    sed -i 's/- \[ \] st-01/- [x] st-01/' '${PLAN_PATH}'
    sed -i 's/- \[ \] st-02/- [x] st-02/' '${PLAN_PATH}'
" 2>/dev/null

# Wave 2: st-03 and st-04 should now be ready
WAVE2_OUTPUT=$(exec_in_manager bash -c "
    export HOME='${LEADER_HOME}'
    bash ${LEADER_HOME}/skills/team-project-management/scripts/resolve-dag.sh \
        --plan '${PLAN_PATH}' --action ready
" 2>&1)

WAVE2_READY=$(echo "${WAVE2_OUTPUT}" | jq -r '[.ready_tasks[].id] | sort | join(",")' 2>/dev/null)
assert_eq "st-03,st-04" "${WAVE2_READY}" "DAG wave 2: st-03 and st-04 ready (parallel)"

WAVE2_COMPLETED=$(echo "${WAVE2_OUTPUT}" | jq '.completed | length' 2>/dev/null)
assert_eq "2" "${WAVE2_COMPLETED}" "DAG wave 2: 2 tasks completed"

WAVE2_BLOCKED=$(echo "${WAVE2_OUTPUT}" | jq -r '[.blocked_tasks[].id] | join(",")' 2>/dev/null)
assert_eq "st-05" "${WAVE2_BLOCKED}" "DAG wave 2: st-05 still blocked"

# Mark st-03 as in-progress, st-04 as completed
exec_in_manager bash -c "
    sed -i 's/- \[ \] st-03/- [~] st-03/' '${PLAN_PATH}'
    sed -i 's/- \[ \] st-04/- [x] st-04/' '${PLAN_PATH}'
" 2>/dev/null

# st-05 should still be blocked (st-03 not done yet)
WAVE2B_OUTPUT=$(exec_in_manager bash -c "
    export HOME='${LEADER_HOME}'
    bash ${LEADER_HOME}/skills/team-project-management/scripts/resolve-dag.sh \
        --plan '${PLAN_PATH}' --action ready
" 2>&1)

WAVE2B_READY=$(echo "${WAVE2B_OUTPUT}" | jq '.ready_tasks | length' 2>/dev/null)
assert_eq "0" "${WAVE2B_READY}" "DAG wave 2b: no new tasks ready (st-03 still in-progress)"

WAVE2B_IP=$(echo "${WAVE2B_OUTPUT}" | jq -r '[.in_progress[].id] | join(",")' 2>/dev/null)
assert_eq "st-03" "${WAVE2B_IP}" "DAG wave 2b: st-03 in-progress"

# Mark st-03 as completed
exec_in_manager bash -c "
    sed -i 's/- \[~\] st-03/- [x] st-03/' '${PLAN_PATH}'
" 2>/dev/null

# Wave 3: st-05 should now be ready
WAVE3_OUTPUT=$(exec_in_manager bash -c "
    export HOME='${LEADER_HOME}'
    bash ${LEADER_HOME}/skills/team-project-management/scripts/resolve-dag.sh \
        --plan '${PLAN_PATH}' --action ready
" 2>&1)

WAVE3_READY=$(echo "${WAVE3_OUTPUT}" | jq -r '[.ready_tasks[].id] | join(",")' 2>/dev/null)
assert_eq "st-05" "${WAVE3_READY}" "DAG wave 3: st-05 ready (all deps satisfied)"

# Mark st-05 as completed — all done
exec_in_manager bash -c "
    sed -i 's/- \[ \] st-05/- [x] st-05/' '${PLAN_PATH}'
" 2>/dev/null

# Full status check
STATUS_OUTPUT=$(exec_in_manager bash -c "
    export HOME='${LEADER_HOME}'
    bash ${LEADER_HOME}/skills/team-project-management/scripts/resolve-dag.sh \
        --plan '${PLAN_PATH}' --action status
" 2>&1)

STATUS_COMPLETED=$(echo "${STATUS_OUTPUT}" | jq '.completed | length' 2>/dev/null)
assert_eq "5" "${STATUS_COMPLETED}" "DAG final: all 5 tasks completed"

STATUS_PENDING=$(echo "${STATUS_OUTPUT}" | jq '.pending | length' 2>/dev/null)
assert_eq "0" "${STATUS_PENDING}" "DAG final: 0 tasks pending"

# ============================================================
# Section 10: Verify manage-team-state.sh Project Tracking
# ============================================================
log_section "Verify Project State Tracking"

STATE_SCRIPT="${LEADER_HOME}/skills/team-task-management/scripts/manage-team-state.sh"

# Init state (fresh — remove any state left by create-team-project.sh)
exec_in_manager bash -c "
    rm -f '${LEADER_HOME}/team-state.json'
    export HOME='${LEADER_HOME}'
    bash '${STATE_SCRIPT}' --action init
" 2>/dev/null

# Add project (Manager source)
ADD_PROJECT_OUT=$(exec_in_manager bash -c "
    export HOME='${LEADER_HOME}'
    bash '${STATE_SCRIPT}' --action add-project \
        --project-id '${PROJECT_ID}' --title 'Test Auth Module' \
        --source manager --parent-task-id '${PARENT_TASK_ID}'
" 2>&1)
assert_contains "${ADD_PROJECT_OUT}" "OK" "add-project (Manager source) succeeded"

# Add task (Manager source)
ADD_TASK_OUT=$(exec_in_manager bash -c "
    export HOME='${LEADER_HOME}'
    bash '${STATE_SCRIPT}' --action add-finite \
        --task-id st-01 --title 'Design auth schema' \
        --assigned-to '${TEST_W1}' --room-id '!fake:domain' \
        --source manager --parent-task-id '${PARENT_TASK_ID}'
" 2>&1)
assert_contains "${ADD_TASK_OUT}" "OK" "add-finite (Manager source) succeeded"

# Verify state file
STATE_JSON=$(exec_in_manager cat "${LEADER_HOME}/team-state.json" 2>/dev/null)

STATE_PROJ_COUNT=$(echo "${STATE_JSON}" | jq '.active_projects | length' 2>/dev/null)
assert_eq "1" "${STATE_PROJ_COUNT}" "team-state.json has 1 active project"

STATE_PROJ_SOURCE=$(echo "${STATE_JSON}" | jq -r '.active_projects[0].source // empty' 2>/dev/null)
assert_eq "manager" "${STATE_PROJ_SOURCE}" "Project source = manager in state"

STATE_PROJ_PARENT=$(echo "${STATE_JSON}" | jq -r '.active_projects[0].parent_task_id // empty' 2>/dev/null)
assert_eq "${PARENT_TASK_ID}" "${STATE_PROJ_PARENT}" "Project parent_task_id correct in state"

STATE_TASK_SOURCE=$(echo "${STATE_JSON}" | jq -r '.active_tasks[0].source // empty' 2>/dev/null)
assert_eq "manager" "${STATE_TASK_SOURCE}" "Task source = manager in state"

# ============================================================
# Section 11: Create Team Project (Team Admin Source)
# ============================================================
log_section "Create Team Project (Team Admin Source)"

ADMIN_PROJECT_ID="tp-test-admin-$$"

ADD_ADMIN_PROJECT_OUT=$(exec_in_manager bash -c "
    export HOME='${LEADER_HOME}'
    bash '${STATE_SCRIPT}' --action add-project \
        --project-id '${ADMIN_PROJECT_ID}' --title 'Admin Requested Feature' \
        --source team-admin --requester '@testadmin:${TEST_MATRIX_DOMAIN}'
" 2>&1)
assert_contains "${ADD_ADMIN_PROJECT_OUT}" "OK" "add-project (Team Admin source) succeeded"

# Add task (Team Admin source)
ADD_ADMIN_TASK_OUT=$(exec_in_manager bash -c "
    export HOME='${LEADER_HOME}'
    bash '${STATE_SCRIPT}' --action add-finite \
        --task-id st-admin-01 --title 'Admin task' \
        --assigned-to '${TEST_W2}' --room-id '!fake:domain' \
        --source team-admin --requester '@testadmin:${TEST_MATRIX_DOMAIN}'
" 2>&1)
assert_contains "${ADD_ADMIN_TASK_OUT}" "OK" "add-finite (Team Admin source) succeeded"

# Verify dual-source state
STATE_JSON2=$(exec_in_manager cat "${LEADER_HOME}/team-state.json" 2>/dev/null)

STATE_PROJ2_COUNT=$(echo "${STATE_JSON2}" | jq '.active_projects | length' 2>/dev/null)
assert_eq "2" "${STATE_PROJ2_COUNT}" "team-state.json has 2 active projects"

ADMIN_PROJ_SOURCE=$(echo "${STATE_JSON2}" | jq -r --arg id "${ADMIN_PROJECT_ID}" '.active_projects[] | select(.project_id == $id) | .source' 2>/dev/null)
assert_eq "team-admin" "${ADMIN_PROJ_SOURCE}" "Admin project source = team-admin"

ADMIN_PROJ_REQUESTER=$(echo "${STATE_JSON2}" | jq -r --arg id "${ADMIN_PROJECT_ID}" '.active_projects[] | select(.project_id == $id) | .requester' 2>/dev/null)
assert_contains "${ADMIN_PROJ_REQUESTER}" "testadmin" "Admin project has requester"

ADMIN_TASK_SOURCE=$(echo "${STATE_JSON2}" | jq -r '.active_tasks[] | select(.task_id == "st-admin-01") | .source' 2>/dev/null)
assert_eq "team-admin" "${ADMIN_TASK_SOURCE}" "Admin task source = team-admin"

# ============================================================
# Section 12: Complete and Verify Cleanup
# ============================================================
log_section "Complete Project and Verify State"

# Complete Manager project
COMPLETE_OUT=$(exec_in_manager bash -c "
    export HOME='${LEADER_HOME}'
    bash '${STATE_SCRIPT}' --action complete-project --project-id '${PROJECT_ID}'
" 2>&1)
assert_contains "${COMPLETE_OUT}" "OK" "complete-project succeeded"

# Complete task
exec_in_manager bash -c "
    export HOME='${LEADER_HOME}'
    bash '${STATE_SCRIPT}' --action complete --task-id st-01
" 2>/dev/null

# Verify final state
STATE_JSON3=$(exec_in_manager cat "${LEADER_HOME}/team-state.json" 2>/dev/null)

FINAL_PROJ_COUNT=$(echo "${STATE_JSON3}" | jq '.active_projects | length' 2>/dev/null)
assert_eq "1" "${FINAL_PROJ_COUNT}" "After completion: 1 project remaining (admin project)"

FINAL_TASK_COUNT=$(echo "${STATE_JSON3}" | jq '.active_tasks | length' 2>/dev/null)
assert_eq "1" "${FINAL_TASK_COUNT}" "After completion: 1 task remaining (admin task)"

REMAINING_PROJ=$(echo "${STATE_JSON3}" | jq -r '.active_projects[0].project_id // empty' 2>/dev/null)
assert_eq "${ADMIN_PROJECT_ID}" "${REMAINING_PROJ}" "Remaining project is the admin project"

# ============================================================
# Section 13: Verify DAG Cycle Detection
# ============================================================
log_section "DAG Cycle Detection"

CYCLE_PLAN="/tmp/cycle-test-plan.md"
exec_in_manager bash -c "
cat > '${CYCLE_PLAN}' <<'PLAN'
# Team Project: Cycle Test

## DAG Task Plan

- [ ] st-01 — Task A (assigned: @${TEST_W1}:${TEST_MATRIX_DOMAIN}, depends: st-03)
- [ ] st-02 — Task B (assigned: @${TEST_W2}:${TEST_MATRIX_DOMAIN}, depends: st-01)
- [ ] st-03 — Task C (assigned: @${TEST_W1}:${TEST_MATRIX_DOMAIN}, depends: st-02)

## Change Log
PLAN
" 2>/dev/null

CYCLE_OUTPUT=$(exec_in_manager bash -c "
    export HOME='${LEADER_HOME}'
    bash /opt/hiclaw/agent/team-leader-agent/skills/team-project-management/scripts/resolve-dag.sh \
        --plan '${CYCLE_PLAN}' --action validate 2>&1 || true
" 2>&1)

if echo "${CYCLE_OUTPUT}" | grep -q '"valid": false'; then
    log_pass "DAG cycle detection: correctly identified cycle"
else
    log_fail "DAG cycle detection: correctly identified cycle (output: ${CYCLE_OUTPUT})"
fi

# ============================================================
# Section 14: List all state (final overview)
# ============================================================
log_section "Final State Overview"

LIST_OUTPUT=$(exec_in_manager bash -c "
    export HOME='${LEADER_HOME}'
    bash '${STATE_SCRIPT}' --action list
" 2>&1)

assert_contains "${LIST_OUTPUT}" "team-admin" "List output shows team-admin source"
assert_contains "${LIST_OUTPUT}" "st-admin-01" "List output shows admin task"
assert_contains "${LIST_OUTPUT}" "${ADMIN_PROJECT_ID}" "List output shows admin project"

log_info "Final team-state.json:"
exec_in_manager cat "${LEADER_HOME}/team-state.json" 2>/dev/null | jq . || true

# ============================================================
# NOTE: No cleanup — environment left for manual inspection via Element
# ============================================================
log_info "Environment NOT cleaned up — inspect via Element at http://127.0.0.1:${TEST_ELEMENT_PORT:-18088}"

test_teardown "21-team-project-dag"
test_summary
