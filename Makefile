# Build wiring for the C helpers (Phase 1). The Swift package builds
# separately with `swift build`; this Makefile is only for the helpers
# and the generated keymap table.
#
#   make helpers        build ledgehost-media into bin/
#   make install-debug  also copy the helpers next to the Swift debug
#                       products (.build/debug/), where ledgehostd
#                       looks for them
#   make keymap         regenerate the keymap tables from
#                       helpers/keymap/hid-usage.tsv (python3)
#
# Development files live in a user-local prefix (the task environment
# documents PKG_CONFIG_PATH=$(DEVPREFIX)/usr/lib/x86_64-linux-gnu/pkgconfig,
# but its .pc files carry prefix=/usr and its .so links are dangling
# relative sonames, so pkg-config's flags do not resolve cleanly).
# What actually works, and what this file uses directly:
#   * headers: $(DEVPREFIX)/usr/include (gstreamer-1.0, glib-2.0, X11)
#     plus the arch glib-2.0 include dir for glibconfig.h
#   * libraries: the system's own runtime SONAMEs in /usr/lib
#     (-l:libfoo.so.N selects them without dev .so links)

DEVPREFIX ?= $(HOME)/tools/devprefix

CC      ?= cc
CFLAGS  ?= -O2 -Wall -Wextra
BIN     := bin
GEN     := helpers/generated

DEVINC := -I$(DEVPREFIX)/usr/include/gstreamer-1.0 \
          -I$(DEVPREFIX)/usr/include/glib-2.0 \
          -I$(DEVPREFIX)/usr/lib/x86_64-linux-gnu/glib-2.0/include \
          -I$(DEVPREFIX)/usr/include
GST_LIBS := -l:libgstapp-1.0.so.0 -l:libgstvideo-1.0.so.0 \
            -l:libgstbase-1.0.so.0 -l:libgstreamer-1.0.so.0 \
            -lgobject-2.0 -lglib-2.0
X11_LIBS := -l:libXtst.so.6 -lX11 -lXext

helpers: $(BIN)/ledgehost-media $(BIN)/ledgehost-input $(BIN)/xquery

$(BIN):
	mkdir -p $(BIN)

$(BIN)/ledgehost-media: helpers/ledgehost-media.c | $(BIN)
	$(CC) $(CFLAGS) $(DEVINC) -o $@ $< $(GST_LIBS)

$(BIN)/ledgehost-input: helpers/ledgehost-input.c $(GEN)/keymap.h | $(BIN)
	$(CC) $(CFLAGS) -Ihelpers -I$(DEVPREFIX)/usr/include -o $@ $< $(X11_LIBS) -lX11

$(BIN)/xquery: helpers/xquery.c | $(BIN)
	$(CC) $(CFLAGS) -o $@ $< -lX11

keymap: $(GEN)/keymap.h Sources/LedgehostCore/Generated/Keymap.swift

$(GEN)/keymap.h Sources/LedgehostCore/Generated/Keymap.swift: \
		helpers/keymap/hid-usage.tsv scripts/gen-keymap.py | $(GEN)
	python3 scripts/gen-keymap.py helpers/keymap/hid-usage.tsv \
		$(GEN)/keymap.h Sources/LedgehostCore/Generated/Keymap.swift

$(GEN):
	mkdir -p $(GEN)

# Regenerate into a temp dir and diff: fails when the committed tables
# no longer match the source tsv.
keymap-check:
	@tmp=$$(mktemp -d) && \
	python3 scripts/gen-keymap.py helpers/keymap/hid-usage.tsv \
		$$tmp/keymap.h $$tmp/Keymap.swift && \
	diff -q $$tmp/keymap.h $(GEN)/keymap.h && \
	diff -q $$tmp/Keymap.swift Sources/LedgehostCore/Generated/Keymap.swift && \
	echo "keymap tables in sync"

install-debug: helpers
	mkdir -p .build/debug
	cp -f $(BIN)/ledgehost-media $(BIN)/ledgehost-input .build/debug/

clean:
	rm -rf $(BIN)

.PHONY: helpers keymap keymap-check install-debug clean
