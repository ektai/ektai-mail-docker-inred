#!/usr/bin/env bash

# Author: Zhang Huangbin <zhb _at_ iredmail.org>

#---------------------------------------------------------------------
# This file is part of iRedMail, which is an open source mail server
# solution for Red Hat(R) Enterprise Linux, CentOS, Debian and Ubuntu.
#
# iRedMail is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# iRedMail is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with iRedMail.  If not, see <http://www.gnu.org/licenses/>.
#---------------------------------------------------------------------

# -------------------------------------------------------
# ---------------------- Postfix ------------------------
# -------------------------------------------------------

postfix_config_basic()
{
    ECHO_INFO "Configure Postfix (Message Transfer Agent)."

    backup_file ${POSTFIX_FILE_MAIN_CF} ${POSTFIX_FILE_MASTER_CF}

    ECHO_DEBUG "Enable chroot."
    perl -pi -e 's/^(smtp.*inet)(.*)(n)(.*)(n)(.*smtpd)$/${1}${2}${3}${4}-${6}/' ${POSTFIX_FILE_MASTER_CF}

    # Comment out the parameter first to avoid duplicate entries
    perl -pi -e 's/^(inet_protocols*)/#${1}/' ${POSTFIX_FILE_MAIN_CF}
    # Disable IPv6 here since old Cluebringer release doesn't support ipv6.
    postconf -e inet_protocols='ipv4'

    # Do not set virtual_alias_domains.
    perl -pi -e 's/^(virtual_alias_domains*)/#${1}/' ${POSTFIX_FILE_MAIN_CF}
    postconf -e virtual_alias_domains=''

    ECHO_DEBUG "Copy: /etc/{hosts,resolv.conf,localtime,services} -> ${POSTFIX_CHROOT_DIR}/etc/"
    mkdir -p ${POSTFIX_CHROOT_DIR}/etc/ >> ${INSTALL_LOG} 2>&1
    for i in /etc/hosts /etc/resolv.conf /etc/localtime /etc/services; do
        [ -f $i ] && cp ${i} ${POSTFIX_CHROOT_DIR}/etc/
    done

    postconf -e myhostname="${HOSTNAME}"
    postconf -e myorigin="${HOSTNAME}"
    postconf -e mydomain="${HOSTNAME}"

    # Disable the rewriting of the form "user%domain" to "user@domain".
    postconf -e allow_percent_hack='no'
    # Disable the rewriting of "site!user" into "user@site".
    postconf -e swap_bangpath='no'

    postconf -e mydestination="\$myhostname, localhost, localhost.localdomain"

    # Do not notify local user.
    postconf -e biff='no'
    postconf -e inet_interfaces="all"
    postconf -e mynetworks="127.0.0.1"
    postconf -e mynetworks_style="host"
    postconf -e smtpd_data_restrictions='reject_unauth_pipelining'
    postconf -e smtpd_reject_unlisted_recipient='yes'
    postconf -e smtpd_reject_unlisted_sender='yes'

    # Disable SSLv3
    # Opportunistic TLS
    postconf -e smtpd_tls_protocols='!SSLv2 !SSLv3'
    postconf -e smtp_tls_protocols='!SSLv2 !SSLv3'
    postconf -e lmtp_tls_protocols='!SSLv2 !SSLv3'
    # Mandatory TLS
    postconf -e smtpd_tls_mandatory_protocols='!SSLv2 !SSLv3'
    postconf -e smtp_tls_mandatory_protocols='!SSLv2 !SSLv3'
    postconf -e lmtp_tls_mandatory_protocols='!SSLv2 !SSLv3'
    # Fix 'The Logjam Attack'.
    postconf -e smtpd_tls_mandatory_exclude_ciphers='aNULL, eNULL, EXPORT, DES, RC4, MD5, PSK, aECDH, EDH-DSS-DES-CBC3-SHA, EDH-RSA-DES-CDC3-SHA, KRB5-DE5, CBC3-SHA'
    postconf -e smtpd_tls_dh1024_param_file="${SSL_DHPARAM_FILE}"

    # Opportunistic TLS, used when Postfix sends email to remote SMTP server.
    # Use TLS if this is supported by the remote SMTP server, otherwise use
    # plaintext.
    # References:
    #   - http://www.postfix.org/TLS_README.html#client_tls_may
    #   - http://www.postfix.org/postconf.5.html#smtp_tls_security_level
    postconf -e smtp_tls_security_level='may'
    # Use the same CA file as smtpd.
    postconf -e smtp_tls_CAfile='$smtpd_tls_CAfile'
    postconf -e smtp_tls_loglevel='0'
    postconf -e smtp_tls_note_starttls_offer='yes'

    # Sender restrictions
    postconf -e smtpd_sender_restrictions="reject_unknown_sender_domain, reject_non_fqdn_sender, reject_unlisted_sender, permit_mynetworks, reject_sender_login_mismatch, permit_sasl_authenticated"


    postconf -e delay_warning_time='0h'
    postconf -e maximal_queue_lifetime='4h'
    postconf -e bounce_queue_lifetime='4h'
    postconf -e recipient_delimiter='+'
    postconf -e proxy_read_maps='$canonical_maps $lmtp_generic_maps $local_recipient_maps $mydestination $mynetworks $recipient_bcc_maps $recipient_canonical_maps $relay_domains $relay_recipient_maps $relocated_maps $sender_bcc_maps $sender_canonical_maps $smtp_generic_maps $smtpd_sender_login_maps $transport_maps $virtual_alias_domains $virtual_alias_maps $virtual_mailbox_domains $virtual_mailbox_maps $smtpd_sender_restrictions'

    postconf -e smtp_data_init_timeout='240s'
    postconf -e smtp_data_xfer_timeout='600s'

    # HELO restriction
    postconf -e smtpd_helo_required="yes"
    postconf -e smtpd_helo_restrictions="permit_mynetworks, permit_sasl_authenticated, reject_non_fqdn_helo_hostname, reject_invalid_helo_hostname, check_helo_access pcre:${POSTFIX_FILE_HELO_ACCESS}, reject_unknown_helo_hostname"

    backup_file ${POSTFIX_FILE_HELO_ACCESS}
    cp -f ${SAMPLE_DIR}/postfix/helo_access.pcre ${POSTFIX_FILE_HELO_ACCESS}

    # Reduce queue run delay time.
    postconf -e queue_run_delay='300s'          # default '300s' in postfix-2.4.
    postconf -e minimal_backoff_time='300s'     # default '300s' in postfix-2.4.
    postconf -e maximal_backoff_time='1800s'    # default '4000s' in postfix-2.4.

    # Avoid duplicate recipient messages. Default is 'yes'.
    postconf -e enable_original_recipient='no'

    # Disable the SMTP VRFY command. This stops some techniques used to
    # harvest email addresses.
    postconf -e disable_vrfy_command='yes'

    # We use 'maildir' format, not 'mbox'.
    if [ X"${MAILBOX_FORMAT}" == X"Maildir" ]; then
        postconf -e home_mailbox="Maildir/"
    fi

    postconf -e maximal_backoff_time="4000s"

    # Allow recipient address start with '-'.
    postconf -e allow_min_user='no'

    # Update Postfix aliases file.
    add_postfix_alias nobody ${SYS_ROOT_USER}
    add_postfix_alias ${VMAIL_USER_NAME} ${SYS_ROOT_USER}
    add_postfix_alias ${SYS_ROOT_USER} ${FIRST_USER}@${FIRST_DOMAIN}

    postconf -e alias_maps="hash:${POSTFIX_FILE_ALIASES}"
    postconf -e alias_database="hash:${POSTFIX_FILE_ALIASES}"

    # Set message_size_limit.
    postconf -e message_size_limit="${MESSAGE_SIZE_LIMIT}"
    # Set smtpd_recipient_limit.
    postconf -e smtpd_recipient_limit="${RECIPIENTS_NUMBER}"
    # Virtual support.
    postconf -e virtual_minimum_uid="${VMAIL_USER_UID}"
    postconf -e virtual_uid_maps="static:${VMAIL_USER_UID}"
    postconf -e virtual_gid_maps="static:${VMAIL_USER_GID}"
    postconf -e virtual_mailbox_base="${STORAGE_BASE_DIR}"


    postconf -e smtpd_delay_reject="yes"
    
    if  [ X"${USE_DOCKER}" != X"YES" ]; then
        postconf -e anvil_rate_time_unit="60s"
        postconf -e smtpd_client_message_rate_limit="5"
    fi


    cat >> ${TIP_FILE} <<EOF
Postfix (basic):
    * Configuration files:
        - ${POSTFIX_ROOTDIR}
        - ${POSTFIX_ROOTDIR}/aliases
        - ${POSTFIX_FILE_MAIN_CF}
        - ${POSTFIX_FILE_MASTER_CF}

EOF

    # Create directory, used to store lookup files.
    [ -d ${POSTFIX_LOOKUP_DIR} ] || mkdir -p ${POSTFIX_LOOKUP_DIR}

    echo 'export status_postfix_config_basic="DONE"' >> ${STATUS_FILE}
}

