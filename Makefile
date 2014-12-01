


all: test


.PHONY: test
test: 
	make -C test test

.PHONY: clean
clean:
	make -C test clean
	rm -rf *~ 

