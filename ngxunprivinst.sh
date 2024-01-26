#!/bin/sh
set -e
##
#  This script downloads and extracts nginx-plus and modules packages to 
#  user writable directory, then modify nginx configuration to run from unprivileged user.
#  It also can upgrade existing unprivileged installation, including graceful reload.
#
#  Make sure that you have downloaded Nginx Plus subscription certificate and key.
#  For RPM-based distros, make sure that you have rpm2cpio installed.
##
#  Usage: ./ngxunprivinst.sh fetch -c <cert_file> -k <key_file> [-v <version>]
#         ./ngxunprivinst.sh (install|upgrade) [-y] -p <path> <file> <file> ...
#         ./ngxunprivinst.sh list -c <cert_file> -k <key_file>
#
#    fetch      - download Nginx Plus and modules packages
#                 for current operating system
#    install    - extracts downloaded packages to specific <path>
#    upgrade    - upgrade existing installation in <path>
#    list       - list available versions from repository to install
#
#    cert_file - path to your subscription certificate file
#    key_file  - path to your subscription private key file
#    path      - nginx prefix path
#    version   - nginx package version (default: latest available)
#    -y        - answers "yes" to all questions
##

PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:

NGXUSER=`id -nu`
NGXCERT=
NGXKEY=
NGXPATH=
CURDIR=`pwd`
WGET="wget -q"
REPOURL=
HTTPPORT=8080
FORCE="NO"

about() {
    sed -ne '3,/^##$/p' < $0 | sed 's/#//g'
}
usage() {
    sed -ne '/^#  Usage/,/^##$/p' < $0 | sed 's/#//g'
}
if [ $# -eq 0 ]; then
    about
    usage
    exit 
fi
if ! ( [ x$1 = x'fetch' ] || [ x$1 = x'install' ] || [ x$1 = x'upgrade' ] || [ x$1 = x'list' ]) ; then
    usage
    exit 
else
    ACTION=$1
    shift
fi

args=`getopt c:k:p:v:y $*`

for opt
do
    case "$opt" in
        -c) NGXCERT=$2; shift; shift;;
        -k) NGXKEY=$2;  shift; shift;;
        -p) NGXPATH=$2; shift; shift;;
        -v) VERSION=$2; shift; shift;;
        -y) FORCE="YES"; shift;;
    esac
done

if ( [ "$NGXKEY" = '' ] || [ "$NGXCERT" = '' ] ) && ( [ "$ACTION" = 'fetch' ] || [ "$ACTION" = 'list' ] ) ; then
    echo "-c and -k options are mandatory to fetch/list"
    exit 1
fi

if [ "$NGXPATH" = '' ] && ( [ "$ACTION" = 'install' ] || [ "$ACTION" = 'upgrade' ] ) ; then
    echo "-p option is mandatory for install/upgrade"
    exit
    if ! ( [ -x /usr/bin/dpkg ] || [ -x /usr/bin/rpm2cpio ] ); then
        echo "Please make sure that you have dpkg or rpm2cpio packages installed"
        exit 1
    fi
fi

FILES=$*

if [ -z "$FILES" ]; then
    if [ "$ACTION" = 'install' ] || [ "$ACTION" = 'upgrade' ]; then
        echo "Please specify packages to install or upgrade."
        exit 1
    fi
fi

ARCH=x86_64
[ `uname -m` = "aarch64" ] && ARCH=aarch64

if [ -f /etc/redhat-release ]; then
    RELEASE=`grep -Eo 'release [0-9]{1}' /etc/redhat-release | cut -d' ' -f2`
    REPOURL=https://pkgs.nginx.com/plus/centos/$RELEASE/$ARCH/RPMS/
    DISTRO="RHEL/CentOS"
    SUFFIX="el"
elif [ -f /etc/os-release ] && fgrep SLES /etc/os-release; then
    RELEASE=`grep -Eo 'VERSION="[0-9]{2}' /etc/os-release | cut -d'"' -f2`
    REPOURL=https://pkgs.nginx.com/plus/sles/$RELEASE/$ARCH/RPMS/
    DISTRO="SLES"
    SUFFIX="sles"
