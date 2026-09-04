CC ?= cc
CFLAGS ?= -std=c11 -Wall -Wextra -O2

.PHONY: all test clean

all: depgraph

depgraph: depgraph.c
	$(CC) $(CFLAGS) -o $@ $<

test: depgraph
	./depgraph_test.sh

clean:
	rm -f depgraph
