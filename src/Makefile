PACKAGE=pve-ha-manager
SIMPACKAGE=pve-ha-simulator

PREFIX=/usr
BINDIR=${PREFIX}/bin
SBINDIR=${PREFIX}/sbin
MANDIR=${PREFIX}/share/man
DOCDIR=${PREFIX}/share/doc/${PACKAGE}
SIMDOCDIR=${PREFIX}/share/doc/${SIMPACKAGE}
PODDIR=${DOCDIR}/pod
MAN1DIR=${MANDIR}/man1/
BASHCOMPLDIR=${PREFIX}/share/bash-completion/completions/
export PERLDIR=${PREFIX}/share/perl5

all: watchdog-mux

%.1.gz: %.1.pod
	rm -f $@
	cat $<|pod2man -n $* -s 1 -r ${VERSION} -c "Proxmox Documentation"|gzip -c9 >$@

pve-ha-crm.1.pod: pve-ha-crm
	perl -I. ./pve-ha-crm printmanpod >$@

pve-ha-lrm.1.pod: pve-ha-lrm
	perl -I. ./pve-ha-lrm printmanpod >$@

ha-manager.1.pod:
	perl -I. -T -e "use PVE::CLI::ha_manager; PVE::CLI::ha_manager->generate_pod_manpage();" >$@.tmp
	mv $@.tmp $@

ha-manager.bash-completion:
	perl -I. -T -e "use PVE::CLI::ha_manager; PVE::CLI::ha_manager->generate_bash_completions();" >$@


watchdog-mux: watchdog-mux.c
	gcc watchdog-mux.c -o watchdog-mux -Wall -Wl,-z,relro $$(pkg-config --libs --cflags libsystemd-daemon)

.PHONY: install
install: watchdog-mux pve-ha-crm pve-ha-lrm ha-manager.1.pod ha-manager.1.gz pve-ha-crm.1.pod pve-ha-crm.1.gz pve-ha-lrm.1.pod pve-ha-lrm.1.gz ha-manager.bash-completion
	perl -I. ./pve-ha-crm verifyapi
	perl -I. ./pve-ha-lrm verifyapi
	perl -I. -T -e "use PVE::CLI::ha_manager; PVE::CLI::ha_manager->verify_api();"
	install -d ${DESTDIR}${SBINDIR}
	install -m 0755 pve-ha-crm ${DESTDIR}${SBINDIR}
	install -m 0755 pve-ha-lrm ${DESTDIR}${SBINDIR}
	install -m 0755 ha-manager ${DESTDIR}${SBINDIR}
	install -m 0755 watchdog-mux ${DESTDIR}${SBINDIR}
	install -m 0644 -D ha-manager.bash-completion ${DESTDIR}${BASHCOMPLDIR}/ha-manager
	make -C PVE install
	install -d ${DESTDIR}/usr/share/man/man1
	install -d ${DESTDIR}${PODDIR}
	install -m 0644 pve-ha-crm.1.gz ${DESTDIR}/usr/share/man/man1/
	install -m 0644 pve-ha-crm.1.pod ${DESTDIR}/${PODDIR}
	install -m 0644 pve-ha-lrm.1.gz ${DESTDIR}/usr/share/man/man1/
	install -m 0644 pve-ha-lrm.1.pod ${DESTDIR}/${PODDIR}
	install -m 0644 ha-manager.1.gz ${DESTDIR}/usr/share/man/man1/
	install -m 0644 ha-manager.1.pod ${DESTDIR}/${PODDIR}

.PHONY: installsim
installsim: pve-ha-simulator
	install -d ${DESTDIR}${SBINDIR}
	install -m 0755 pve-ha-simulator ${DESTDIR}${SBINDIR}
	make -C PVE PERLDIR=${PREFIX}/share/${SIMPACKAGE} installsim

.PHONY: test
test: 
	make -C test test

.PHONY: clean
clean: 	
	make -C test clean
	rm -rf watchdog-mux *.1.pod *.1.gz *.bash-completion
	find . -name '*~' -exec rm {} ';'

.PHONY: distclean
distclean: clean