postfix_config_vhost_mysql()
{
    ECHO_DEBUG "Configure Postfix for MySQL lookup."

    postconf -e transport_maps="proxy:mysql:${mysql_transport_maps_user_cf}, proxy:mysql:${mysql_transport_maps_domain_cf}"
    postconf -e virtual_mailbox_domains="proxy:mysql:${mysql_virtual_mailbox_domains_cf}"
    postconf -e virtual_mailbox_maps="proxy:mysql:${mysql_virtual_mailbox_maps_cf}"
    postconf -e virtual_alias_maps="proxy:mysql:${mysql_virtual_alias_maps_cf}, proxy:mysql:${mysql_domain_alias_maps_cf}, proxy:mysql:${mysql_catchall_maps_cf}, proxy:mysql:${mysql_domain_alias_catchall_maps_cf}"
    postconf -e sender_bcc_maps="proxy:mysql:${mysql_sender_bcc_maps_user_cf}, proxy:mysql:${mysql_sender_bcc_maps_domain_cf}"
    postconf -e recipient_bcc_maps="proxy:mysql:${mysql_recipient_bcc_maps_user_cf}, proxy:mysql:${mysql_recipient_bcc_maps_domain_cf}"
    postconf -e relay_domains="\$mydestination, proxy:mysql:${mysql_relay_domains_cf}"
    postconf -e smtpd_sender_login_maps="proxy:mysql:${mysql_sender_login_maps_cf}"

    # Per-domain and per-user transport maps.
    cp ${SAMPLE_DIR}/postfix/mysql/transport_maps_domain.cf ${mysql_transport_maps_domain_cf}
    cp ${SAMPLE_DIR}/postfix/mysql/transport_maps_user.cf ${mysql_transport_maps_user_cf}

    # Virtual domains
    cp ${SAMPLE_DIR}/postfix/mysql/virtual_mailbox_domains.cf ${mysql_virtual_mailbox_domains_cf}
    # Relay domains
    cp ${SAMPLE_DIR}/postfix/mysql/relay_domains.cf ${mysql_relay_domains_cf}
    # Virtual mail users
    cp ${SAMPLE_DIR}/postfix/mysql/virtual_mailbox_maps.cf ${mysql_virtual_mailbox_maps_cf}
    # Virtual alias
    cp ${SAMPLE_DIR}/postfix/mysql/virtual_alias_maps.cf ${mysql_virtual_alias_maps_cf}
    # Alias domain
    cp ${SAMPLE_DIR}/postfix/mysql/domain_alias_maps.cf ${mysql_domain_alias_maps_cf}
    # Catch-all
    cp ${SAMPLE_DIR}/postfix/mysql/catchall_maps.cf ${mysql_catchall_maps_cf}
    # Alias domain support of catch-all
    cp ${SAMPLE_DIR}/postfix/mysql/domain_alias_catchall_maps.cf ${mysql_domain_alias_catchall_maps_cf}
    # Sender login maps
    cp ${SAMPLE_DIR}/postfix/mysql/sender_login_maps.cf ${mysql_sender_login_maps_cf}
    # Sender bcc maps
    cp ${SAMPLE_DIR}/postfix/mysql/sender_bcc_maps_domain.cf ${mysql_sender_bcc_maps_domain_cf}
    cp ${SAMPLE_DIR}/postfix/mysql/sender_bcc_maps_user.cf ${mysql_sender_bcc_maps_user_cf}
    # Recipient bcc maps
    cp ${SAMPLE_DIR}/postfix/mysql/recipient_bcc_maps_domain.cf ${mysql_recipient_bcc_maps_domain_cf}
    cp ${SAMPLE_DIR}/postfix/mysql/recipient_bcc_maps_user.cf ${mysql_recipient_bcc_maps_user_cf}

    ECHO_DEBUG "Set file permission: Owner/Group -> postfix/postfix, Mode -> 0640."
    cat >> ${TIP_FILE} <<EOF
Postfix (MySQL):
    * Configuration files:
EOF

    for i in \
        ${mysql_transport_maps_domain_cf} \
        ${mysql_transport_maps_user_cf} \
        ${mysql_virtual_mailbox_domains_cf} \
        ${mysql_relay_domains_cf} \
        ${mysql_virtual_mailbox_maps_cf} \
        ${mysql_virtual_alias_maps_cf} \
        ${mysql_domain_alias_maps_cf} \
        ${mysql_catchall_maps_cf} \
        ${mysql_domain_alias_catchall_maps_cf} \
        ${mysql_sender_login_maps_cf} \
        ${mysql_sender_bcc_maps_domain_cf} \
        ${mysql_sender_bcc_maps_user_cf} \
        ${mysql_recipient_bcc_maps_domain_cf} \
        ${mysql_recipient_bcc_maps_user_cf}; do

        # Set file owner and permission
        chown ${SYS_ROOT_USER}:${POSTFIX_DAEMON_GROUP} ${i}
        chmod 0640 ${i}

        # Place placeholders
        perl -pi -e 's#^(user * = ).*#${1}$ENV{VMAIL_DB_ADMIN_USER}#' ${i}
        perl -pi -e 's#^(password * = ).*#${1}$ENV{VMAIL_DB_ADMIN_PASSWD}#' ${i}
        perl -pi -e 's#^(hosts * = ).*#${1}$ENV{SQL_SERVER}#' ${i}
        perl -pi -e 's#^(port * = ).*#${1}$ENV{SQL_SERVER_PORT}#' ${i}
        perl -pi -e 's#^(dbname * = ).*#${1}$ENV{VMAIL_DB}#' ${i}

        cat >> ${TIP_FILE} <<EOF
        - $i
EOF
    done

    echo 'export status_postfix_config_vhost_mysql="DONE"' >> ${STATUS_FILE}
}

