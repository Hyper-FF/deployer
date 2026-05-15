# syntax=docker/dockerfile:1.4
#
# Builds a runtime image containing a user-supplied StarRocks tarball.
# Expected tarball layout (after stripping the top-level directory):
#     fe/   { bin, conf, lib, ... }
#     be/   { bin, conf, lib, ... }
#
# Build args:
#   BASE_IMAGE     - JDK-bearing base image (default: eclipse-temurin:17-jdk-jammy)
#   PACKAGE_FILE   - filename of the tarball inside ./packages/ (required)

ARG BASE_IMAGE=eclipse-temurin:17-jdk-jammy
FROM ${BASE_IMAGE}

# Runtime dependencies for FE/BE plus the mysql client our entrypoints use to
# talk to the leader during cluster join.
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        curl \
        default-mysql-client \
        netcat-openbsd \
        procps \
        tzdata \
        zip unzip && \
    rm -rf /var/lib/apt/lists/*

ENV STARROCKS_HOME=/opt/starrocks \
    PATH=/opt/starrocks/fe/bin:/opt/starrocks/be/bin:${PATH}

ARG PACKAGE_FILE
RUN test -n "${PACKAGE_FILE}" || (echo "PACKAGE_FILE build arg is required" && false)

COPY packages/${PACKAGE_FILE} /tmp/sr.tar.gz
RUN mkdir -p ${STARROCKS_HOME} && \
    tar -xzf /tmp/sr.tar.gz -C ${STARROCKS_HOME} --strip-components=1 && \
    rm -f /tmp/sr.tar.gz && \
    test -x ${STARROCKS_HOME}/fe/bin/start_fe.sh || \
        (echo "package does not contain fe/bin/start_fe.sh after --strip-components=1" && \
         ls -la ${STARROCKS_HOME} && false) && \
    test -x ${STARROCKS_HOME}/be/bin/start_be.sh || \
        (echo "package does not contain be/bin/start_be.sh after --strip-components=1" && \
         ls -la ${STARROCKS_HOME} && false) && \
    mkdir -p ${STARROCKS_HOME}/fe/log ${STARROCKS_HOME}/be/log \
             ${STARROCKS_HOME}/fe/meta ${STARROCKS_HOME}/be/storage

COPY runtime/fe-entrypoint.sh runtime/be-entrypoint.sh /opt/
RUN chmod +x /opt/fe-entrypoint.sh /opt/be-entrypoint.sh

# FE: edit_log=9010 rpc=9020 query=9030 http=8030
# BE: be_port=9060 webserver=8040 heartbeat=9050 brpc=8060
EXPOSE 8030 9010 9020 9030  8040 9050 9060 8060

WORKDIR ${STARROCKS_HOME}
