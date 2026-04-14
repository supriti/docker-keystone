# Testing keystone:userid and keystone:role with Ceph RGW

Each command can be run directly in the terminal.

Replace `KEYSTONE_IP` with your Keystone container IP throughout.

---

## Step 1: Start Keystone

```bash
docker build -t keystone-rgw-test .

docker run -d --name keystone-test \
  -e ADMIN_USERNAME=admin \
  -e ADMIN_PASSWORD=password \
  -e ADMIN_TENANT_NAME=admin \
  -p 5000:5000 -p 35357:35357 \
  keystone-rgw-test

docker logs -f keystone-test
# Wait for "Ready for testing!", then Ctrl+C
```

## Step 2: Set Keystone IP

If running from the same Docker host:

```bash
export KEYSTONE_IP=$(docker inspect keystone-test --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
echo "Keystone IP: $KEYSTONE_IP"
```

If running from a different machine (e.g. a devcontainer), set it manually:

```bash
export KEYSTONE_IP=172.17.0.4
```

This variable is used in all subsequent commands.

## Step 3: Verify user IDs

```bash
./verify-userid.sh $KEYSTONE_IP
```

Note the UUIDs from the output. You will need them for policies later:
- workerX1 `keystone:userid` = ?
- workerX2 `keystone:userid` = ?
- workerX3 `keystone:userid` = ?

## Step 4: Start RGW

```bash
cd /path/to/ceph/build

MON=1 OSD=1 MDS=0 MGR=1 RGW=1 ../src/vstart.sh -n -d -o \
"rgw_keystone_url = \"http://$KEYSTONE_IP:5000\"
rgw_keystone_api_version = 3
rgw_keystone_admin_user = \"rgw-admin\"
rgw_keystone_admin_password = \"rgw-secret\"
rgw_keystone_admin_project = \"service\"
rgw_keystone_admin_domain = \"Default\"
rgw_keystone_accepted_roles = \"admin,member,reader\"
rgw_keystone_implicit_tenants = true
rgw_s3_auth_use_keystone = true
rgw_keystone_verify_ssl = false"
```

## Step 5: Get Keystone tokens

```bash
TOKEN_W1=$(curl -si http://$KEYSTONE_IP:5000/v3/auth/tokens -H "Content-Type: application/json" -d '{"auth":{"identity":{"methods":["password"],"password":{"user":{"name":"workerX1","domain":{"id":"default"},"password":"worker1pass"}}},"scope":{"project":{"name":"test-project","domain":{"id":"default"}}}}}' 2>/dev/null | grep -i x-subject-token | awk '{print $2}' | tr -d '\r')
echo "TOKEN_W1: ${TOKEN_W1:0:20}..."

TOKEN_W2=$(curl -si http://$KEYSTONE_IP:5000/v3/auth/tokens -H "Content-Type: application/json" -d '{"auth":{"identity":{"methods":["password"],"password":{"user":{"name":"workerX2","domain":{"id":"default"},"password":"worker2pass"}}},"scope":{"project":{"name":"test-project","domain":{"id":"default"}}}}}' 2>/dev/null | grep -i x-subject-token | awk '{print $2}' | tr -d '\r')
echo "TOKEN_W2: ${TOKEN_W2:0:20}..."

TOKEN_W3=$(curl -si http://$KEYSTONE_IP:5000/v3/auth/tokens -H "Content-Type: application/json" -d '{"auth":{"identity":{"methods":["password"],"password":{"user":{"name":"workerX3","domain":{"id":"default"},"password":"worker3pass"}}},"scope":{"project":{"name":"test-project","domain":{"id":"default"}}}}}' 2>/dev/null | grep -i x-subject-token | awk '{print $2}' | tr -d '\r')
echo "TOKEN_W3: ${TOKEN_W3:0:20}..."
```

## Step 6: Trigger RGW user creation

```bash
curl -s -w "workerX1: HTTP %{http_code}\n" -H "X-Auth-Token: $TOKEN_W1" http://localhost:8000/swift/v1
curl -s -w "workerX2: HTTP %{http_code}\n" -H "X-Auth-Token: $TOKEN_W2" http://localhost:8000/swift/v1
curl -s -w "workerX3: HTTP %{http_code}\n" -H "X-Auth-Token: $TOKEN_W3" http://localhost:8000/swift/v1
```

All should return HTTP 204.

## Step 7: Check auto-created RGW user

```bash
bin/radosgw-admin user list
```

You will see one user like `<PROJECT_ID>$<PROJECT_ID>`. All three workers share it.
Copy that user ID and inspect it:

```bash
bin/radosgw-admin user info --uid='<PROJECT_ID>$<PROJECT_ID>'
```

You should see `"type": "keystone"` and `"display_name": "test-project"`.

## Step 8: Generate S3 keys

```bash
bin/radosgw-admin key create --uid='<PROJECT_ID>$<PROJECT_ID>' --key-type=s3 --gen-access-key --gen-secret
```

Copy the `access_key` and `secret_key` from the output. Set them:

```bash
S3_ACCESS_KEY=<paste access_key here>
S3_SECRET_KEY=<paste secret_key here>
```

---

## Test A: Per-user bucket policy

### Create bucket

```bash
python3 -c "
import boto3
s3 = boto3.client('s3', endpoint_url='http://localhost:8000',
    aws_access_key_id='$S3_ACCESS_KEY',
    aws_secret_access_key='$S3_SECRET_KEY', region_name='')
s3.create_bucket(Bucket='policy-test')
print('Bucket created')
"
```

### Set policy (deny write unless workerX1)

Replace `WORKERX1_UUID` with the actual UUID from Step 3.

```bash
cat > /tmp/policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "DenyWriteUnlessWorkerX1",
    "Effect": "Deny",
    "Principal": "*",
    "Action": "s3:PutObject",
    "Resource": "arn:aws:s3:::policy-test/*",
    "Condition": {
      "StringNotEquals": {
        "keystone:userid": "WORKERX1_UUID"
      }
    }
  }]
}
EOF
```

Apply:

```bash
python3 -c "
import boto3, json
s3 = boto3.client('s3', endpoint_url='http://localhost:8000',
    aws_access_key_id='$S3_ACCESS_KEY',
    aws_secret_access_key='$S3_SECRET_KEY', region_name='')
policy = json.load(open('/tmp/policy.json'))
s3.put_bucket_policy(Bucket='policy-test', Policy=json.dumps(policy))
print('Policy set')
"
```

### Test

```bash
echo "--- workerX1 PUT (expect 201) ---"
curl -s -w "HTTP: %{http_code}\n" -X PUT -H "X-Auth-Token: $TOKEN_W1" -d "data" http://localhost:8000/swift/v1/policy-test/file.txt

echo "--- workerX2 PUT (expect 403) ---"
curl -s -w "HTTP: %{http_code}\n" -X PUT -H "X-Auth-Token: $TOKEN_W2" -d "data" http://localhost:8000/swift/v1/policy-test/file.txt

echo "--- workerX3 PUT (expect 403) ---"
curl -s -w "HTTP: %{http_code}\n" -X PUT -H "X-Auth-Token: $TOKEN_W3" -d "data" http://localhost:8000/swift/v1/policy-test/file.txt

echo "--- workerX2 GET (expect 200) ---"
curl -s -w "HTTP: %{http_code}\n" -X GET -H "X-Auth-Token: $TOKEN_W2" http://localhost:8000/swift/v1/policy-test/file.txt
```

Expected: workerX1 can write, workerX2/X3 denied, workerX2 can read.

---

## Test B: Subfolder isolation

### Create bucket

```bash
python3 -c "
import boto3
s3 = boto3.client('s3', endpoint_url='http://localhost:8000',
    aws_access_key_id='$S3_ACCESS_KEY',
    aws_secret_access_key='$S3_SECRET_KEY', region_name='')
s3.create_bucket(Bucket='subfolder-test')
print('Bucket created')
"
```

### Set policy

Replace `WORKERX1_UUID`, `WORKERX2_UUID`, `WORKERX3_UUID` with actual UUIDs from Step 3.

The pattern: deny each worker from writing to folders that are NOT theirs.
No explicit Allow needed — bucket owner (project) already has full access.