# Starting config.
postfix_config_virtual_host()
{
    check_status_before_run postfix_config_vhost_mysql

    echo 'export status_postfix_config_virtual_host="DONE"' >> ${STATUS_FILE}
}

postfix_config_sasl()
{
    ECHO_DEBUG "Configure SMTP SASL authentication."

    # For SASL auth
    postconf -e smtpd_sasl_auth_enable="yes"
    postconf -e smtpd_sasl_local_domain=''
    postconf -e broken_sasl_auth_clients="yes"
    postconf -e smtpd_sasl_security_options="noanonymous"

    # Offer SASL authentication only after a TLS-encrypted session has been established
    postconf -e smtpd_tls_auth_only='yes'

    POSTCONF_IREDAPD=''
    if [ X"${USE_IREDAPD}" == X"YES" ]; then
        POSTCONF_IREDAPD="check_policy_service inet:${IREDAPD_BIND_HOST}:${IREDAPD_LISTEN_PORT},"
    fi

    POSTCONF_CLUEBRINGER=''
    if [ X"${USE_CLUEBRINGER}" == X"YES" ]; then
        POSTCONF_CLUEBRINGER="check_policy_service inet:${CLUEBRINGER_BIND_HOST}:${CLUEBRINGER_BIND_PORT},"

        postconf -e smtpd_recipient_restrictions="reject_unknown_sender_domain, reject_unknown_recipient_domain, reject_non_fqdn_sender, reject_non_fqdn_recipient, reject_unlisted_recipient, ${POSTCONF_IREDAPD} ${POSTCONF_CLUEBRINGER} permit_mynetworks, permit_sasl_authenticated, reject_invalid_hostname, reject_unauth_destination, reject_unauth_pipelining, reject_rbl_client b.barracudacentral.org, permit"
        postconf -e smtpd_end_of_data_restrictions="${POSTCONF_IREDAPD} ${POSTCONF_CLUEBRINGER}"

    else
        postconf -e smtpd_recipient_restrictions="reject_unknown_sender_domain, reject_unknown_recipient_domain, reject_non_fqdn_sender, reject_non_fqdn_recipient, reject_unlisted_recipient, ${POSTCONF_IREDAPD} permit_mynetworks, permit_sasl_authenticated, reject_invalid_hostname, reject_unauth_destination, reject_unauth_pipelining, reject_rbl_client b.barracudacentral.org, permit"

    fi

    echo 'export status_postfix_config_sasl="DONE"' >> ${STATUS_FILE}
}

