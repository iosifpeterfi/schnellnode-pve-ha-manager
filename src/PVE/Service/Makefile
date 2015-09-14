SOURCES=pve_ha_lrm.pm

.PHONY: install
install: ${SOURCES}
	install -d -m 0755 ${DESTDIR}${PERLDIR}/PVE/Service
	for i in ${SOURCES}; do install -D -m 0644 $$i ${DESTDIR}${PERLDIR}/PVE/Service/$$i; done
