#!/bin/bash
set -e

# Bedrock Batch SLA Fallback - Integration Test Script
# Tests all three fallback scenarios end-to-end, including output verification.

REGION="${AWS_DEFAULT_REGION:-us-east-1}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text --profile "${AWS_PROFILE:-default}")
STATE_MACHINE_ARN="arn:aws:states:${REGION}:${ACCOUNT_ID}:stateMachine:bedrock-batch-sla-fallback"
INPUT_BUCKET="bedrock-batch-sla-input-${ACCOUNT_ID}"
OUTPUT_BUCKET="bedrock-batch-sla-output-${ACCOUNT_ID}"
JOBS_TABLE="bedrock-batch-sla-jobs"
ALARM_NAME="bedrock-batch-sla-stuck-job"

TESTS_PASSED=0
TESTS_FAILED=0
FAILED_TESTS=""

echo "Bedrock Batch SLA Fallback - Integration Tests"
echo "=================================================="
echo ""
echo "WARNING: These tests will:"
echo "   - Deploy CDK stack with modified settings"
echo "   - Trigger CloudWatch alarms"
echo "   - Temporarily modify IAM permissions"
echo "   - Create and stop batch jobs"
echo ""
read -p "Continue? (y/n) " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    exit 1
fi

# =============================================================================
# Helper functions
# =============================================================================

# Count records in the local sample input file
input_record_count() {
    grep -c . sample/input.jsonl
}

# Wait for a Step Functions execution to reach a terminal state.
# Writes progress to stderr; writes final status word to stdout.
wait_for_terminal() {
    local exec_arn=$1
    local max_wait=${2:-900}
    local elapsed=0

    echo "Waiting for execution to reach terminal state (max ${max_wait}s)..." >&2
    while [ $elapsed -lt $max_wait ]; do
        STATUS=$(aws stepfunctions describe-execution \
            --execution-arn "$exec_arn" \
            --query 'status' \
            --output text 2>/dev/null || echo "UNKNOWN")

        case "$STATUS" in
            SUCCEEDED|FAILED|TIMED_OUT|ABORTED)
                echo "   Execution reached: $STATUS" >&2
                echo "$STATUS"
                return 0
                ;;
        esac

        sleep 10
        elapsed=$((elapsed + 10))
        echo "   [$elapsed s] status: $STATUS" >&2
    done

    echo "   Timed out waiting for terminal state" >&2
    echo "TIMED_OUT"
    return 1
}

# Check that the merged output exists in S3 and contains exactly expected_count records
verify_output() {
    local job_id=$1
    local expected_count=$2

    local merged_key="merged-output/${job_id}/results.jsonl"
    echo "Verifying output: s3://${OUTPUT_BUCKET}/${merged_key}"

    if ! aws s3 ls "s3://${OUTPUT_BUCKET}/${merged_key}" > /dev/null 2>&1; then
        echo "  FAIL: merged output file not found at ${merged_key}"
        return 1
    fi

    local tmp
    tmp=$(mktemp)
    aws s3 cp "s3://${OUTPUT_BUCKET}/${merged_key}" "$tmp" > /dev/null 2>&1
    local actual_count
    actual_count=$(grep -c . "$tmp" || true)
    rm -f "$tmp"

    echo "  Expected records: $expected_count, Got: $actual_count"
    if [ "$actual_count" -eq "$expected_count" ]; then
        echo "  PASS: record count matches"
        return 0
    else
        echo "  FAIL: record count mismatch"
        return 1
    fi
}

# Extract job_id from execution ARN (execution name is batch-job-{uuid})
job_id_from_exec_arn() {
    local exec_arn=$1
    echo "$exec_arn" | grep -oE 'batch-job-[a-f0-9-]{36}' | sed 's/batch-job-//'
}

check_fallback_states() {
    local exec_arn=$1

    HISTORY=$(aws stepfunctions get-execution-history \
        --execution-arn "$exec_arn" \
        --output json)

    local fallback
    fallback=$(echo "$HISTORY" | jq '[.events[] | select(.stateEnteredEventDetails.name == "FallbackEntry")] | length')
    local reconcile
    reconcile=$(echo "$HISTORY" | jq '[.events[] | select(.stateEnteredEventDetails.name == "ReconcileRecords")] | length')
    local redrive
    redrive=$(echo "$HISTORY" | jq '[.events[] | select(.stateEnteredEventDetails.name == "RedriveOnDemand")] | length')
    local merge
    merge=$(echo "$HISTORY" | jq '[.events[] | select(.stateEnteredEventDetails.name == "MergeResults")] | length')

    echo "  FallbackEntry:   $fallback"
    echo "  ReconcileRecords: $reconcile"
    echo "  RedriveOnDemand: $redrive"
    echo "  MergeResults:    $merge"

    [ "$fallback" -gt 0 ] && [ "$reconcile" -gt 0 ] && [ "$redrive" -gt 0 ] && [ "$merge" -gt 0 ]
}

