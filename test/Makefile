all:


.PHONY: test
test:
	echo "running regression tests"
	./ha-tester.pl
	echo "end regression tests (success)"

.PHONY: clean
clean:
	rm -rf *~ test-*/log  test-*/status
