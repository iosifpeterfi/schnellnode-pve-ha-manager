
.PHONY: install
install:
	install -d -m 0755 ${DESTDIR}${PERLDIR}/PVE
	make -C HA install
	make -C API2 install
	make -C CLI install
	make -C Service install

.PHONY: installsim
installsim:
	install -d -m 0755 ${DESTDIR}${PERLDIR}/PVE
	make -C HA installsim
