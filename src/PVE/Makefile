
.PHONY: install
install:
	install -d -m 0755 ${DESTDIR}${PERLDIR}/PVE
	make -C HA install

.PHONY: installsim
installsim:
	install -d -m 0755 ${DESTDIR}${PERLDIR}/PVE
	make -C HA installsim
