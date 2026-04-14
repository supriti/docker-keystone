# docker-keystone

Dockerized OpenStack Keystone (v28.0.0) for testing Ceph RGW `keystone:userid`
and `keystone:role` IAM policy condition keys.

## What it does

Starts a Keystone identity service with pre-configured test users, projects,
and roles. Designed to be used with a Ceph RGW build that supports
`keystone:userid` and `keystone:role` condition keys
(branch `wip-s3-policy-keystone-role`).

## Prerequisites

- Docker
- A Ceph build with RGW (`radosgw` and `radosgw-admin`)
- `curl` and `python3` (for the verification script)

## Setup

```bash
docker build -t keystone-rgw-test .

docker run -d --name keystone-test \
  -e ADMIN_USERNAME=admin \
  -e ADMIN_PASSWORD=password \
  -e ADMIN_TENANT_NAME=admin \
  -p 5000:5000 -p 35357:35357 \
  keystone-rgw-test

# Wait for "Ready for testing!" in the logs
docker logs -f keystone-test
```

## Test users created on startup

| User | Password | Project | Roles |
|---|---|---|---|
| `rgw-admin` | `rgw-secret` | `service` | `admin` (RGW service account) |
| `workerX1` | `worker1pass` | `test-project` | `member`, `reader` |
| `workerX2` | `worker2pass` | `test-project` | `member` |
| `workerX3` | `worker3pass` | `test-project` | `member` |
| `otherUser` | `otherpass` | `other-project` | `member` |

## Testing

See [README-testing.md](README-testing.md) for the full step-by-step test
procedure covering user ID verification, bucket policies, and subfolder-level
access control.
