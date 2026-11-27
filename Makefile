SHELL = /bin/sh
.SUFFIXES:

# Identify this Makefile for the help target (frozen before Makefile.local).
THIS_MAKEFILE := $(lastword $(MAKEFILE_LIST))

# Defaults users can override from the command line or Makefile.local.
MIX             ?= mix
BURRITO_TARGET  ?= linux_x86_64
PREFIX          ?= /usr/local
BINDIR          ?= $(PREFIX)/bin
MANPREFIX       ?= $(PREFIX)/share/man
MANDIR          ?= $(MANPREFIX)/man1

# Benchmark inputs. Leave BENCH_REPO empty for the synthetic fixture.
BENCH_REPO      ?=
BENCH_WORKTREES ?= 2
BENCH_DIR       ?=

# Arguments for `make run`.
ARGS            ?=

# Local, unversioned overrides.
-include Makefile.local

# Command-line variables are exported to recipes by default. Zig honours
# DESTDIR/PREFIX and would install the Burrito wrapper outside zig-out/bin,
# which makes Burrito's copy step fail. Make still expands $(DESTDIR) and
# $(PREFIX) in recipes, so install/uninstall keep working.
unexport DESTDIR
unexport PREFIX
unexport BINDIR
unexport MANPREFIX
unexport MANDIR

# Fixed values; not meant to be overridden.
INSTALL         := install
INSTALL_DIR     := $(INSTALL) -d
INSTALL_PROGRAM := $(INSTALL) -m 0755
INSTALL_DATA    := $(INSTALL) -m 0644
LN_S            := ln -s
BINARY          := burrito_out/gitspace_$(BURRITO_TARGET)
MANPAGE         := man/gitspace.1

ifndef VERBOSE
.SILENT:
endif

.PHONY: all build deps test check format format-check lint ci man bench burrito run
.PHONY: install install-man uninstall clean mostlyclean distclean maintainer-clean help

##
## BUILD
## -----

## all                 » default target: compile the project
all: build

## build               » compile with warnings as errors
build: deps
	$(MIX) compile --warnings-as-errors

## deps                » fetch Hex dependencies
deps:
	$(MIX) deps.get

## burrito             » build the standalone binary
burrito: deps
	BURRITO_TARGET=$(BURRITO_TARGET) MIX_ENV=prod $(MIX) release --overwrite

##
## TEST AND QUALITY
## ----------------

## test                » run the test suite
test: build
	$(MIX) test

## check               » GNU alias for the test suite
check: test

## format              » format the source
format:
	$(MIX) format

## format-check        » verify formatting without changing files
format-check:
	$(MIX) format --check-formatted

## lint                » formatting plus warnings-as-errors
lint: format-check build

## ci                  » what CI runs: lint, then tests
ci: lint
	$(MAKE) test
	$(MAKE) man

##
## RUNNING
## -------

## bench               » run benchmarks (BENCH_REPO=, BENCH_WORKTREES=, BENCH_DIR=)
bench:
	@if [ -n "$(BENCH_REPO)" ]; then \
		export GITSPACE_BENCH_REPO="$(BENCH_REPO)"; \
		export GITSPACE_BENCH_WORKTREES="$(BENCH_WORKTREES)"; \
		if [ -n "$(BENCH_DIR)" ]; then export GITSPACE_BENCH_DIR="$(BENCH_DIR)"; fi; \
		$(MIX) run bench/bench.exs; \
	else \
		$(MIX) run bench/bench.exs; \
	fi

## man                 » lint and render the manpage
man:
	@if command -v mandoc >/dev/null 2>&1; then \
		mandoc -Tlint $(MANPAGE); \
	elif command -v groff >/dev/null 2>&1; then \
		groff -man -Tutf8 $(MANPAGE) >/dev/null; \
	else \
		echo "skip manpage check: neither mandoc nor groff is installed"; \
	fi

## run                 » run the dev CLI (ARGS="doctor")
run:
	$(MIX) run -e 'Gitspace.CLI.main(System.argv())' -- $(ARGS)

##
## INSTALL
## -------

## install             » install the binary, the gsp alias and the manpage
install: burrito man
	$(INSTALL_DIR) $(DESTDIR)$(BINDIR)
	$(INSTALL_PROGRAM) $(BINARY) $(DESTDIR)$(BINDIR)/gitspace
	$(LN_S) -f gitspace $(DESTDIR)$(BINDIR)/gsp
	$(INSTALL_DIR) $(DESTDIR)$(MANDIR)
	$(INSTALL_DATA) $(MANPAGE) $(DESTDIR)$(MANDIR)/gitspace.1

## install-man         » install only the manpage
install-man: man
	$(INSTALL_DIR) $(DESTDIR)$(MANDIR)
	$(INSTALL_DATA) $(MANPAGE) $(DESTDIR)$(MANDIR)/gitspace.1

## uninstall           » remove the installed binary, alias and manpage
uninstall:
	rm -f $(DESTDIR)$(BINDIR)/gitspace $(DESTDIR)$(BINDIR)/gsp
	rm -f $(DESTDIR)$(MANDIR)/gitspace.1

##
## CLEANING
## --------

## clean               » remove compiled artifacts and the standalone binary
clean:
	$(MIX) clean
	rm -rf burrito_out

## mostlyclean         » remove compiled project artifacts, keep deps and binary
mostlyclean:
	$(MIX) clean

## distclean           » remove all build output, keep fetched dependencies
distclean: clean
	rm -rf _build

## maintainer-clean    » remove build output and fetched dependencies
maintainer-clean: distclean
	@printf 'WARNING: removing fetched dependencies.\n'
	$(MIX) deps.clean --all

##
## MISC
## ----

## help                » show this help message
help:
	@sed -n -e "s/^## \?\\(.*\\)/\\1/p" "$(THIS_MAKEFILE)"
