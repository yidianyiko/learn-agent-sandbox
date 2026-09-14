CFLAGS ?= -O2 -Wall -Wextra

tinysnap: tinysnap.c
	$(CC) $(CFLAGS) -o $@ $<

run: tinysnap
	./tinysnap && ./tinysnap restore

clean:
	rm -f tinysnap snapshot.mem snapshot.cpu

.PHONY: run clean
