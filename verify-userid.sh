#!/usr/bin/env bash
# Run this from the Ceph devcontainer after Keystone is running.
# Usage: ./verify-userid.sh <keystone-ip>
#
# This script:
# 1. Gets tokens for each test user
# 2. Shows the user.id from each token (= keystone:userid)
# 3. Shows the project.id from each token (= aws:userid / RGW user)
# 4. Confirms that different users in the same project get different user.id
#    but the same project.id

set -e

KS_HOST=${1:-172.17.0.4}
KS_URL="http://${KS_HOST}:5000"

echo "Using Keystone at: $KS_URL"
echo ""

get_token() {
    local username=$1
    local password=$2
    local project=$3

    local response
    response=$(curl -s -D - -o /tmp/ks_body_${username}.json \
        "${KS_URL}/v3/auth/tokens" \
        -H "Content-Type: application/json" \
        -d "{
            \"auth\": {
                \"identity\": {
                    \"methods\": [\"password\"],
                    \"password\": {
                        \"user\": {
                            \"name\": \"${username}\",
                            \"domain\": {\"id\": \"default\"},
                            \"password\": \"${password}\"
                        }
                    }
                },
                \"scope\": {
                    \"project\": {
                        \"name\": \"${project}\",
                        \"domain\": {\"id\": \"default\"}
                    }
                }
            }
        }" 2>/dev/null)

    local token
    token=$(echo "$response" | grep -i "x-subject-token" | tr -d '\r' | awk '{print $2}')

    if [ -z "$token" ]; then
        echo "  FAILED to get token for $username"
        echo "  Response: $(cat /tmp/ks_body_${username}.json)"
        return 1
    fi

    local user_id user_name project_id project_name roles
    user_id=$(python3 -c "import json; d=json.load(open('/tmp/ks_body_${username}.json')); print(d['token']['user']['id'])")
    user_name=$(python3 -c "import json; d=json.load(open('/tmp/ks_body_${username}.json')); print(d['token']['user']['name'])")
    project_id=$(python3 -c "import json; d=json.load(open('/tmp/ks_body_${username}.json')); print(d['token']['project']['id'])")
    project_name=$(python3 -c "import json; d=json.load(open('/tmp/ks_body_${username}.json')); print(d['token']['project']['name'])")
    roles=$(python3 -c "import json; d=json.load(open('/tmp/ks_body_${username}.json')); print(', '.join(r['name'] for r in d['token']['roles']))")

    echo "  User: $user_name"
    echo "    keystone:userid  = $user_id    (Keystone user UUID - unique per user)"
    echo "    aws:userid       = $project_id  (Keystone project UUID - shared by project)"
    echo "    project          = $project_name"
    echo "    keystone:role    = $roles"
    echo "    token            = ${token:0:20}..."
    echo ""

    # Export for later use
    eval "TOKEN_${username}=${token}"
    eval "USERID_${username}=${user_id}"
    eval "PROJECTID_${username}=${project_id}"
}

echo "============================================"
echo "  Getting tokens for all test users"
echo "============================================"
echo ""

get_token workerX1 worker1pass test-project
get_token workerX2 worker2pass test-project
get_token workerX3 worker3pass test-project
get_token otherUser otherpass other-project

echo "============================================"
echo "  Verification"
echo "============================================"
echo ""

# Compare user IDs
W1_UID=$(python3 -c "import json; print(json.load(open('/tmp/ks_body_workerX1.json'))['token']['user']['id'])")
W2_UID=$(python3 -c "import json; print(json.load(open('/tmp/ks_body_workerX2.json'))['token']['user']['id'])")
W3_UID=$(python3 -c "import json; print(json.load(open('/tmp/ks_body_workerX3.json'))['token']['user']['id'])")
OTHER_UID=$(python3 -c "import json; print(json.load(open('/tmp/ks_body_otherUser.json'))['token']['user']['id'])")

W1_PID=$(python3 -c "import json; print(json.load(open('/tmp/ks_body_workerX1.json'))['token']['project']['id'])")
W2_PID=$(python3 -c "import json; print(json.load(open('/tmp/ks_body_workerX2.json'))['token']['project']['id'])")
OTHER_PID=$(python3 -c "import json; print(json.load(open('/tmp/ks_body_otherUser.json'))['token']['project']['id'])")

echo "1. Different users in SAME project have DIFFERENT keystone:userid?"
if [ "$W1_UID" != "$W2_UID" ] && [ "$W2_UID" != "$W3_UID" ]; then
    echo "   PASS: workerX1=$W1_UID != workerX2=$W2_UID != workerX3=$W3_UID"
else
    echo "   FAIL: user IDs are not unique!"
fi
echo ""

echo "2. Different users in SAME project have SAME aws:userid (project ID)?"
if [ "$W1_PID" = "$W2_PID" ]; then
    echo "   PASS: workerX1 project=$W1_PID == workerX2 project=$W2_PID"
else
    echo "   FAIL: project IDs differ!"
fi
echo ""

echo "3. Users in DIFFERENT projects have DIFFERENT aws:userid?"
if [ "$W1_PID" != "$OTHER_PID" ]; then
    echo "   PASS: test-project=$W1_PID != other-project=$OTHER_PID"
else
    echo "   FAIL: project IDs are the same!"
fi
echo ""

echo "============================================"
echo "  Summary: What goes where in RGW"
echo "============================================"
echo ""
echo "  keystone:userid  -> Unique per Keystone user (use for per-user ACL)"
echo "  aws:userid       -> Keystone project ID (shared by all users in project)"
echo "  RGW user account -> Auto-created from project ID (e.g. ${W1_PID}\$${W1_PID})"
echo ""
echo "  To use in bucket policy:"
echo "  {"
echo "    \"Condition\": {"
echo "      \"StringEquals\": {"
echo "        \"keystone:userid\": \"$W1_UID\""
echo "      }"
echo "    }"
echo "  }"
echo ""
echo "============================================"
echo "  User IDs for bucket policies"
echo "============================================"
echo ""
echo "  workerX1: $W1_UID"
echo "  workerX2: $W2_UID"
echo "  workerX3: $W3_UID"
echo "  otherUser: $OTHER_UID"
