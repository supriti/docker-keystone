FROM ubuntu:26.04

ENV ADMIN_USERNAME=admin
ENV ADMIN_PASSWORD=password
ENV ADMIN_TENANT_NAME=admin

RUN apt-get -y update && \
    apt-get install -y --no-install-recommends memcached mariadb-server python3-dev python3-pip python3-setuptools git-core gcc libssl-dev libcrypt-dev curl
RUN git clone --branch 28.0.0 --single-branch --depth 1 https://github.com/openstack/keystone.git /usr/local/src/keystone && \
    pip3 install --break-system-packages --upgrade setuptools pymysql uwsgi python-openstackclient && \
    cd /usr/local/src/keystone && pip3 install --break-system-packages .
RUN apt-get remove -y --purge git-core git gcc && \
    apt-get autoremove -y --purge && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

COPY keystone.conf /etc/keystone/keystone.conf
COPY keystone.sql /keystone.sql
COPY keystone-uwsgi-admin.ini /keystone-uwsgi-admin.ini
COPY keystone-uwsgi-public.ini /keystone-uwsgi-public.ini

COPY bootstrap.sh /bootstrap.sh
COPY setup-test-users.sh /setup-test-users.sh
RUN chmod a+x /bootstrap.sh /setup-test-users.sh

EXPOSE 5000 35357
ENTRYPOINT ["/bootstrap.sh"]