elif [ -f /etc/os-release ] && fgrep -q -i amazon /etc/os-release; then
    RELEASE=`grep -Eo 'VERSION=".+"' /etc/os-release | cut -d'"' -f2`
    if [ "$RELEASE" = "2" ]; then
        REPOURL=https://pkgs.nginx.com/plus/amzn2/2/$ARCH/RPMS/
        SUFFIX="amzn2"
    elif [ "$RELEASE" = "2023" ]; then
        REPOURL=https://pkgs.nginx.com/plus/amzn/2023/$ARCH/RPMS/
        SUFFIX="amzn2023"
    else
        REPOURL=https://pkgs.nginx.com/plus/amzn/latest/$ARCH/RPMS/
        SUFFIX="amzn1"
        RELEASE="1"
    fi
    DISTRO="amzn"
elif [ -f /usr/bin/dpkg ]; then
    ARCH=amd64
    [ `uname -m` = "aarch64" ] && ARCH=arm64
    DISTRO=`grep -E "^ID=" /etc/os-release | cut -d '=' -f2 | tr '[:upper:]' '[:lower:]'`
    RELEASE=`grep VERSION_CODENAME /etc/os-release | cut -d '=' -f2`
    REPOURL=https://pkgs.nginx.com/plus/$DISTRO/pool/nginx-plus/n/
elif [ -x /sbin/apk ]; then
    RELEASE=`grep -Eo 'VERSION_ID=[0-9]\.[0-9]{1,2}' /etc/os-release | cut -d'=' -f2`
    REPOURL=https://pkgs.nginx.com/plus/alpine/v$RELEASE/main/$ARCH/
    DISTRO="alpine"
else
    echo "Cannot determine your operating system."
    exit 1
fi
if [ "$ACTION" = 'fetch' ] || [ "$ACTION" = 'list' ]; then
    if [ ! -f $NGXCERT ] || [ ! -f $NGXKEY ]; then
        echo "Check that certificate and key files exist."
        exit 1
    else
        # check that wget is not a part of busybox package
        [ `find $(which wget) -type f | wc -l` -eq 0 ] && echo "Please install wget package." && exit 1
        # lower security level for certificate check
        ldd $(which wget) | grep -q libgnutls || \
            echo "" | openssl s_client -servername pkgs.nginx.com -cert $NGXCERT -key $NGXKEY -connect pkgs.nginx.com:443 >/dev/null 2>&1 || \
            WGET='wget -q --ciphers DEFAULT@SECLEVEL=1'
            if ! $WGET -O /dev/null --certificate=$NGXCERT --private-key=$NGXKEY https://pkgs.nginx.com/plus/ ; then
                echo "Cannot connect to pkgs.nginx.com, please check certificate and key."
                exit 1
            fi
    fi
fi
cleanup() {
    [ -d $TMPDIR ] && rm -rf $TMPDIR
}

ask() {
    echo "$1 {y/N}"
    if [ "$FORCE" != 'YES' ]; then
        read -r a
        if ! ( [ x$a = 'xy' ] || [ x$a = 'xY' ] ); then
            echo "Exiting..."
            cleanup
            exit
        fi
    else
        echo y
    fi
}

