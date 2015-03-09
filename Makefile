RELEASE=4.0

VERSION=0.1
PACKAGE=pve-ha-manager
SIMPACKAGE=pve-ha-simulator
PKGREL=1

GITVERSION:=$(shell cat .git/refs/heads/master)

ARCH:=$(shell dpkg-architecture -qDEB_BUILD_ARCH)

DEB=${PACKAGE}_${VERSION}-${PKGREL}_${ARCH}.deb
SIMDEB=${SIMPACKAGE}_${VERSION}-${PKGREL}_all.deb


all: ${DEB} ${SIMDEB}

.PHONY: dinstall simdeb
dinstall: deb simdeb
	dpkg -i ${DEB} ${SIMDEB}


.PHONY: simdeb ${SIMDEB}
simdeb ${SIMDEB}:
	rm -rf build
	mkdir build
	rsync -a src/ build
	rsync -a simdebian/ build/debian
	cp changelog.Debian build/debian/changelog
	echo "git clone git://git.proxmox.com/git/pve-ha-manager.git\\ngit checkout ${GITVERSION}" > build/debian/SOURCE
	cd build; dpkg-buildpackage -rfakeroot -b -us -uc
	lintian ${SIMDEB}

.PHONY: deb ${DEB}
deb ${DEB}:
	rm -rf build
	mkdir build
	rsync -a src/ build
	rsync -a debian/ build/debian
	cp changelog.Debian build/debian/changelog
	echo "git clone git://git.proxmox.com/git/pve-ha-manager.git\\ngit checkout ${GITVERSION}" > build/debian/SOURCE
	cd build; dpkg-buildpackage -rfakeroot -b -us -uc
	lintian ${DEB}

.PHONY: clean
clean:
	rm -rf build *.deb ${PACKAGE}-*.tar.gz *.changes 
	find . -name '*~' -exec rm {} ';'

.PHONY: distclean
distclean: clean

