FROM registry.fedoraproject.org/fedora:37
LABEL maintainer "Fedora-CI"
LABEL description="rpminspect for fedora-ci"

# https://copr.fedorainfracloud.org/coprs/dcantrell/rpminspect/
ENV RPMINSPECT_PACKAGE_NAME=rpminspect
ENV RPMINSPECT_DATA_PACKAGE_NAME=rpminspect-data-fedora

ENV RPMINSPECT_WORKDIR=/workdir/
ENV HOME=${RPMINSPECT_WORKDIR}

RUN mkdir -p ${RPMINSPECT_WORKDIR} &&\
    chmod 777 ${RPMINSPECT_WORKDIR}

RUN dnf -y install 'dnf-command(copr)' && \
    dnf -y copr enable dcantrell/rpminspect

# We enable updates-testing to pull in the latest annobin
RUN dnf install -y --enablerepo=updates-testing \
    ${RPMINSPECT_PACKAGE_NAME} \
    ${RPMINSPECT_DATA_PACKAGE_NAME} \
    libabigail \
    clamav-update \
    python3-pyyaml \
    koji \
    git \
    jq \
    && dnf clean all

# Update the virus database (we also update it when running the inspection)
RUN freshclam

COPY *.sh scripts/rpminspect_json2text.py /usr/local/bin/

WORKDIR ${RPMINSPECT_WORKDIR}
