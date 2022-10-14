# syntax=docker/dockerfile:1
FROM alpine:latest
LABEL maintainer="Alfred TCHONDJO <tchondjo.ext@gmail.com>"

# environnement vars:
ENV SLAPD_CONFIG_DIR=/etc/openldap/slapd.d \
    APP_CONFIG_DIR=/opt/applications/slapd \
    SLAPD_DATA_DIR=/var/lib/openldap/openldap-data \
    SLAPD_MAIN_CONFIG_FILE=/etc/conf.d/slapd \
    SLAPD_OLD_CONFIG_FILE=/etc/openldap/slapd.conf \
    SLAPD_CONFIG_FILE=/etc/openldap/slapd.ldif \
    SLAPD_IPC_SOCKET=/run/openldap/ldapi

# Install dependencies:
RUN mkdir -p ${APP_CONFIG_DIR}; \
    apk update  &&\
    apk upgrade &&\
    apk add gettext \
    openldap \
    openldap-clients \
    openldap-back-mdb \
    openldap-passwd-pbkdf2 \
    openldap-overlay-memberof \
    openldap-overlay-ppolicy \
    openldap-overlay-refint  &&\
    rm -rf /var/cache/apk/*

EXPOSE 389 636

COPY openldap/ ${APP_CONFIG_DIR}/
COPY entrypoint.sh /

RUN chmod +xr /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
