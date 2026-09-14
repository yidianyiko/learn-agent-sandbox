CFLAGS ?= -O2 -Wall -Wextra

tinyvmm: tinyvmm.c
	$(CC) $(CFLAGS) -o $@ $<

run: tinyvmm
	./tinyvmm

clean:
	rm -f tinyvmm

.PHONY: run clean
