RELEASE=4.0

VERSION=0.1
PACKAGE=pve-ha-manager
SIMPACKAGE=pve-ha-simulator
PKGREL=1

DESTDIR=
PREFIX=/usr
BINDIR=${PREFIX}/bin
SBINDIR=${PREFIX}/sbin
MANDIR=${PREFIX}/share/man
DOCDIR=${PREFIX}/share/doc/${PACKAGE}
SIMDOCDIR=${PREFIX}/share/doc/${SIMPACKAGE}
PODDIR=${DOCDIR}/pod
MAN1DIR=${MANDIR}/man1/
export PERLDIR=${PREFIX}/share/perl5

#ARCH:=$(shell dpkg-architecture -qDEB_BUILD_ARCH)
ARCH=all
GITVERSION:=$(shell cat .git/refs/heads/master)

DEB=${PACKAGE}_${VERSION}-${PKGREL}_${ARCH}.deb
SIMDEB=${SIMPACKAGE}_${VERSION}-${PKGREL}_${ARCH}.deb


all: ${DEB} ${SIMDEB}

.PHONY: dinstall simdeb
dinstall: deb simdeb
	dpkg -i ${DEB} ${SIMDEB}

%.1.gz: %.1.pod
	rm -f $@
	cat $<|pod2man -n $* -s 1 -r ${VERSION} -c "Proxmox Documentation"|gzip -c9 >$@

pve-ha-crm.1.pod: pve-ha-crm
	perl -I. ./pve-ha-crm printmanpod >$@

pve-ha-lrm.1.pod: pve-ha-lrm
	perl -I. ./pve-ha-lrm printmanpod >$@

.PHONY: install
install: pve-ha-crm pve-ha-lrm pve-ha-crm.1.pod pve-ha-crm.1.gz pve-ha-lrm.1.pod pve-ha-lrm.1.gz
	install -d ${DESTDIR}${SBINDIR}
	install -m 0755 pve-ha-crm ${DESTDIR}${SBINDIR}
	install -m 0755 pve-ha-lrm ${DESTDIR}${SBINDIR}
	make -C PVE install
	install -d ${DESTDIR}/usr/share/man/man1
	install -d ${DESTDIR}${PODDIR}
	install -m 0644 pve-ha-crm.1.gz ${DESTDIR}/usr/share/man/man1/
	install -m 0644 pve-ha-crm.1.pod ${DESTDIR}/${PODDIR}
	install -m 0644 pve-ha-lrm.1.gz ${DESTDIR}/usr/share/man/man1/
	install -m 0644 pve-ha-lrm.1.pod ${DESTDIR}/${PODDIR}

.PHONY: installsim
installsim: pve-ha-simulator
	install -d ${DESTDIR}${SBINDIR}
	install -m 0755 pve-ha-simulator ${DESTDIR}${SBINDIR}
	make -C PVE installsim

.PHONY: simdeb ${SIMDEB}
simdeb ${SIMDEB}:
	rm -rf build
	mkdir build
	make DESTDIR=${CURDIR}/build PERLDIR=${PREFIX}/share/${SIMPACKAGE} installsim
	perl -I. ./pve-ha-crm verifyapi
	perl -I. ./pve-ha-lrm verifyapi
	install -d -m 0755 build/DEBIAN
	sed -e s/@@VERSION@@/${VERSION}/ -e s/@@PKGRELEASE@@/${PKGREL}/ -e s/@@ARCH@@/${ARCH}/ <simcontrol.in >build/DEBIAN/control
	install -D -m 0644 copyright build/${SIMDOCDIR}/copyright
	install -m 0644 changelog.Debian build/${SIMDOCDIR}/
	gzip -9 build/${SIMDOCDIR}/changelog.Debian
	echo "git clone git://git.proxmox.com/git/pve-storage.git\\ngit checkout ${GITVERSION}" > build/${SIMDOCDIR}/SOURCE
	dpkg-deb --build build
	mv build.deb ${SIMDEB}
	rm -rf debian
	lintian ${SIMDEB}

.PHONY: deb ${DEB}
deb ${DEB}:
	rm -rf build
	mkdir build
	make DESTDIR=${CURDIR}/build install
	perl -I. ./pve-ha-crm verifyapi
	perl -I. ./pve-ha-lrm verifyapi
	install -d -m 0755 build/DEBIAN
	sed -e s/@@VERSION@@/${VERSION}/ -e s/@@PKGRELEASE@@/${PKGREL}/ -e s/@@ARCH@@/${ARCH}/ <control.in >build/DEBIAN/control
	install -D -m 0644 copyright build/${DOCDIR}/copyright
	install -m 0644 changelog.Debian build/${DOCDIR}/
	gzip -9 build/${DOCDIR}/changelog.Debian
	echo "git clone git://git.proxmox.com/git/pve-storage.git\\ngit checkout ${GITVERSION}" > build/${DOCDIR}/SOURCE
	dpkg-deb --build build
	mv build.deb ${DEB}
	rm -rf debian
	lintian ${DEB}


.PHONY: test
test: 
	make -C test test

.PHONY: clean
clean: 	
	make -C test clean
	rm -rf build *.deb ${PACKAGE}-*.tar.gz dist *.1.pod *.1.gz
	find . -name '*~' -exec rm {} ';'

.PHONY: distclean
distclean: clean

