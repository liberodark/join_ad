#!/bin/bash
#
# About: Add AD automatically
# Author: Unknow, liberodark
# Thanks : erdnaxeli
# License: GNU GPLv3

version="0.2.0"

echo "Welcome on Join AD Script $version"

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
distribution=$(cat /etc/*release | grep "PRETTY_NAME" | sed 's/PRETTY_NAME=//g' | sed 's/["]//g' | awk '{print $1}')

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
     echo "-h: Show help"
}

clean_cache(){
echo "Clean Cache"
      kdestroy -A
      systemctl stop sssd
      sss_cache -E
      rm -f /var/lib/sss/db/*.ldb
      systemctl start sssd
      authconfig --updateall
}

install_dependencies(){
if [[ "$distribution" = CentOS || "$distribution" = CentOS || "$distribution" = Red\ Hat || "$distribution" = Fedora || "$distribution" = Suse || "$distribution" = Oracle ]]; then
      echo "Install Packages"
      yum install -y kexec-tools yum-utils authconfig net-tools openssh-server krb5-workstation oddjob oddjob-mkhomedir sssd adcli samba-common-tools open-vm-tools realmd &> /dev/null
      clean_cache
      
     elif [[ "$distribution" = Debian || "$distribution" = Ubuntu || "$distribution" = Deepin ]]; then
      echo "Install Packages"
      export DEBIAN_FRONTEND=noninteractive
      apt install -yq packagekit openssh-server realmd krb5-user krb5-config samba samba-common smbclient oddjob oddjob-mkhomedir sssd sssd-tools adcli open-vm-tools &> /dev/null
      clean_cache    
fi
}

install_dependencies

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
}

recap ()
{
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

parse_args "$@"

if [ "${PROJECT_GROUP}" == "ask" ]
then
    echo "Project group name (empty if none) : "
    read -r PROJECT_GROUP
    if [ -z "${PROJECT_GROUP}" ]
    then
        PROJECT_ADMIN_GROUP=""
    fi
fi

recap

echo "Domain query..."
realm discover "${REALM}"
domainname "${REALM}"

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

echo "Admin domain authentication..."
kinit "${DOMAIN_ADMIN}"

echo "Join au domain..."
realm join "${DC}" -U "${DOMAIN_ADMIN}" -v

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
echo test

echo "Access authorization..."

realm permit -g "${DOMAIN_ADMIN_GROUP}"
if [ -z "${PROJECT_GROUP}" ]
then
    realm permit -g "${PROJECT_GROUP}"
fi

echo "Automatic creation of homes..."
run_authconfig(){
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

if ! command -v authselect > /dev/null 2>&1; then
run_authconfig || exit
else
run_authselect || exit
fi

echo "Administrators..."

if [ -n "${PROJECT_ADMIN_GROUP}" ]; then
        echo '"%'"${PROJECT_ADMIN_GROUP}"'" ALL=(ALL) ALL' > /etc/sudoers.d/admins
elif [ -n "${DOMAIN_ADMIN_GROUP}" ]; then
        echo '"%'"${DOMAIN_ADMIN_GROUP}"'" ALL=(ALL) ALL' > /etc/sudoers.d/admins

fi

chmod 600 /etc/sudoers.d/admins