fetch() {
    a=$(list | wc -l)
    [ $a -eq 1 ] && echo "OS ($DISTRO $RELEASE $ARCH) is not supported." && exit 1
    if [ "$DISTRO" = 'ubuntu' ] || [ "$DISTRO" = 'debian' ]; then
        if [ -z $VERSION ]; then
            NGXDEB=`$WGET -O- --certificate=$NGXCERT --private-key=$NGXKEY $REPOURL/nginx-plus | cut -d '"' -f2 | egrep 'nginx-plus_[0-9][0-9]' | fgrep $RELEASE | fgrep $ARCH | sort | uniq | tail -1`
        else
            NGXDEB="nginx-plus_${VERSION}~${RELEASE}_${ARCH}.deb"
        fi
        echo "Downloading $NGXDEB..."
        $WGET --certificate=$NGXCERT --private-key=$NGXKEY $REPOURL/nginx-plus/$NGXDEB -O $NGXDEB ||:
        if [ ! -s $NGXDEB ]; then
            echo "Wrong Nginx Plus version!"
            list
            rm $NGXDEB
            cleanup
            exit 1
        fi
        PLUS_RELEASE=$(echo $NGXDEB | grep -Eo '[0-9][0-9]' | head -1)
        MODULES_PATHS=$($WGET --certificate=$NGXCERT --private-key=$NGXKEY $REPOURL -O- | fgrep 'nginx-plus-module' | cut -d '"' -f2)
        for MODPATH in $MODULES_PATHS; do
            MODDEBS=$($WGET --certificate=$NGXCERT --private-key=$NGXKEY $REPOURL/$MODPATH/ -O- | fgrep 'nginx-plus-module' | fgrep deb | fgrep -v dbg | cut -d '"' -f2 | fgrep $RELEASE | fgrep $ARCH | fgrep "_$PLUS_RELEASE") ||:
            for MODDEB in $MODDEBS; do
                echo "Downloading $MODDEB..."
                $WGET --certificate=$NGXCERT --private-key=$NGXKEY $REPOURL/$MODPATH/$MODDEB -O $MODDEB
            done
        done
    elif [ "$DISTRO" = 'alpine' ]; then
        if [ -z $VERSION ]; then
            NGXAPK=`$WGET -O- --certificate=$NGXCERT --private-key=$NGXKEY $REPOURL | cut -d '"' -f2 | egrep 'nginx-plus-[0-9][0-9]' | sort | uniq | tail -1`
        else
            NGXAPK=nginx-plus-$VERSION.apk
        fi
        echo "Downloading $NGXAPK..."
        $WGET --certificate=$NGXCERT --private-key=$NGXKEY $REPOURL/$NGXAPK -O $NGXAPK ||:
        if [ ! -s $NGXAPK ]; then
            echo "Wrong Nginx Plus version!"
            list
            rm $NGXAPK
            cleanup
            exit 1
        fi
        PLUS_RELEASE=$(echo $NGXAPK | grep -Eo '[0-9][0-9]' | head -1)
        MODULES_APKS=$($WGET --certificate=$NGXCERT --private-key=$NGXKEY $REPOURL/ -O- | fgrep nginx-plus-module | fgrep -v debug | fgrep "$PLUS_RELEASE." | cut -d '"' -f2) ||:
        for MODAPK in $MODULES_APKS; do
            echo "Downloading $MODAPK..."
            $WGET --certificate=$NGXCERT --private-key=$NGXKEY $REPOURL/$MODAPK -O $MODAPK
        done
    else
        if [ -z $VERSION ]; then
            NGXRPM=`$WGET -O- --certificate=$NGXCERT --private-key=$NGXKEY $REPOURL | cut -d '"' -f2 | egrep 'nginx-plus-[0-9][0-9]' | sort | uniq | tail -1`
        else
            echo $VERSION | egrep -q '1[567]\-' && [ "$RELEASE" = "7" ] && RELEASE="7_4"
            NGXRPM=nginx-plus-$VERSION.$SUFFIX$RELEASE.ngx.$ARCH.rpm
        fi
        echo "Downloading $NGXRPM..."
        $WGET --certificate=$NGXCERT --private-key=$NGXKEY $REPOURL/$NGXRPM -O $NGXRPM ||:
        if [ ! -s $NGXRPM ]; then
            echo "Wrong Nginx Plus version!"
            list
            rm $NGXRPM
            cleanup
            exit 1
        fi
        PLUS_RELEASE=$(echo $NGXRPM | grep -Eo '[0-9][0-9]' | head -1)
        MODULES_RPMS=$($WGET --certificate=$NGXCERT --private-key=$NGXKEY $REPOURL/ -O- | fgrep nginx-plus-module | fgrep -v debug | fgrep "$PLUS_RELEASE+" | cut -d '"' -f2) ||:
        for MODRPM in $MODULES_RPMS; do
            echo "Downloading $MODRPM..."
            $WGET --certificate=$NGXCERT --private-key=$NGXKEY $REPOURL/$MODRPM -O $MODRPM
        done
    fi
}

