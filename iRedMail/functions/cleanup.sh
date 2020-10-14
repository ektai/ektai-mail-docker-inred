#!/usr/bin/env bash

# Author:   Zhang Huangbin (zhb _at_ iredmail.org)

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

# Available variables for automate installation (value should be 'y' or 'n'):
#   AUTO_CLEANUP_REMOVE_SENDMAIL
#   AUTO_CLEANUP_REMOVE_MOD_PYTHON
#   AUTO_CLEANUP_REPLACE_FIREWALL_RULES
#   AUTO_CLEANUP_RESTART_IPTABLES
#   AUTO_CLEANUP_REPLACE_MYSQL_CONFIG
#   AUTO_CLEANUP_RESTART_POSTFIX
#
# Usage:
#   # AUTO_CLEANUP_REMOVE_SENDMAIL=y [...] bash iRedMail.sh

# -------------------------------------------
# Misc.
# -------------------------------------------
# Set cron file permission to 0600.
cleanup_set_cron_file_permission()
{
    for user in ${SYS_ROOT_USER} ${AMAVISD_SYS_USER} ${SOGO_DAEMON_USER}; do
        cron_file="${CRON_SPOOL_DIR}/${user}"
        if [ -f ${cron_file} ]; then
            ECHO_DEBUG "Set file permission to 0600: ${cron_file}."
            chmod 0600 ${cron_file}
        fi
    done

    echo 'export status_cleanup_set_cron_file_permission="DONE"' >> ${STATUS_FILE}
}

cleanup_disable_selinux()
{
    ECHO_INFO "Disable SELinux in /etc/selinux/config."
    [ -f /etc/selinux/config ] && perl -pi -e 's#^(SELINUX=)(.*)#${1}disabled#' /etc/selinux/config

    setenforce 0 >> ${INSTALL_LOG} 2>&1

    echo 'export status_cleanup_disable_selinux="DONE"' >> ${STATUS_FILE}
}

cleanup_remove_sendmail()
{
    # Remove sendmail.
    eval ${LIST_ALL_PKGS} | grep 'sendmail' &>/dev/null

    if [ X"$?" == X"0" ]; then
        eval ${remove_pkg} sendmail
    fi

    echo 'export status_cleanup_remove_sendmail="DONE"' >> ${STATUS_FILE}
}

cleanup_remove_mod_python()
{
    # Remove mod_python.
    eval ${LIST_ALL_PKGS} | grep 'mod_python' &>/dev/null

    if [ X"$?" == X"0" ]; then
        ECHO_QUESTION -n "iRedAdmin doesn't work with mod_python, *REMOVE* it now? [Y|n]"
        read_setting ${AUTO_CLEANUP_REMOVE_MOD_PYTHON}
        case $ANSWER in
            N|n ) : ;;
            Y|y|* ) eval ${remove_pkg} mod_python ;;
        esac
    else
        :
    fi

    echo 'export status_cleanup_remove_mod_python="DONE"' >> ${STATUS_FILE}
}

