CFLAGS ?= -O2 -Wall -Wextra

tinyfork: tinyfork.c
	$(CC) $(CFLAGS) -o $@ $<

run: tinyfork
	./tinyfork

clean:
	rm -f tinyfork

.PHONY: run clean