```bash
cat > /tmp/subfolder-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DenyWorkerX1WriteToX2",
      "Effect": "Deny",
      "Principal": "*",
      "Action": "s3:PutObject",
      "Resource": "arn:aws:s3:::subfolder-test/Z/Y/X2/*",
      "Condition": {
        "StringEquals": { "keystone:userid": "WORKERX1_UUID" }
      }
    },
    {
      "Sid": "DenyWorkerX1WriteToX3",
      "Effect": "Deny",
      "Principal": "*",
      "Action": "s3:PutObject",
      "Resource": "arn:aws:s3:::subfolder-test/Z/Y/X3/*",
      "Condition": {
        "StringEquals": { "keystone:userid": "WORKERX1_UUID" }
      }
    },
    {
      "Sid": "DenyWorkerX2WriteToX1",
      "Effect": "Deny",
      "Principal": "*",
      "Action": "s3:PutObject",
      "Resource": "arn:aws:s3:::subfolder-test/Z/Y/X1/*",
      "Condition": {
        "StringEquals": { "keystone:userid": "WORKERX2_UUID" }
      }
    },
    {
      "Sid": "DenyWorkerX2WriteToX3",
      "Effect": "Deny",
      "Principal": "*",
      "Action": "s3:PutObject",
      "Resource": "arn:aws:s3:::subfolder-test/Z/Y/X3/*",
      "Condition": {
        "StringEquals": { "keystone:userid": "WORKERX2_UUID" }
      }
    },
    {
      "Sid": "DenyWorkerX3WriteAll",
      "Effect": "Deny",
      "Principal": "*",
      "Action": "s3:PutObject",
      "Resource": "arn:aws:s3:::subfolder-test/Z/Y/*",
      "Condition": {
        "StringEquals": { "keystone:userid": "WORKERX3_UUID" }
      }
    },
    {
      "Sid": "AllMembersRead",
      "Effect": "Allow",
      "Principal": "*",
      "Action": "s3:GetObject",
      "Resource": "arn:aws:s3:::subfolder-test/Z/Y/*",
      "Condition": {
        "StringEquals": { "keystone:role": "member" }
      }
    }
  ]
}
EOF
```

Apply:

```bash
python3 -c "
import boto3, json
s3 = boto3.client('s3', endpoint_url='http://localhost:8000',
    aws_access_key_id='$S3_ACCESS_KEY',
    aws_secret_access_key='$S3_SECRET_KEY', region_name='')
policy = json.load(open('/tmp/subfolder-policy.json'))
s3.put_bucket_policy(Bucket='subfolder-test', Policy=json.dumps(policy))
print('Policy set')
"
```

### Test

```bash
echo "--- workerX1 PUT Z/Y/X1/ own folder (expect 201) ---"
curl -s -w "HTTP: %{http_code}\n" -X PUT -H "X-Auth-Token: $TOKEN_W1" -d "data" http://localhost:8000/swift/v1/subfolder-test/Z/Y/X1/file.txt

echo "--- workerX1 PUT Z/Y/X2/ other folder (expect 403) ---"
curl -s -w "HTTP: %{http_code}\n" -X PUT -H "X-Auth-Token: $TOKEN_W1" -d "data" http://localhost:8000/swift/v1/subfolder-test/Z/Y/X2/file.txt

echo "--- workerX2 PUT Z/Y/X2/ own folder (expect 201) ---"
curl -s -w "HTTP: %{http_code}\n" -X PUT -H "X-Auth-Token: $TOKEN_W2" -d "data" http://localhost:8000/swift/v1/subfolder-test/Z/Y/X2/file.txt

echo "--- workerX2 PUT Z/Y/X1/ other folder (expect 403) ---"
curl -s -w "HTTP: %{http_code}\n" -X PUT -H "X-Auth-Token: $TOKEN_W2" -d "data" http://localhost:8000/swift/v1/subfolder-test/Z/Y/X1/file.txt

echo "--- workerX3 PUT Z/Y/X1/ (expect 403, no write anywhere) ---"
curl -s -w "HTTP: %{http_code}\n" -X PUT -H "X-Auth-Token: $TOKEN_W3" -d "data" http://localhost:8000/swift/v1/subfolder-test/Z/Y/X1/file.txt

echo "--- workerX2 GET Z/Y/X1/ (expect 200, all members read) ---"
curl -s -w "HTTP: %{http_code}\n" -X GET -H "X-Auth-Token: $TOKEN_W2" http://localhost:8000/swift/v1/subfolder-test/Z/Y/X1/file.txt

echo "--- workerX3 GET Z/Y/X2/ (expect 200, all members read) ---"
curl -s -w "HTTP: %{http_code}\n" -X GET -H "X-Auth-Token: $TOKEN_W3" http://localhost:8000/swift/v1/subfolder-test/Z/Y/X2/file.txt
```

### Expected results

| Command | User | Path | Expected |
|---|---|---|---|
| PUT | workerX1 | Z/Y/X1/ (own) | 201 |
| PUT | workerX1 | Z/Y/X2/ (other) | 403 |
| PUT | workerX2 | Z/Y/X2/ (own) | 201 |
| PUT | workerX2 | Z/Y/X1/ (other) | 403 |
| PUT | workerX3 | Z/Y/X1/ | 403 |
| GET | workerX2 | Z/Y/X1/ | 200 |
| GET | workerX3 | Z/Y/X2/ | 200 |

---

## Cleanup

```bash
docker stop keystone-test && docker rm keystone-test
cd /path/to/ceph/build && ../src/stop.sh
```