pass_test() {
    local name=$1
    echo "PASSED: $name"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

fail_test() {
    local name=$1
    local reason=$2
    echo "FAILED: $name — $reason"
    TESTS_FAILED=$((TESTS_FAILED + 1))
    FAILED_TESTS="$FAILED_TESTS\n  - $name: $reason"
}

restore_normal_config() {
    echo "Restoring normal configuration..."
    npx cdk deploy --profile "${AWS_PROFILE:-default}" --require-approval never > /dev/null 2>&1
    echo "Restored."
}

# =============================================================================
# TEST 1: Timeout Fallback
# =============================================================================
echo ""
echo "==================================================================="
echo "TEST 1: Timeout Fallback (Step Functions timeout)"
echo "==================================================================="

RECORD_COUNT=$(input_record_count)

echo "Step 1: Deploy with 2-minute SLA..."
npx cdk deploy --profile "${AWS_PROFILE:-default}" -c slaTotalMinutes=2 --require-approval never > /dev/null 2>&1
echo "   Deployed with 2-minute SLA (batch cutoff ~60s)"

echo "Step 2: Upload sample/input.jsonl ($RECORD_COUNT records)..."
TEST_KEY="test-timeout-$(date +%s).jsonl"
aws s3 cp sample/input.jsonl "s3://$INPUT_BUCKET/$TEST_KEY" > /dev/null 2>&1
echo "   Uploaded: $TEST_KEY"

echo "Step 3: Get execution ARN..."
sleep 10
EXEC_ARN=$(aws stepfunctions list-executions \
    --state-machine-arn "$STATE_MACHINE_ARN" \
    --max-results 1 \
    --output json | jq -r '.executions[0].executionArn')
echo "   Execution: $EXEC_ARN"

echo "Step 4: Wait for terminal state..."
FINAL_STATUS=$(wait_for_terminal "$EXEC_ARN" 900)

if [ "$FINAL_STATUS" != "SUCCEEDED" ]; then
    fail_test "TEST 1: Timeout Fallback" "Execution ended with $FINAL_STATUS instead of SUCCEEDED"
else
    echo "Step 5: Verify fallback states were entered..."
    if ! check_fallback_states "$EXEC_ARN"; then
        fail_test "TEST 1: Timeout Fallback" "Fallback states not all entered"
    else
        echo "Step 6: Verify merged output record count..."
        JOB_ID=$(job_id_from_exec_arn "$EXEC_ARN")
        if verify_output "$JOB_ID" $RECORD_COUNT; then
            pass_test "TEST 1: Timeout Fallback"
        else
            fail_test "TEST 1: Timeout Fallback" "Output record count mismatch"
        fi
    fi
fi

restore_normal_config

# =============================================================================
# TEST 2: Stuck Job Alarm Fallback
# =============================================================================
echo ""
echo "==================================================================="
echo "TEST 2: Stuck Job Alarm Fallback (CloudWatch alarm trigger)"
echo "==================================================================="

RECORD_COUNT=$(input_record_count)

echo "Step 1: Upload sample/input.jsonl ($RECORD_COUNT records)..."
TEST_KEY="test-alarm-$(date +%s).jsonl"
aws s3 cp sample/input.jsonl "s3://$INPUT_BUCKET/$TEST_KEY" > /dev/null 2>&1
echo "   Uploaded: $TEST_KEY"

sleep 10
EXEC_ARN=$(aws stepfunctions list-executions \
    --state-machine-arn "$STATE_MACHINE_ARN" \
    --max-results 1 \
    --output json | jq -r '.executions[0].executionArn')
echo "   Execution: $EXEC_ARN"

echo "Step 2: Wait 90s for batch job to reach InProgress and emit metrics..."
sleep 90

STATUS=$(aws stepfunctions describe-execution --execution-arn "$EXEC_ARN" --query 'status' --output text)
if [ "$STATUS" != "RUNNING" ]; then
    fail_test "TEST 2: Alarm Fallback" "Execution not RUNNING after 90s (status: $STATUS)"
else
    echo "Step 3: Trigger CloudWatch alarm to simulate stuck job..."
    aws cloudwatch set-alarm-state \
        --alarm-name "$ALARM_NAME" \
        --state-value ALARM \
        --state-reason "Integration test: simulating stuck job" > /dev/null 2>&1
    echo "   Alarm triggered"

    echo "Step 4: Wait for terminal state..."
    FINAL_STATUS=$(wait_for_terminal "$EXEC_ARN" 900)

    # Reset alarm regardless of outcome
    aws cloudwatch set-alarm-state \
        --alarm-name "$ALARM_NAME" \
        --state-value OK \
        --state-reason "Integration test complete" > /dev/null 2>&1

    if [ "$FINAL_STATUS" != "SUCCEEDED" ]; then
        fail_test "TEST 2: Alarm Fallback" "Execution ended with $FINAL_STATUS instead of SUCCEEDED"
    else
        echo "Step 5: Verify fallback states were entered..."
        if ! check_fallback_states "$EXEC_ARN"; then
            fail_test "TEST 2: Alarm Fallback" "Fallback states not all entered"
        else
            echo "Step 6: Verify merged output record count..."
            JOB_ID=$(job_id_from_exec_arn "$EXEC_ARN")
            if verify_output "$JOB_ID" $RECORD_COUNT; then
                pass_test "TEST 2: Alarm Fallback"
            else
                fail_test "TEST 2: Alarm Fallback" "Output record count mismatch"
            fi
        fi
    fi
fi

# =============================================================================
# TEST 3: Failed Job Fallback
# =============================================================================
echo ""
echo "==================================================================="
echo "TEST 3: Failed Job Fallback (EventBridge terminal state)"
echo "==================================================================="

RECORD_COUNT=$(input_record_count)

echo "Step 1: Temporarily deny InvokeModel permission on Bedrock service role..."
aws iam put-role-policy \
    --role-name bedrock-batch-sla-service-role \
    --policy-name TestDenyInvokeModel \
    --policy-document '{
        "Version": "2012-10-17",
        "Statement": [{
            "Effect": "Deny",
            "Action": "bedrock:InvokeModel",
            "Resource": "*"
        }]
    }' > /dev/null 2>&1