cleanup_replace_firewall_rules()
{
    # Get SSH listen port, replace default port number in iptable rule file.
    export sshd_port="$(grep -s '^Port' ${SSHD_CONFIG} | awk '{print $2}' )"
    if [ X"${sshd_port}" == X"" -o X"${sshd_port}" == X"22" ]; then
        # No port number defined, use default (22).
        export sshd_port='22'
    else
        # Replace port number in iptable, pf and Fail2ban.
        [ X"${USE_FIREWALLD}" == X'YES' ] && \
            perl -pi -e 's#(.*)22(.*)#${1}$ENV{sshd_port}${2}#' ${SAMPLE_DIR}/firewalld/services/ssh.xml


        perl -pi -e 's#(.* )22( .*)#${1}$ENV{sshd_port}${2}#' ${SAMPLE_DIR}/iptables.rules
        perl -pi -e 's#(.*mail_services=.*)ssh( .*)#${1}$ENV{sshd_port}${2}#' ${SAMPLE_DIR}/openbsd/pf.conf

        [ -f ${FAIL2BAN_JAIL_LOCAL_CONF} ] && \
            perl -pi -e 's#(.*port=.*)ssh(.*)#${1}$ENV{sshd_port}${2}#' ${FAIL2BAN_JAIL_LOCAL_CONF}
    fi

    if [ X"${MYSQL_EXTERNAL}" == X"NO" ]; then
        if [ X"${MAIL_DB_EXTERNAL_GRANT_HOST}" != X"" ]; then
            # Replace port number in iptable.
            perl -pi -e 's#(.* )--dport 3306( .*)#${1}-s $ENV{MAIL_DB_EXTERNAL_GRANT_HOST} --dport 3306${2}#' ${SAMPLE_DIR}/iptables.rules
        fi

        if [ X"${SQL_SERVER_PORT}" != X"3306" ]; then
            # Replace port number in iptable.
            perl -pi -e 's#(.* )3306( .*)#${1}$ENV{SQL_SERVER_PORT}${2}#' ${SAMPLE_DIR}/iptables.rules
        fi
    else 
        perl -pi -e 's#(.* )3306( .*)# #' ${SAMPLE_DIR}/iptables.rules
    fi    
    
    iptables-save | sed -n "/*nat/,/COMMIT/p" > ${SAMPLE_DIR}/iptables-nat.rules
    cat ${SAMPLE_DIR}/iptables-nat.rules ${SAMPLE_DIR}/iptables.rules > ${SAMPLE_DIR}/iptables-new.rules
    rm -f ${SAMPLE_DIR}/iptables.rules
    mv ${SAMPLE_DIR}/iptables-new.rules ${SAMPLE_DIR}/iptables.rules
    
    backup_file ${FIREWALL_RULE_CONF}

    ECHO_INFO "Copy firewall sample rules: ${FIREWALL_RULE_CONF}."
    cp -f ${SAMPLE_DIR}/iptables.rules ${FIREWALL_RULE_CONF}

    # Replace HTTP port.
    [ X"${HTTPD_PORT}" != X"80" ]&& \
        perl -pi -e 's#(.*)80(,.*)#${1}$ENV{HTTPD_PORT}${2}#' ${FIREWALL_RULE_CONF}
    
    service_control enable 'iptables' >> ${INSTALL_LOG} 2>&1


    # Prompt to restart iptables.
    ECHO_INFO "Restarting firewall ..."

    ${DIR_RC_SCRIPTS}/iptables restart &>/dev/null      


    # Restarting iptables before restarting fail2ban.
    ENABLED_SERVICES="iptables ${ENABLED_SERVICES}"

    echo 'export status_cleanup_replace_firewall_rules="DONE"' >> ${STATUS_FILE}
}

cleanup_replace_mysql_config()
{
    # Both MySQL and OpenLDAP backend need MySQL database server, so prompt
    # this config file replacement.
    backup_file ${MYSQL_MY_CNF}
    ECHO_INFO "Copy MySQL sample file: ${MYSQL_MY_CNF}."
    cp -f ${SAMPLE_DIR}/mysql/my.cnf ${MYSQL_MY_CNF}

    ECHO_INFO "Enable SSL support for MySQL server."
    perl -pi -e 's/^#(ssl-cert.*=)(.*)/${1} $ENV{SSL_CERT_FILE}/' ${MYSQL_MY_CNF}
    perl -pi -e 's/^#(ssl-key.*=)(.*)/${1} $ENV{SSL_KEY_FILE}/' ${MYSQL_MY_CNF}
    perl -pi -e 's/^#(ssl-cipher.*)/${1}/' ${MYSQL_MY_CNF}

    echo 'export status_cleanup_replace_mysql_config="DONE"' >> ${STATUS_FILE}
}

cleanup_update_compile_spamassassin_rules()
{
    # Required on FreeBSD to start Amavisd-new.
    ECHO_INFO "Updating SpamAssassin rules (sa-update), please wait ..."
    ${BIN_SA_UPDATE} >> ${INSTALL_LOG} 2>&1

    ECHO_INFO "Compiling SpamAssassin rulesets (sa-compile), please wait ..."
    ${BIN_SA_COMPILE} >> ${INSTALL_LOG} 2>&1

    echo 'export status_cleanup_update_compile_spamassassin_rules="DONE"' >> ${STATUS_FILE}
}

cleanup_update_clamav_signatures()
{
    # Update clamav before start clamav-clamd service.
    ECHO_INFO "Updating ClamAV database (freshclam), please wait ..."
    freshclam

    echo 'export status_cleanup_update_clamav_signatures="DONE"' >> ${STATUS_FILE}
}

