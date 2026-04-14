#!/usr/bin/env bash
# Creates test users for verifying keystone:userid and keystone:role
# in Ceph RGW IAM/bucket policies.
set -x

export OS_AUTH_URL=http://localhost:5000/v3
export OS_USERNAME=${ADMIN_USERNAME}
export OS_PASSWORD=${ADMIN_PASSWORD}
export OS_PROJECT_NAME=${ADMIN_TENANT_NAME}
export OS_USER_DOMAIN_NAME=Default
export OS_PROJECT_DOMAIN_NAME=Default
export OS_IDENTITY_API_VERSION=3

# Wait until Keystone is responsive
for i in $(seq 1 30); do
    openstack token issue -f value -c id > /dev/null 2>&1 && break
    echo "Waiting for Keystone to be ready... ($i)"
    sleep 2
done

echo ""
echo "============================================"
echo "  Setting up RGW Keystone test environment"
echo "============================================"
echo ""

# --- Create service project and RGW admin user (for RGW->Keystone auth) ---
openstack project create --domain default service
openstack user create --domain default --password rgw-secret rgw-admin
openstack role add --project service --user rgw-admin admin

# --- Create a test project with two workers ---
# Note: 'member' and 'reader' roles are auto-created by keystone-manage bootstrap
openstack project create --domain default test-project

openstack user create --domain default --password worker1pass workerX1
openstack user create --domain default --password worker2pass workerX2
openstack user create --domain default --password worker3pass workerX3

openstack role add --project test-project --user workerX1 member
openstack role add --project test-project --user workerX2 member
openstack role add --project test-project --user workerX3 member

# Give workerX1 an additional "reader" role
openstack role add --project test-project --user workerX1 reader

# --- Create a second project to test cross-project ---
openstack project create --domain default other-project
openstack user create --domain default --password otherpass otherUser
openstack role add --project other-project --user otherUser member

echo ""
echo "============================================"
echo "  Keystone test users created successfully"
echo "============================================"
echo ""
echo "--- User IDs (these are keystone:userid values) ---"
echo ""
for u in admin workerX1 workerX2 workerX3 otherUser rgw-admin; do
    uid=$(openstack user show "$u" -f value -c id 2>/dev/null)
    echo "  $u -> $uid"
done

echo ""
echo "--- Project IDs (these become RGW user / aws:userid) ---"
echo ""
for p in admin service test-project other-project; do
    pid=$(openstack project show "$p" -f value -c id 2>/dev/null)
    echo "  $p -> $pid"
done

echo ""
echo "--- Role assignments ---"
echo ""
openstack role assignment list --names

echo ""
echo "============================================"
echo "  RGW ceph.conf settings needed:"
echo "============================================"
echo ""
echo '  rgw_keystone_url = "http://<keystone-ip>:5000"'
echo '  rgw_keystone_api_version = 3'
echo '  rgw_keystone_admin_user = "rgw-admin"'
echo '  rgw_keystone_admin_password = "rgw-secret"'
echo '  rgw_keystone_admin_project = "service"'
echo '  rgw_keystone_admin_domain = "Default"'
echo '  rgw_keystone_accepted_roles = "admin,member,reader"'
echo '  rgw_keystone_implicit_tenants = true'
echo '  rgw_s3_auth_use_keystone = true'
echo '  rgw_keystone_verify_ssl = false'
echo ""
echo "--- Test credentials ---"
echo "  workerX1: password=worker1pass  project=test-project"
echo "  workerX2: password=worker2pass  project=test-project"
echo "  workerX3: password=worker3pass  project=test-project"
echo "  otherUser: password=otherpass   project=other-project"
echo ""
echo "============================================"
echo "  Ready for testing!"
echo "============================================"