echo "   Permission denied (temporary)"

echo "Step 2: Upload sample/input.jsonl (batch job will fail due to denied InvokeModel)..."
TEST_KEY="test-failed-$(date +%s).jsonl"
aws s3 cp sample/input.jsonl "s3://$INPUT_BUCKET/$TEST_KEY" > /dev/null 2>&1
echo "   Uploaded: $TEST_KEY"

sleep 10
EXEC_ARN=$(aws stepfunctions list-executions \
    --state-machine-arn "$STATE_MACHINE_ARN" \
    --max-results 1 \
    --output json | jq -r '.executions[0].executionArn')
echo "   Execution: $EXEC_ARN"
JOB_ID=$(job_id_from_exec_arn "$EXEC_ARN")

echo "Step 3: Poll Bedrock until job reaches Failed state (max 10 min)..."
JOB_FAILED=false
for i in $(seq 1 40); do
    JOB_ARN=$(aws dynamodb get-item \
        --table-name "$JOBS_TABLE" \
        --key "{\"JobId\":{\"S\":\"$JOB_ID\"}}" \
        --output json 2>/dev/null | jq -r '.Item.BedrockJobArn.S // empty')

    if [ -n "$JOB_ARN" ]; then
        BEDROCK_STATUS=$(aws bedrock get-model-invocation-job \
            --job-identifier "$JOB_ARN" \
            --query 'status' \
            --output text 2>/dev/null || echo "UNKNOWN")
        echo "   [$i] Bedrock job status: $BEDROCK_STATUS"
        if [ "$BEDROCK_STATUS" = "Failed" ]; then
            echo "   Batch job failed as expected"
            JOB_FAILED=true
            break
        elif [[ "$BEDROCK_STATUS" =~ ^(Completed|Stopped|PartiallyCompleted|Expired)$ ]]; then
            echo "   Unexpected terminal state: $BEDROCK_STATUS"
            break
        fi
    else
        echo "   [$i] Waiting for job ARN..."
    fi
    sleep 15
done

# Restore permissions before checking results (regardless of outcome)
echo "Step 4: Restore InvokeModel permission..."
aws iam delete-role-policy \
    --role-name bedrock-batch-sla-service-role \
    --policy-name TestDenyInvokeModel > /dev/null 2>&1
echo "   Permissions restored"

if [ "$JOB_FAILED" != "true" ]; then
    fail_test "TEST 3: Failed Job Fallback" "Batch job did not reach Failed state within timeout"
else
    echo "Step 5: Wait for terminal state (EventBridge → Resume Lambda → fallback → merge)..."
    FINAL_STATUS=$(wait_for_terminal "$EXEC_ARN" 900)

    if [ "$FINAL_STATUS" != "SUCCEEDED" ]; then
        fail_test "TEST 3: Failed Job Fallback" "Execution ended with $FINAL_STATUS instead of SUCCEEDED"
    else
        echo "Step 6: Verify fallback states were entered..."
        if ! check_fallback_states "$EXEC_ARN"; then
            fail_test "TEST 3: Failed Job Fallback" "Fallback states not all entered"
        else
            echo "Step 7: Verify merged output record count..."
            if verify_output "$JOB_ID" $RECORD_COUNT; then
                pass_test "TEST 3: Failed Job Fallback"
            else
                fail_test "TEST 3: Failed Job Fallback" "Output record count mismatch"
            fi
        fi
    fi
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "==================================================================="
echo "TEST SUMMARY"
echo "==================================================================="
echo ""
echo "  Passed: $TESTS_PASSED"
echo "  Failed: $TESTS_FAILED"
echo ""
echo "View executions:"
echo "  https://console.aws.amazon.com/states/home?region=${REGION}#/statemachines/view/${STATE_MACHINE_ARN}"
echo ""

if [ $TESTS_FAILED -gt 0 ]; then
    echo "FAILED tests:"
    echo -e "$FAILED_TESTS"
    echo ""
    exit 1
fi

exit 0
