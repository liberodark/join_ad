#! /bin/bash

set -e
set -u

DC="ard03.alyotech.fr"
REALM="alyotech.fr"
KRB5_REALM=$(echo "${REALM}" | tr '[:lower:]' '[:upper:]')
DOMAIN_ADMIN_GROUP="domain admins"
PROJECT_ADMIN_GROUP="(prj) administrateurs"
PROJECT_GROUP=""
DOMAIN_ADMIN=""
distribution=$(cat /etc/*release | grep "PRETTY_NAME" | sed 's/PRETTY_NAME=//g' | sed 's/["]//g' | awk '{print $1}')

AUTO=0
YESARG=""
INSTALL=1

if ! command -v sssd &> /dev/null; then

    if [[ "$distribution" = CentOS || "$distribution" = CentOS || "$distribution" = Red\ Hat || "$distribution" = Fedora || "$distribution" = Suse || "$distribution" = Oracle ]]; then
      yum install -y krb5-workstation oddjob oddjob-mkhomedir sssd adcli samba-common-tools open-vm-tools &> /dev/null

    fi
fi

usage ()
{
    echo "usage : $0 -da DOMAIN_ADMIN [options]"
    echo "  options : "
    echo "      -da  DA      : DÃ©finition de l'administrateur du domaine"
    echo "      -dc  DC      : DÃ©finition du contrÃ´leur de domaine (defaut : ${DC})"
    echo "      -r   REALM   : DÃ©finition du nom de domaine (defaut : ${REALM})"
    echo "      -dag DA_G    : DÃ©finition du groupe d'administrateurs du domaine (defaut : ${DOMAIN_ADMIN_GROUP})"
    echo "      -pg  PROJECT : DÃ©finition du groupe Projet"
    echo "      -pga PA_G    : DÃ©finition du groupe d'administrateurs des projets (defaut : ${PROJECT_ADMIN_GROUP})"
    echo "      -auto        : Ne pas demander confirmation avant de procÃ©der. "
    echo "      -h           : Afficher l'aide"
}

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
    echo "IntÃ©gration au domaine : '${REALM}'"
    echo "  ContrÃ´leur de domaine : '${DC}'"
    echo "  Domain admin          : '${DOMAIN_ADMIN}'"
    echo "  Domain admin group    : '${DOMAIN_ADMIN_GROUP}'"
    echo "  Domaine Kerberos      : '${KRB5_REALM}'"
    if [ ! -z "${PROJECT_GROUP}" ]
    then
        echo "  Groupe projet         : '${PROJECT_GROUP}'"
        if [ ! -z "${PROJECT_ADMIN_GROUP}" ]
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
        if [ "${OK}" != "o" -a "${OK}" != "O" ]
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

#if [ ${INSTALL} -eq 1 ]
#then
#    header "Installation des paquets nÃ©cessaires..."
#    yum install ${YESARG} --nogpgcheck kexec-tools yum-utils net-tools openssh-server realmd oddjob oddjob-mkhomedir sssd adcli samba-common-tools vim bash-completion krb5-workstation
#    sync
#fi

header "IntÃ©rrogation du domaine..."
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

header "Autorisation d'accÃ¨s..."

realm permit -g "${DOMAIN_ADMIN_GROUP}"
if [ ! -z "${PROJECT_GROUP}" ]
then
    realm permit -g "${PROJECT_GROUP}"
fi

header "CrÃ©ation automatique des homes..."
authconfig --enablemkhomedir --updateall

header "Administrateurs..."

(
echo '"%'"${DOMAIN_ADMIN_GROUP}"'" ALL=(ALL) ALL'
if [ ! -z "${PROJECT_ADMIN_GROUP}" ]
then
    echo '"%'${PROJECT_ADMIN_GROUP}'" ALL=(ALL) ALL'
fi
) > /etc/sudoers.d/admins

chmod 600 /etc/sudoers.d/admins
sync
