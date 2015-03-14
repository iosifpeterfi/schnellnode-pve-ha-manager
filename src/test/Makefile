all:


.PHONY: test
test:
	echo "running regression tests"
	./test_failover1.pl
	echo "end regression tests (success)"

# fixme: re-enable ha-tester!
orig_test:
	echo "running regression tests"
	./ha-tester.pl
	echo "end regression tests (success)"

.PHONY: clean
clean:
	rm -rf *~ test-*/log  test-*/*~ test-*/status
