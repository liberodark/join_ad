#!/bin/bash -eu
#
# About: Add AD automatically
# Author: Unknow, liberodark
# Thanks : erdnaxeli
# License: GNU GPLv3

VERSION="0.2.8"

echo "Welcome on Join AD Script ${VERSION}"

#=================================================
# CHECK ROOT
#=================================================

if [[ $(id -u) -ne 0 ]] ; then echo "Please run as root" ; exit 1 ; fi

#=================================================
# RETRIEVE ARGUMENTS FROM THE MANIFEST AND VAR
#=================================================

DC=""
REALM=""
KRB5_REALM=$(echo "${REALM}" | tr '[:lower:]' '[:upper:]')
DOMAIN_ADMIN_GROUP=""
PROJECT_ADMIN_GROUP=""
PROJECT_GROUP=""
DOMAIN_ADMIN=""
AUTO=0
DATE=$(date +%Y.%m.%d_%H-%M-%S)
DETECT_OS=$(cat /etc/*release | grep "PRETTY_NAME" | sed 's/PRETTY_NAME=//g' | sed 's/["]//g' | awk '{print $1}')

usage ()
{
     echo "usage: $0 -da DOMAIN_ADMIN [options]"
     echo "options:"
     echo "-da DA: Defining the domain administrator"
     echo "-dc DC: Domain Controller Definition (default: ${DC})"
     echo "-r REALM: Definition of the domain name (default: ${REALM})"
     echo "-dag DA_G: Domain Administrator Group Definition (Default: ${DOMAIN_ADMIN_GROUP})"
     echo "-pg PROJECT: Project Group Definition"
     echo "-pga PA_G: Project Administrators Group Definition (default: ${PROJECT_ADMIN_GROUP})"
     echo "-clean Clean cache & Fix"
     echo "-h: Show help"
}

recap(){
    echo "Integration into the domain : '${REALM}'"
    echo "  Domain controller : '${DC}'"
    echo "  Domain admin          : '${DOMAIN_ADMIN}'"
    echo "  Domain admin group    : '${DOMAIN_ADMIN_GROUP}'"
    echo "  Domaine Kerberos      : '${KRB5_REALM}'"
    if [ -z "${PROJECT_GROUP}" ]
    then
        echo "  Project group         : '${PROJECT_GROUP}'"
        if [ -z "${PROJECT_ADMIN_GROUP}" ]
        then
            echo "  Project admin group   : '${PROJECT_ADMIN_GROUP}'"
        else
            echo "  No project admin"
        fi
    else
        echo "  No project"
    fi
    
    if [ "${AUTO}" -eq 0 ]
    then
        echo "Continue ? (Y/N)"
        read -r OK
        if [ "$OK" = "n" ] || [ "$OK" = "N" ]
        then
            echo "Abord..." 
            exit 3
        fi
    fi
}

run_ask(){
if [ "${PROJECT_GROUP}" == "ask" ]
then
    echo "Project group name (empty if none) : "
    read -r PROJECT_GROUP
    if [ -z "${PROJECT_GROUP}" ]
    then
        PROJECT_ADMIN_GROUP=""
    fi
fi
}

run_kerberos_configuration(){
echo "Kerberos configuration..."
# backup the old conf file if necessary
[ ! -f /etc/krb5.conf.save.join."${REALM}" ] && cp /etc/krb5.conf /etc/krb5.conf.save.join."${REALM}" 

cat << EOF > /etc/krb5.conf
[logging]
    default = FILE:/var/log/krb5libs.log
    kdc = FILE:/var/log/krb5kdc.log
    admin_server = FILE:/var/log/kadmind.log
[libdefaults]
    dns_lookup_realm = false
    ticket_lifetime = 24h
    renew_lifetime = 7d
    forwardable = true
    rdns = false
    default_ccache_name = KEYRING:persistent:%{uid}
    default_realm = ${KRB5_REALM}
[realms]
    ${REALM} = {
        kdc = ${DC}
    }

EOF
}

run_authentication(){
echo "Admin domain authentication..."
kinit "${DOMAIN_ADMIN}"
}

run_realm_join(){
echo "Join domain..."
realm join "${DC}" -U "${DOMAIN_ADMIN}" -v
}

run_configuration(){
echo "Name of users without domain..."
if grep "^[ \t]*use_fully_qualified_names" "/etc/sssd/sssd.conf" > /dev/null 2>&1
then
    sed -i 's|^\([ \t]*use_fully_qualified_names\).*$|\1 = False|' "/etc/sssd/sssd.conf"
else
    echo 'use_fully_qualified_names = False' >> "/etc/sssd/sssd.conf"
fi
sed -i 's|^\([ \t]*fallback_homedir\).*$|\1 = /home/%d/%u|' "/etc/sssd/sssd.conf"

chown root: /etc/sssd/sssd.conf
chmod 600 /etc/sssd/sssd.conf
systemctl restart sssd
}

run_authorization(){
echo "Access authorization..."
realm permit -g "${DOMAIN_ADMIN_GROUP}"
if [ -z "${PROJECT_GROUP}" ]
then
    realm permit -g "${PROJECT_GROUP}"
fi
}

run_authconfig(){
echo "Automatic creation of homes..."
echo "Run authconfig..."
authconfig --enablemkhomedir --updateall
}

run_authselect(){
echo "Run authselect..."
authselect select sssd with-mkhomedir --force
authselect apply-changes
}

authconfig_compatibility(){
echo "Run authselect compatibility..."
authselect check
authselect current --raw
authselect select sssd with-mkhomedir --force
systemctl enable sssd.service
systemctl enable oddjobd.service
systemctl stop oddjobd.service
systemctl start oddjobd.service
}

detect_authselect(){
if ! command -v authselect > /dev/null 2>&1; then
run_authconfig || exit
else
run_authselect || exit
fi
}

pam_mkdir(){
echo "Automatic creation of homes..."
if [ ! -e /usr/share/pam-configs/mkhomedir ]
then
cat << EOF > /usr/share/pam-configs/mkhomedir
Name: Create home directory during login
Default: yes
Priority: 0
Session-Interactive-Only: no
Session-Type: Additional
Session-Final:
        optional        pam_mkhomedir.so
EOF
fi
}

pam_mkdir_new_v1(){
echo "Automatic creation of homes..."
if [ ! -e /usr/share/pam-configs/mkhomedir ]
then
cat << EOF > /usr/share/pam-configs/mkhomedir
Name: activate mkhomedir
Default: yes
Priority: 900
Session-Type: Additional
Session:
        required                        pam_mkhomedir.so umask=0022 skel=/etc/skel
EOF
pam-auth-update
fi
}

pam_mkdir_new_v2(){
echo "Automatic creation of homes..."
if [ ! -e /etc/pam.d/common-session ]
then
echo "session optional pam_mkhomedir.so skel=/etc/skel umask=077" >> /etc/pam.d/common-session
fi
}


pam_ldap(){
echo "LDAP configuration..."
# backup the old conf file if necessary
[ ! -f /etc/pam_ldap.conf.save.join."${REALM}" ] && cp /etc/pam_ldap.conf /etc/pam_ldap.conf.save.join."${REALM}"

echo "What is your server ex : dc=domain,dc=com ?"
read -r domain_name

cat << EOF > /etc/pam_ldap.conf
base ${domain_name}
uri ldapi:///${REALM}
ldap_version 3
#binddn cn=proxyuser,dc=padl,dc=com
# Password is stored in /etc/pam_ldap.secret (mode 600)
rootbinddn cn=${DOMAIN_ADMIN},${domain_name}
#port 389
pam_password crypt
EOF
}

clean_cache(){
echo "Clean Cache & Fix"
      cp -a /etc/sssd/sssd.conf /etc/sssd/sssd.conf.old."${DATE}"
      realm leave -v
      kdestroy -A
      systemctl stop sssd
      sss_cache -E
      rm -f /var/lib/sss/db/*.ldb
      mkdir -p /var/log/sssd
      touch /var/log/sssd/sssd.log
      systemctl start sssd
      # Fix "SSSD couldn't load the configuration database Input/output error"
      #rm -f /usr/lib64/ldb/modules/ldb/paged_results.so
      #detect_authselect
}

install_dependencies(){
if [[ "${DETECT_OS}" = CentOS || "${DETECT_OS}" = CentOS || "${DETECT_OS}" = Red\ Hat || "${DETECT_OS}" = Fedora || "${DETECT_OS}" = Suse || "${DETECT_OS}" = Oracle ]]; then
      echo "Install Packages"
      yum install -y kexec-tools yum-utils authconfig net-tools openssh-server krb5-workstation oddjob oddjob-mkhomedir sssd adcli samba-common-tools realmd &> /dev/null
      
     elif [[ "${DETECT_OS}" = Debian || "${DETECT_OS}" = Ubuntu || "${DETECT_OS}" = Deepin ]]; then
      echo "Install Packages"
      export DEBIAN_FRONTEND=noninteractive
      #V1#apt-get install -yq sudo packagekit openssh-server realmd krb5-user krb5-config samba samba-common smbclient sssd sssd-tools adcli &> /dev/null
      #V2#apt-get install -yq libnss-ldap libpam-ldap ldap-utils nscd &> /dev/null
      apt-get install -yq sudo realmd libnss-sss libpam-sss sssd sssd-tools adcli samba-common-bin oddjob oddjob-mkhomedir packagekit krb5-config krb5-user
fi
}

run_admin_configuration(){
echo "Administrators..."
if [ -n "${PROJECT_ADMIN_GROUP}" ]; then
        echo '"%'"${PROJECT_ADMIN_GROUP}"'" ALL=(ALL) ALL' > /etc/sudoers.d/admins
elif [ -n "${DOMAIN_ADMIN_GROUP}" ]; then
        echo '"%'"${DOMAIN_ADMIN_GROUP}"'" ALL=(ALL) ALL' > /etc/sudoers.d/admins

fi

chmod 600 /etc/sudoers.d/admins
}

run_check_os(){
if [[ "${DETECT_OS}" = CentOS || "${DETECT_OS}" = CentOS || "${DETECT_OS}" = Red\ Hat || "${DETECT_OS}" = Fedora || "${DETECT_OS}" = Suse || "${DETECT_OS}" = Oracle ]]; then
      recap
      run_ask
      install_dependencies
      echo "Domain query..."
      realm discover "${REALM}"
      domainname "${REALM}"
      run_kerberos_configuration
      run_authentication
      run_realm_join
      run_configuration
      run_authorization
      detect_authselect
      run_admin_configuration
      
     elif [[ "${DETECT_OS}" = Debian || "${DETECT_OS}" = Ubuntu || "${DETECT_OS}" = Deepin ]]; then
      recap
      run_ask
      install_dependencies
      echo "Domain query..."
      realm discover "${REALM}"
      domainname "${REALM}"
      run_kerberos_configuration
      run_authentication
      run_realm_join
      run_configuration
      run_authorization
      pam_mkdir_new_v2
      #pam_ldap
      run_admin_configuration
fi
}

parse_args ()
{
    while [ $# -ne 0 ]
    do
        case "${1}" in
            -da)
                shift
                DOMAIN_ADMIN="${1}"
                ;;
            -dc)
                shift
                DC="${1}"
                ;;
            -r)
                shift
                REALM="${1}"
                ;;
            -dag)
                shift
                DOMAIN_ADMIN_GROUP="${1}"
                ;;
            -pg)
                shift
                PROJECT_GROUP="${1}"
                ;;
            -pga)
                shift
                PROJECT_ADMIN_GROUP="${1}"
                ;;
            -auto)
                AUTO=1
                ;;
            -clean)
                shift
                clean_cache
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                echo "Argument invalide : ${1}" >&2
                usage >&2
                exit 1
                ;;
        esac
        shift
    done
    KRB5_REALM=$(echo "${REALM}" | tr '[:lower:]' '[:upper:]')
    if [ -z "${PROJECT_GROUP}" ]
    then
        PROJECT_ADMIN_GROUP=""
    fi
    
    if [ -z "${DOMAIN_ADMIN}" ]
    then
        echo "The admin domain is required (-da XXX)" >&2
        exit 2
    fi
    
    run_check_os
}

parse_args "$@"
