PREFIX ?= $(DESTDIR)/usr/share/keyrings

GPGS	:= $(patsubst %,$(PREFIX)/%,$(wildcard *.gpg))

.PHONY : install

keyrings:
	mkdir -p $(PREFIX)

$(PREFIX)/%.gpg: keyrings
	install -p -m 644 $(patsubst $(PREFIX)/%,%,$@) $@

install: $(GPGS)
