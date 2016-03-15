all:


.PHONY: test
test:
	@echo "-- start regression tests --"
	./test_failover1.pl
	./ha-tester.pl
	./test_fence_config.pl
	@echo "-- end regression tests (success) --"

.PHONY: clean
clean:
	rm -rf *~ test-*/log  test-*/*~ test-*/status \
	fence_cfgs/*.cfg.commands