prepare() {
    mkdir -p $ABSPATH
    TMPDIR=`mktemp -dq /tmp/nginx-prefix.XXXXXXXX`
    if [ "$DISTRO" = "debian" ] || [ "$DISTRO" = "ubuntu" ]; then
        for PKG in $FILES; do
            dpkg -x $PKG $TMPDIR
        done
    elif [ "$DISTRO" = "alpine" ]; then
        for PKG in $FILES; do
	        tar -C $TMPDIR -xf $PKG
        done
    else
        cp $FILES $TMPDIR/
        for PKG in $FILES; do
            NGXCPIO=${PKG%%.rpm}.cpio
            cd $TMPDIR
            rpm2cpio $PKG > $NGXCPIO
            cpio -id < $NGXCPIO 2>/dev/null
            [ -f $PKG ] && rm -f $PKG
            [ -f $NGXCPIO ] && rm -f $NGXCPIO
        done
    fi
}

check_modules_deps() {
    DEPS_NEEDED="NO"
    for MODULE in `find $ABSPATH/usr/lib*/nginx/modules/ -type f`; do
        echo "Module installed: modules/`basename $MODULE`"
        UNMET=$(ldd $MODULE 2>&1 | grep 'Error loading shared library\|=> not found' | sed -E 's/Error loading shared library (.+):.*/\1/g' | sed -E 's/ => not found//g' | sort | uniq | tr -d ': \t' | tr '\n' ' ')
        if [ ! -z $UNMET ]; then
            echo " >>> Module $MODULE have unmet dependencies: $UNMET" && DEPS_NEEDED="YES"
            UNMET=
        fi
    done
    [ $DEPS_NEEDED = 'YES' ] && echo " >>> You should install necessary packages or export correct LD_LIBRARY_PATH contains these libraries." ||:

}