cleanup_backup_scripts()
{
    [ ! -d ${BACKUP_DIR} ] && mkdir -p ${BACKUP_DIR} &>/dev/null

   
    # Backup MySQL databases
    ECHO_DEBUG "Setup backup script: ${BACKUP_SCRIPT_MYSQL}"

    backup_file ${BACKUP_SCRIPT_MYSQL}
    cp ${TOOLS_DIR}/backup_mysql.sh ${BACKUP_SCRIPT_MYSQL}
    chown ${SYS_ROOT_USER}:${SYS_ROOT_GROUP} ${BACKUP_SCRIPT_MYSQL}
    chmod 0700 ${BACKUP_SCRIPT_MYSQL}

    export MYSQL_ROOT_PASSWD MYSQL_BACKUP_DATABASES
    perl -pi -e 's#^(export BACKUP_ROOTDIR=).*#${1}"$ENV{BACKUP_DIR}"#' ${BACKUP_SCRIPT_MYSQL}
    perl -pi -e 's#^(export MYSQL_USER=).*#${1}"$ENV{MYSQL_ROOT_USER}"#' ${BACKUP_SCRIPT_MYSQL}
    perl -pi -e 's#^(export MYSQL_PASSWD=).*#${1}"$ENV{MYSQL_ROOT_PASSWD}"#' ${BACKUP_SCRIPT_MYSQL}
    perl -pi -e 's#^(export DATABASES=).*#${1}"$ENV{MYSQL_BACKUP_DATABASES}"#' ${BACKUP_SCRIPT_MYSQL}

    echo 'export status_cleanup_backup_scripts="DONE"' >> ${STATUS_FILE}
}


cleanup()
{
    cat > /etc/${PROG_NAME_LOWERCASE}-release <<EOF
${PROG_VERSION}
EOF

    rm -f ${MYSQL_DEFAULTS_FILE_ROOT} &>/dev/null

    cat <<EOF

*************************************************************************
* ${PROG_NAME}-${PROG_VERSION} installation and configuration complete.
*************************************************************************

EOF

    ECHO_DEBUG "Mail sensitive administration info to ${tip_recipient}."
    tip_recipient="${FIRST_USER}@${FIRST_DOMAIN}"
    FILE_IREDMAIL_INSTALLATION_DETAILS="${FIRST_USER_MAILDIR_INBOX}/details.eml"
    FILE_IREDMAIL_LINKS="${FIRST_USER_MAILDIR_INBOX}/links.eml"

    cat > ${FILE_IREDMAIL_INSTALLATION_DETAILS} <<EOF
From: root@${HOSTNAME}
To: ${tip_recipient}
Subject: Details of this iRedMail installation

EOF

    cat ${TIP_FILE} >> ${FILE_IREDMAIL_INSTALLATION_DETAILS}

    cat > ${FILE_IREDMAIL_LINKS} <<EOF
From: root@${HOSTNAME}
To: ${tip_recipient}
Subject: Useful resources for iRedMail administrator

EOF
    chown -R ${VMAIL_USER_NAME}:${VMAIL_GROUP_NAME} ${FILE_IREDMAIL_INSTALLATION_DETAILS} ${FILE_IREDMAIL_LINKS}
    chmod -R 0700 ${FILE_IREDMAIL_INSTALLATION_DETAILS} ${FILE_IREDMAIL_LINKS}

    check_status_before_run cleanup_set_cron_file_permission
    check_status_before_run cleanup_disable_selinux
    check_status_before_run cleanup_remove_sendmail
    check_status_before_run cleanup_remove_mod_python

    [ X"${KERNEL_NAME}" == X'LINUX' -o X"${KERNEL_NAME}" == X'OPENBSD' ] && \
        check_status_before_run cleanup_replace_firewall_rules

    check_status_before_run cleanup_replace_mysql_config
    check_status_before_run cleanup_backup_scripts

    if  [ X"${CONFIGURATION_ONLY}" != X"YES" ]; then
        check_status_before_run cleanup_update_clamav_signatures
    fi

    cat <<EOF
********************************************************************
* First mail account credential:
*
*   o Username: ${SITE_ADMIN_NAME}
*   o Password: ${SITE_ADMIN_PASSWD}
*
*
********************************************************************
* Congratulations, mail server setup completed successfully. Please
* read below file for more information:
*
*   - ${TIP_FILE}
*
* And it's sent to your mail account ${tip_recipient}.
*
********************* WARNING **************************************
EOF

    echo 'export status_cleanup="DONE"' >> ${STATUS_FILE}
}