postfix_config_tls()
{
    ECHO_DEBUG "Enable TLS/SSL support in Postfix."

    postconf -e smtp_use_tls='yes'
    postconf -e smtpd_use_tls='yes'
    postconf -e smtpd_tls_received_header='yes'
    
    postconf -e smtpd_tls_security_level='may'
    postconf -e smtpd_tls_loglevel='0'
    postconf -e smtpd_tls_key_file="${SSL_KEY_FILE}"
    postconf -e smtpd_tls_cert_file="${SSL_CERT_FILE}"
    postconf -e smtpd_tls_CAfile="${SSL_CA_BUNDLE_FILE}"
    postconf -e tls_random_source='dev:/dev/urandom'

    cat >> ${POSTFIX_FILE_MASTER_CF} <<EOF
smtps     inet  n       -       n       -       -       smtpd
  -o syslog_name=postfix/smtps
  -o smtpd_tls_wrappermode=yes
  -o smtpd_sasl_auth_enable=yes

submission inet n       -       n       -       -       smtpd
  -o smtpd_tls_security_level=encrypt
  -o smtpd_sasl_auth_enable=yes
  -o smtpd_client_restrictions=permit_mynetworks,permit_sasl_authenticated,reject
#  -o content_filter=smtp-amavis:[${AMAVISD_SERVER}]:10026

EOF

    echo 'export status_postfix_config_tls="DONE"' >> ${STATUS_FILE}
}