extract() {
    ABSPATH=$(readlink -f $NGXPATH)
    if [ -d $ABSPATH ]; then
        ask "$ABSPATH already exists. Continue?"
    fi
    prepare
    if [ -x $TMPDIR/usr/sbin/nginx ]; then
        # extract and configure nginx-plus package
        if [ -f $ABSPATH/etc/nginx/nginx.conf ]; then
            OLDVERSION=`$ABSPATH/usr/sbin/nginx -V 2>&1 | head -1 | cut -d' ' -f4`
            ask "Previous installation $OLDVERSION detected in $ABSPATH. Overwrite?"
            echo "Backing up configuration directory..."
            mv $ABSPATH/etc $ABSPATH/etc.`date +'%Y%d%m%H%M%S'`
        fi
        cp -a $TMPDIR/* $ABSPATH/
        sed -i "s|\([ ^t]*access_log[ ^t]*\)/|\1$ABSPATH/|" $ABSPATH/etc/nginx/nginx.conf
        sed -i "s|\([ ^t]*error_log[ ^t]*\)/|\1$ABSPATH/|" $ABSPATH/etc/nginx/nginx.conf
        sed -i "s|\([ ^t]*pid[ ^t]*\)/|\1$ABSPATH/|" $ABSPATH/etc/nginx/nginx.conf
        sed -i "s|\([ ^t]*include[ ^t]*\)/|\1$ABSPATH/|" $ABSPATH/etc/nginx/nginx.conf
        sed -i "s|\([ ^t]*root[ ^t]*\)/|\1$ABSPATH/|" $ABSPATH/etc/nginx/nginx.conf
        sed -i "s|\([ ^t]*user[ ^t]*\)nginx;||" $ABSPATH/etc/nginx/nginx.conf

        sed -i "s|http {|http {\n    client_body_temp_path $ABSPATH/var/cache/nginx/client_temp;|" \
            $ABSPATH/etc/nginx/nginx.conf
        sed -i "s|http {|http {\n    proxy_temp_path       $ABSPATH/var/cache/nginx/proxy_temp_path;|" \
            $ABSPATH/etc/nginx/nginx.conf
        sed -i "s|http {|http {\n    fastcgi_temp_path     $ABSPATH/var/cache/nginx/fastcgi_temp;|" \
            $ABSPATH/etc/nginx/nginx.conf
        sed -i "s|http {|http {\n    uwsgi_temp_path       $ABSPATH/var/cache/nginx/uwsgi_temp;|" \
            $ABSPATH/etc/nginx/nginx.conf
        sed -i "s|http {|http {\n    scgi_temp_path        $ABSPATH/var/cache/nginx/scgi_temp;|" \
            $ABSPATH/etc/nginx/nginx.conf

        sed -i "s|\([ ^t]*access_log[ ^t]*\)/|\1$ABSPATH/|" $ABSPATH/etc/nginx/conf.d/default.conf
        sed -i "s|\([ ^t]*root[ ^t]*\)/|\1$ABSPATH/|" $ABSPATH/etc/nginx/conf.d/default.conf
        sed -i "s|\([ ^t]*listen[ ^t]*\)80|\1$HTTPPORT|" $ABSPATH/etc/nginx/conf.d/default.conf

        mkdir -p $ABSPATH/var/run
        mkdir -p $ABSPATH/var/log/nginx
        mkdir -p $ABSPATH/var/cache/nginx
        [ -d $ABSPATH/etc/logrotate.d ] && rm -rf $ABSPATH/etc/logrotate.d
        cd $ABSPATH/etc/nginx
        ln -sfn ../../usr/lib*/nginx/modules modules
        # check that nginx binary does not have unmet dependencies
        if ! ldd $ABSPATH/usr/sbin/nginx > /dev/null 2>&1; then
            echo "Please install all necessary dependencies to nginx binary" && \
            echo "Use command \"ldd $ABSPATH/usr/sbin/nginx\" to check unmet dependencies." && \
            exit 1
        fi
        TARGETVER=$($ABSPATH/usr/sbin/nginx -v 2>&1 | cut -d '(' -f 2 | cut -d ')' -f 1 | cut -d'-' -f 3 | tr -d 'r')
        if [ $TARGETVER -ge 31 ]; then
            echo "mgmt { uuid_file $ABSPATH/var/lib/nginx/nginx.id; }" >> $ABSPATH/etc/nginx/nginx.conf
        fi
        echo "Installation finished. You may run nginx with this command:"
        if [ $TARGETVER -ge 23 ]; then
            echo "$ABSPATH/usr/sbin/nginx -p $ABSPATH/etc/nginx -c nginx.conf -e $ABSPATH/var/log/nginx/error.log"
        else
            echo "$ABSPATH/usr/sbin/nginx -p $ABSPATH/etc/nginx -c nginx.conf"
            echo "You may safely ignore message about /var/log/nginx/error.log or create this file writable by your user."
        fi
    else
        # extract module only in existing directory
        if [ ! -x $ABSPATH/usr/sbin/nginx ]; then
            echo "Please use existing installation directory or specify nginx-plus package in arguments too."
            exit 1
        else
            cp -a $TMPDIR/* $ABSPATH/
        fi
    fi
    check_modules_deps
}

upgrade() {
    ABSPATH=$(readlink -f $NGXPATH)
    prepare
    if [ -x $TMPDIR/usr/sbin/nginx ]; then
        if [ -f $ABSPATH/etc/nginx/nginx.conf ]; then
            OLDVERSION=`$ABSPATH/usr/sbin/nginx -V 2>&1 | head -1 | cut -d' ' -f4`
            ask "Previous installation $OLDVERSION detected in $ABSPATH. Upgrade?"
        fi
        echo "Upgrading $ABSPATH/usr/sbin/nginx binary..."
        install $TMPDIR/usr/sbin/nginx $ABSPATH/usr/sbin/nginx
        install $TMPDIR/usr/sbin/nginx-debug $ABSPATH/usr/sbin/nginx-debug
        cp -a $TMPDIR/usr/share/* $ABSPATH/usr/share/
        [ -d $TMPDIR/usr/lib/ ] && cp -a $TMPDIR/usr/lib/* $ABSPATH/usr/lib/
        [ -d $TMPDIR/usr/lib64/ ] && cp -a $TMPDIR/usr/lib64/* $ABSPATH/usr/lib64/
        check_modules_deps
        TARGETVER=$($ABSPATH/usr/sbin/nginx -v 2>&1 | cut -d '(' -f 2 | cut -d ')' -f 1 | cut -d'-' -f 3 | tr -d 'r')
        if [ $TARGETVER -ge 31 ]; then
            if ! $ABSPATH/usr/sbin/nginx -p $ABSPATH/etc/nginx -c nginx.conf -T 2>&1 | grep 'uuid_file' | grep -vE '^(.*)#.*uuid_file' >/dev/null; then
                echo "mgmt { uuid_file $ABSPATH/var/lib/nginx/nginx.id; }" >> $ABSPATH/etc/nginx/nginx.conf
            fi
        fi
        echo "Performing binary seamless upgrade..."
        ps x | grep -q '[n]ginx: master process' \
            && kill -s USR2 `cat $ABSPATH/var/run/nginx.pid` \
            && sleep 5 \
            && kill -s WINCH `cat $ABSPATH/var/run/nginx.pid.oldbin` \
            && kill -s QUIT `cat $ABSPATH/var/run/nginx.pid.oldbin`
    else
        echo "No nginx binary found in packages, upgrading modules only..."
        [ -d $TMPDIR/usr/lib/ ] && cp -a $TMPDIR/usr/lib/* $ABSPATH/usr/lib/
        [ -d $TMPDIR/usr/lib64/ ] && cp -a $TMPDIR/usr/lib64/* $ABSPATH/usr/lib64/
        check_modules_deps
        echo "Reloading nginx..."
        ps x | grep -q '[n]ginx: master process' && kill -s HUP `cat $ABSPATH/var/run/nginx.pid`
    fi
}

list() {
    if [ "$DISTRO" = 'ubuntu' ] || [ "$DISTRO" = 'debian' ]; then
        REPOURL=https://pkgs.nginx.com/plus/$DISTRO/pool/nginx-plus/n/nginx-plus
    fi
    echo "Versions available for $DISTRO $RELEASE $ARCH:"
    if [ "$DISTRO" = 'alpine' ] ; then
        $WGET -O- --certificate=$NGXCERT --private-key=$NGXKEY $REPOURL | grep -Eo "nginx-plus-[0-9][0-9]-r[1-9]" | sed 's/nginx-plus-//g' | sort | uniq
    else
    	$WGET -O- --certificate=$NGXCERT --private-key=$NGXKEY $REPOURL | grep -E "nginx-plus[_-][0-9][0-9]-[1-9]" | fgrep $ARCH | fgrep $RELEASE | grep -Eo '[0-9][0-9]-[1-9]' | sort | uniq
    fi
}

case $ACTION in
    fetch)
        fetch
        ;;
    install)
        if [ `ps x | grep -c '[n]ginx: master process'` -eq 0 ]; then
            extract
        else
            echo "Stop running nginx processes or use 'upgrade' script option."
            cleanup
            exit 1
        fi
        ;;
    upgrade)
        upgrade
         ;;
    list)
        list
        ;;
    *) 
        break 
        ;;
esac
cleanup
