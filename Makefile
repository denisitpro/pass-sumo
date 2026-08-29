# Thin forwarder: the real Makefile (all target logic + docs) lives in PassSumo/Makefile — the
# app code is meant to be open-sourceable on its own (see PassSumo/CLAUDE.md contract), so it
# carries its own build tooling. This lets `make local`, `make test`, etc. still work from the
# repo root without duplicating any target. Command-line variable assignments (DERIVED_DIR=...)
# propagate to the sub-make automatically — make passes them through MAKEFLAGS whenever it
# re-invokes itself via $(MAKE).

.DEFAULT_GOAL := help

.PHONY: help generate debug release local remove-app remove run test e2e

help generate debug release local remove-app remove run test e2e:
	$(MAKE) -C PassSumo $@
