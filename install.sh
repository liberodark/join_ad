#!/bin/bash
#
# About: Add AD automatically
# Author: Unknow, liberodark
# License: GNU GPLv3

version="0.0.5"

echo "Welcome on Join AD Script $version"

set -e
set -u

#=================================================
# CHECK ROOT
#=================================================

if [[ $(id -u) -ne 0 ]] ; then echo "Please run as root" ; exit 1 ; fi

#=================================================
# RETRIEVE ARGUMENTS FROM THE MANIFEST AND VAR
#=================================================

DC="YOUR DC"
REALM="DOMAIN"
KRB5_REALM=$(echo "${REALM}" | tr '[:lower:]' '[:upper:]')
DOMAIN_ADMIN_GROUP="domain admins"
PROJECT_ADMIN_GROUP="(prj) administrators"
PROJECT_GROUP=""
DOMAIN_ADMIN=""
distribution=$(cat /etc/*release | grep "PRETTY_NAME" | sed 's/PRETTY_NAME=//g' | sed 's/["]//g' | awk '{print $1}')
repo="YOUR_REPO"

AUTO=0
YESARG=""
INSTALL=1

centos_repo='
[base]
name=CentOS-$releasever - Base
#mirrorlist=http://mirrorlist.centos.org/?release=$releasever&arch=$basearch&repo=os&infra=$infra
baseurl=http://$repo/centos/$releasever/os/$basearch/
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7

#released updates 
[updates]
name=CentOS-$releasever - Updates
#mirrorlist=http://mirrorlist.centos.org/?release=$releasever&arch=$basearch&repo=updates&infra=$infra
baseurl=http://$repo/centos/$releasever/updates/$basearch/
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7

#additional packages that may be useful
[extras]
name=CentOS-$releasever - Extras
#mirrorlist=http://mirrorlist.centos.org/?release=$releasever&arch=$basearch&repo=extras&infra=$infra
baseurl=http://$repo/centos/$releasever/extras/$basearch/
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7

#additional packages that extend functionality of existing packages
[centosplus]
name=CentOS-$releasever - Plus
#mirrorlist=http://mirrorlist.centos.org/?release=$releasever&arch=$basearch&repo=centosplus&infra=$infra
baseurl=http://$repo/centos/$releasever/centosplus/$basearch/
gpgcheck=1
enabled=0
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7'

debian_repo='
deb http://$repo/debian/ jessie main contrib non-free
deb http://$repo/debian-security/ jessie/updates main contrib non-free'

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
     echo "-auto: Do not ask for confirmation before proceeding."
     echo "-h: Show help"
}

if [[ "$distribution" = CentOS || "$distribution" = CentOS || "$distribution" = Red\ Hat || "$distribution" = Fedora || "$distribution" = Suse || "$distribution" = Oracle ]]; then
      #mkdir -p /tmp/backup-repo
      #mv /etc/yum.repos.d/*.repo /tmp/backup-repo/
      #echo -e "$centos_repo" >> /etc/yum.repos.d/myrepo.repo
      #yum update &> /dev/null
      yum install -y kexec-tools yum-utils net-tools openssh-server vim bash-completion krb5-workstation oddjob oddjob-mkhomedir sssd adcli samba-common-tools open-vm-tools realmd &> /dev/null
     
     elif [[ "$distribution" = Debian || "$distribution" = Ubuntu || "$distribution" = Deepin ]]; then
      #mkdir -p /tmp/backup-repo
      #rm /etc/apt/sources.list
      #echo -e "$debian_repo" >> /etc/apt/sources.list
      #apt update &> /dev/null
      apt install -y krb5-workstation oddjob oddjob-mkhomedir sssd adcli samba-common-tools open-vm-tools &> /dev/null
fi

parse_args ()
{
    while [ $# -ne 0 ]
    do
        case "${1}" in
            -noinst)
                INSTALL=0
                ;;
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
                YESARG="-y"
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
        echo "Le domain admin est obligatoire (-da XXX)" >&2
        exit 2
    fi
}

recap ()
{
    echo "Intégration au domaine : '${REALM}'"
    echo "  Contrôleur de domaine : '${DC}'"
    echo "  Domain admin          : '${DOMAIN_ADMIN}'"
    echo "  Domain admin group    : '${DOMAIN_ADMIN_GROUP}'"
    echo "  Domaine Kerberos      : '${KRB5_REALM}'"
    if [ -z "${PROJECT_GROUP}" ]
    then
        echo "  Groupe projet         : '${PROJECT_GROUP}'"
        if [ -z "${PROJECT_ADMIN_GROUP}" ]
        then
            echo "  Groupe admin projet   : '${PROJECT_ADMIN_GROUP}'"
        else
            echo "  Pas d'admin projet"
        fi
    else
        echo "  Pas de projet"
    fi
    
    if [ ${AUTO} -eq 0 ]
    then
        echo "Continuer ? (O/N)"
        read -r OK
        if [ "$OK" = "o" ] || [ "$OK" = "O" ]
        then
            echo "Abandon..." 
            exit 3
        fi
    fi
}

header ()
{
    echo "=== ${1}"
}

parse_args "$@"

if [ "${PROJECT_GROUP}" == "ask" ]
then
    echo "Nom du groupe projet (vide si aucun) : "
    read -r PROJECT_GROUP
    if [ -z "${PROJECT_GROUP}" ]
    then
        PROJECT_ADMIN_GROUP=""
    fi
fi

recap
sync

header "Intérrogation du domaine..."
realm discover "${REALM}"
domainname "${REALM}"

header "Configuration Kerberos..."
# sauvegarde de l'ancien fichier de conf si besoin
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
sync

#header "Authentification du domain admin..."
kinit "${DOMAIN_ADMIN}"

sync

header "Join au domain..."
realm join "${DC}" -U "${DOMAIN_ADMIN}" -v

header "Nom des users sans domaine..."

if grep "^[ \t]*use_fully_qualified_names" "/etc/sssd/sssd.conf" > /dev/null 2>&1
then
    sed -i 's|^\([ \t]*use_fully_qualified_names\).*$|\1 = False|' "/etc/sssd/sssd.conf"
else
    echo 'use_fully_qualified_names = False' >> "/etc/sssd/sssd.conf"
fi
sed -i 's|^\([ \t]*fallback_homedir\).*$|\1 = /home/%d/%u|' "/etc/sssd/sssd.conf"
sync

systemctl restart sssd

header "Autorisation d'accès..."

realm permit -g "${DOMAIN_ADMIN_GROUP}"
if [ -z "${PROJECT_GROUP}" ]
then
    realm permit -g "${PROJECT_GROUP}"
fi

header "Création automatique des homes..."
authconfig --enablemkhomedir --updateall

header "Administrators..."

(
echo '"%'"${DOMAIN_ADMIN_GROUP}"'" ALL=(ALL) ALL'
if [ -z "${PROJECT_ADMIN_GROUP}" ]
then
    echo '"%'${PROJECT_ADMIN_GROUP}'" ALL=(ALL) ALL'
fi
) > /etc/sudoers.d/admins

chmod 600 /etc/sudoers.d/admins
sync
