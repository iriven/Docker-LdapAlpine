#!/bin/sh
# escape url
_escurl() { echo $1 | sed 's|/|%2F|g' ;}
_gensuffix() { [ ${#} -eq 1 ] && echo 'dc='$(echo ${1//dc=/}|sed 's/,/\./g'|sed -e 's/\.\+/,dc=/g') || echo ""; }
_genrootdn() { [ ${#} -eq 2 ] && echo "cn=${1},${2}" || echo ""; }
_genpasswordhash() { [ ${#} -eq 1 ] && echo $(slappasswd -o module-load=pw-pbkdf2.so -h {PBKDF2-SHA512} -s "${1}") || echo ""; }
_gendomain(){ [ ${#} -eq 1 ] && echo ${1//dc=/}|sed 's/,/\./g'|awk -F. '{print $(NF-1)}' || echo ""; }


if [[ ! ${SLAPD_dNSDOMAIN} ]]; then
    echo "SLAPD_dNSDOMAIN is required while generating organization ldif" >&2
    exit 1
fi

if [[ ! ${LDAPADD_DEBUG_LEVEL} ]]; then
    echo "LDAPADD_DEBUG_LEVEL is required while generating
        organization ldif template" >&2
    exit 1
fi

if [[ ! ${SLAPD_ORGANIZATION} ]]; then
    echo "SLAPD_ORGANIZATION is required while generating organization
    ldif template" >&2
    exit 1
fi


if [[ ! ${SLAPD_LOG_LEVEL} ]]; then
    echo "SLAPD_LOG_LEVEL is required while generating
        organization ldif template" >&2
    exit 1
fi

SLAPD_CONFIG_DIR=/etc/openldap/slapd.d
SLAPD_DAEMON_CONFIG=/etc/conf.d/slapd
SLAPD_DEPRECATED_CONFIG=/etc/openldap/slapd.conf
SLAPD_CONFIG_FILE=/etc/openldap/slapd.ldif
SLAPD_IPC_SOCKET=/run/openldap/ldapi

TEMP_FILE=/tmp/openldap.tmp.ldif
DB_DUMP_DIR=${APP_CONFIG_DIR}/dump
DB_DUMP_FILE=${DB_DUMP_DIR}/dbdump.ldif
TLS_ISACTIVE=1

# substitute environment variables in file
_envsubst() { envsubst < $1 > ${TEMP_FILE}; echo ${TEMP_FILE} ; }

SLAPD_SUFFIX="$(_gensuffix ${SLAPD_dNSDOMAIN})"
SLAPD_DOMAIN="$(_gendomain ${SLAPD_dNSDOMAIN})"
SLAPD_ROOTDN="$(_genrootdn ${SLAPD_ROOT_USER} ${SLAPD_SUFFIX})"
SLAPD_ROOTPW="$(_genpasswordhash ${SLAPD_ROOT_PASSWORD})"
SLAPD_HOSTNAME=$(hostname)

echo "SLAPD_SUFFIX = ${SLAPD_SUFFIX}"
if [[ -z "${SLAPD_SUFFIX}" ]]; then
    echo -n >&2 "Error: SLAPD_SUFFIX not set. "
    echo >&2 "Did you forget to add -e SLAPD_dNSDOMAIN=... ?"
    exit 1
fi

echo "SLAPD_ROOTDN = ${SLAPD_ROOTDN}"
if [[ -z "${SLAPD_ROOTDN}" ]]; then
    echo -n >&2 "Error: SLAPD_ROOTDN not set. "
    echo >&2 "Did you forget to add -e SLAPD_ROOT_USER=... ?"
    exit 1
fi
if [[ -z "${SLAPD_ROOTPW}" ]]; then
	echo -n >&2 "Error: SLAPD_ROOTPW not set. "
	echo >&2 "Did you forget to add -e SLAPD_ROOT_PASSWORD=... ?"
	exit 1
fi

if [[ ! -d "${APP_CONFIG_DIR}/dump" ]]; then
    mkdir -p ${APP_CONFIG_DIR}/dump
    chown -R ldap:ldap ${APP_CONFIG_DIR}
fi

mkdir -p /run/openldap ${DB_DUMP_DIR}

echo "Configuring openldap for v2.3+ style slapd.d config directory..."
install -m 755 -o ldap -g ldap -d ${SLAPD_CONFIG_DIR}
if [[  -f "${SLAPD_DAEMON_CONFIG}"  ]] ; then
    sed -i~ \
        -e 's/^cfgfile=/#cfgfile=/' \
        -e "s~^#cfgdir=.*~cfgdir=\"${SLAPD_CONFIG_DIR}\"~"  ${SLAPD_DAEMON_CONFIG}
fi

if [[  -f "${SLAPD_DEPRECATED_CONFIG}"  ]] ; then
    rm -f ${SLAPD_DEPRECATED_CONFIG}
fi

for i in $(echo '.orig,~1' | tr ',' '\n'); do cp -rvfp ${SLAPD_CONFIG_FILE} ${SLAPD_CONFIG_FILE}$i ;done

echo "Customizing for domain: ${SLAPD_SUFFIX}..."
sed -i~ \
    -e 's/\.la$/\.so/' \
    -e "s/^olcSuffix:.*$/olcSuffix: ${SLAPD_SUFFIX}/" \
    -e "s/^olcRootPW:.*$/olcRootPW: ${SLAPD_ROOTPW}\nolcPasswordHash {PBKDF2-SHA512}/" \
    -e "s/^olcRootDN:.*${SLAPD_SUFFIX}$/olcRootDN: ${SLAPD_ROOTDN}/" ${SLAPD_CONFIG_FILE}~1
sed -i~ "/^olcModuleload:.*back_mdb.*/a olcModuleload:  pw-pbkdf2.so" ${SLAPD_CONFIG_FILE}~1

echo "Adding schema for Linux user accounts..."

awk '{ print } /^include:/ { sub("core", "cosine", $0); print $0;
sub("cosine", "inetorgperson"); print $0;
sub("inetorgperson", "nis"); print  }' ${SLAPD_CONFIG_FILE}~1 >${SLAPD_CONFIG_FILE}
rm ${SLAPD_CONFIG_FILE}~1

# user-provided schemas
if [[ -d "${APP_CONFIG_DIR}/schema" ]] &&  [[ "$(ls -A ${APP_CONFIG_DIR}/schema)" ]]; then
    previous_line=$(sed '/include:/h;g;$!d' ${SLAPD_CONFIG_FILE}|awk -F '/' '{print $NF}')
    for sfile in ${APP_CONFIG_DIR}/schema/* ; do
        case "${sfile}" in
            *.ldif)  echo "ENTRYPOINT CUSTOM SCHEMA: Including ${sfile}";
                    # slapadd -l $l
                    sed -i "~^include:.*${previous_line}.*~a include: file://${sfile//\\/\//}" ${SLAPD_CONFIG_FILE}
                    previous_line=$(basename "${sfile}")
                    ;;
            *)      echo "ENTRYPOINT CUSTOM SCHEMA: ignoring ${sfile} . Only files with extension '.ldif' are supported" ;;
        esac
    done
fi

echo "Importing configuration..."
#awk '/^\s*?$/||!seen[$0]++' ${SLAPD_CONFIG_FILE}
slapadd -n 0 -F ${SLAPD_CONFIG_DIR} -l ${SLAPD_CONFIG_FILE}

cat <<-EOF > "${SLAPD_CONFIG_DIR}/domain.ldif"
dn: ${SLAPD_SUFFIX}
dc: ${SLAPD_DOMAIN}
objectClass: top
objectClass: dcObject
objectClass: organization
o: ${SLAPD_ORGANIZATION}
EOF

slapadd  -n 1 -c -F ${SLAPD_CONFIG_DIR}  -l "${SLAPD_CONFIG_DIR}/domain.ldif"

chown -R ldap:ldap ${SLAPD_CONFIG_DIR}/*

echo "Configuring slapd service..."
install -m 755 -o ldap -g ldap -d /var/lib/openldap/run
# service slapd start
# rc-update add slapd

echo "Starting slapd for first configuration"
slapd -h "ldap:/// ldapi://$(_escurl ${SLAPD_IPC_SOCKET})" -u ldap -g ldap -F ${SLAPD_CONFIG_DIR} -d ${SLAPD_LOG_LEVEL} &
_PID=$!

# handle race condition
echo "Waiting for server ${_PID} to start..."
let i=0
while [[ ${i} -lt 60 ]]; do
    printf "."
    ldapsearch -Y EXTERNAL -H ldapi://$(_escurl ${SLAPD_IPC_SOCKET}) -s base -b '' >/dev/null 2>&1
    #ldapsearch -x -H ldap:/// -s base -b '' >/dev/null 2>&1
    test $? -eq 0 && break
    sleep 1
    let i=`expr ${i} + 1`
done
if [[ $? -eq 0 ]] ; then
    echo "Server running an ready to be configured"
else
    echo "Oops, something went wrong and server may not be properly (pre) configured, check the logs!"
fi
# ssl certs and keys

if [[ -d "${APP_CONFIG_DIR}/certs" ]]  &&  [[ "$(ls -A ${APP_CONFIG_DIR}/certs)" ]]; then
    ROOTCA_CERT_FILE=${APP_CONFIG_DIR}/certs/${ROOTCA_CERT_FILENAME}
    OPENLDAP_SSL_CERT_FILE=${APP_CONFIG_DIR}/certs/${OPENLDAP_CERT_FILENAME}
    OPENLDAP_SSL_KEY_FILE=${APP_CONFIG_DIR}/certs/${OPENLDAP_KEY_FILENAME}

    if [[ -f "${ROOTCA_CERT_FILE}" ]]; then
        mkdir -p /usr/share/ca-certificates/openldap
        mv ${ROOTCA_CERT_FILE} /usr/share/ca-certificates/openldap
        chown -R root:root /usr/share/ca-certificates/openldap
        chmod -R 0755 /usr/share/ca-certificates/openldap
        chmod -R 0644 /usr/share/ca-certificates/openldap/*
        ln -s /usr/share/ca-certificates/openldap/${ROOTCA_CERT_FILENAME} /etc/ssl/certs/ca-cert-openldap_Docker_${ROOTCA_CERT_FILENAME}
        ROOTCA_CERT_FILE=/etc/ssl/certs/ca-cert-Docker_OpenLdap_${ROOTCA_CERT_FILENAME}
# Omit the following clause for olcTLSCACertificateFile
# if you do not have a separate root CA certificate
        cat <<EOF > ${TEMP_FILE}
dn: cn=config
changetype: modify
replace: olcTLSCACertificatePath
olcTLSCACertificatePath: /etc/ssl/certs
-
add: olcTLSCACertificateFile
olcTLSCACertificateFile: ${ROOTCA_CERT_FILE}

EOF
    fi
    if [[ -f "${OPENLDAP_SSL_CERT_FILE}" ]] && [[ -f "${OPENLDAP_SSL_KEY_FILE}" ]] ; then
        mkdir -p /etc/openldap/certs
        mv ${OPENLDAP_SSL_CERT_FILE} "/etc/openldap/certs/${SLAPD_HOSTNAME}.$(basename ${OPENLDAP_SSL_CERT_FILE}|awk -F. '{print $(NF)}')"
        mv ${OPENLDAP_SSL_KEY_FILE} "/etc/openldap/certs/${SLAPD_HOSTNAME}.$(basename ${OPENLDAP_SSL_KEY_FILE}|awk -F. '{print $(NF)}')"
        chown -R ldap:ldap /etc/openldap/certs
        chmod -R 0755 /etc/openldap/certs
        chmod -R 0644 /etc/openldap/certs/*
        OPENLDAP_SSL_CERT_FILE="/etc/openldap/certs/${SLAPD_HOSTNAME}.$(basename ${OPENLDAP_SSL_CERT_FILE}|awk -F. '{print $(NF)}')"
        OPENLDAP_SSL_KEY_FILE="/etc/openldap/certs/${SLAPD_HOSTNAME}.$(basename ${OPENLDAP_SSL_KEY_FILE}|awk -F. '{print $(NF)}')"
        chmod -R 0600 ${OPENLDAP_SSL_KEY_FILE}
    cat <<EOF > ${TEMP_FILE}
dn: cn=config
changetype: modify
replace: olcTLSCertificateFile
olcTLSCertificateFile: ${OPENLDAP_SSL_CERT_FILE}
-
replace: olcTLSCertificateKeyFile
olcTLSCertificateKeyFile: ${OPENLDAP_SSL_KEY_FILE}
-
add: olcTLSVerifyClient
olcTLSVerifyClient: demand
-
add: olcTLSCipherSuite
olcTLSCipherSuite: "HIGH:-SSLv2:+SSLv3"

EOF
        TLS_ISACTIVE=0
    fi
    echo "Installing PKI certificates"
    ldapmodify -Y EXTERNAL -H ldapi://$(_escurl ${SLAPD_IPC_SOCKET}) -f ${TEMP_FILE} -c -d "${LDAPADD_DEBUG_LEVEL}"
fi

# begin additional configuration
if [[ -d "${APP_CONFIG_DIR}/config" ]]  &&  [[ "$(ls -A ${APP_CONFIG_DIR}/config)" ]]; then
    echo "Adding additional config from ${APP_CONFIG_DIR}/config/*.ldif"
    for f in ${APP_CONFIG_DIR}/config/*.ldif ; do
        echo "> $f"
        ldapmodify -Y EXTERNAL -H ldapi://$(_escurl ${SLAPD_IPC_SOCKET}) -f $(_envsubst ${f}) -c -d "${LDAPADD_DEBUG_LEVEL}"
    done

    if [[ -d "${APP_CONFIG_DIR}/config/users" ]]  &&  [[ "$(ls -A ${APP_CONFIG_DIR}/config/users)" ]] ; then
        echo "Adding user config from ${APP_CONFIG_DIR}/config/users"
        for f in ${APP_CONFIG_DIR}/config/users/*ldif ; do
            echo "> $f"
            #ldapmodify -x -H ldap://localhost -w ${SLAPD_ROOTPW} -D cn=${SLAPD_ROOT_USER},dc=${SLAPD_dNSDOMAIN},dc=${SLAPD_DOMAIN_TLD} -f $(_envsubst ${f}) -c -d "${LDAPADD_DEBUG_LEVEL}"
            ldapmodify -Y EXTERNAL -H ldapi://$(_escurl ${SLAPD_IPC_SOCKET}) -f $(_envsubst ${f}) -c -d "${LDAPADD_DEBUG_LEVEL}"
        done
    fi
fi  # additional configuration end

echo "stopping server ${_PID}"
kill -SIGTERM ${_PID}
sleep 2

# # restore dump if available
# if [[ -f "${DB_DUMP_FILE}.gz" ]]; then
#     gunzip "${DB_DUMP_FILE}.gz"
# fi
# if [[ -f "${DB_DUMP_FILE}" ]]; then
#     echo "${DB_DUMP_FILE} found, restore DB from file..."
#     slapadd -c -l $(_envsubst ${DB_DUMP_FILE}) -F ${SLAPD_CONFIG_DIR} -d "${SLAPD_LOG_LEVEL}"
#     restore_state=$?
#     echo "restore finished with code ${restore_state}"

# fi

echo "Starting LDAP(s) server..."
case "${TLS_ISACTIVE}" in
    [tT][rR][uU][eE]|0|[Yy]* )
        slapd -h "ldaps:/// ldapi://$(_escurl ${SLAPD_IPC_SOCKET})"  \
        -F ${SLAPD_CONFIG_DIR} \
        -u ldap \
        -g ldap \
        -d "${SLAPD_LOG_LEVEL}"
        ;;
    *)
        slapd -h "ldap:/// ldapi://$(_escurl ${SLAPD_IPC_SOCKET})"  \
        -F ${SLAPD_CONFIG_DIR} \
        -u ldap \
        -g ldap \
        -d "${SLAPD_LOG_LEVEL}"
        ;;
esac

exec "$@"
