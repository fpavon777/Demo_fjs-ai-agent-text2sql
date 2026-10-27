# Build and run the fjs-ai-agent-text2sql demo (database arc_demo, PostgreSQL).
#
#   make            compile the AiAgent module, the program and the form
#   make run        run with GDC (direct mode)
#   make gas        write the GAS connector and start httpdispatch if needed
#   make clean
#
# Needs OPENAI_API_KEY in the environment (it is only used server-side).

# OPENAI_API_KEY is read from .env.local (KEY=value lines) when present
-include .env.local
export OPENAI_API_KEY

FGLDIR  ?= /opt/fourjs/fgl
FGLCOMP ?= fglcomp
FGLFORM ?= fglform
FGLRUN  ?= fglrun

ROOT    := $(CURDIR)
WCDIR   := $(ROOT)/.fglpkg/webcomponents
APP     := arc_text2sql
GAS_PORT ?= 6394
FGLASDIR ?= /opt/fourjs/gas
GAS_APPDIR ?= $(FGLASDIR)/appdata/app
FGLGBCDIR=

LDPATH  = FGLLDPATH="$(ROOT)$${FGLLDPATH:+:$$FGLLDPATH}"
RUNENV  = $(LDPATH) FGLPROFILE="$(ROOT)/fglprofile" FGLIMAGEPATH="$(ROOT)/.fglpkg:$(WCDIR)$${FGLIMAGEPATH:+:$$FGLIMAGEPATH}"

all: com/fourjs/aiagent/AiAgent.42m $(APP).42m $(APP).42f

com/fourjs/aiagent/AiAgent.42m: com/fourjs/aiagent/AiAgent.4gl
	cd com/fourjs/aiagent && $(FGLCOMP) -M AiAgent.4gl

$(APP).42m: $(APP).4gl com/fourjs/aiagent/AiAgent.42m
	$(LDPATH) $(FGLCOMP) -M $(APP).4gl

$(APP).42f: $(APP).per
	$(FGLFORM) -M $(APP).per

run: all
	$(RUNENV) $(FGLRUN) $(APP)

# GAS connector: the OpenAI key is read from the environment at this moment
# and written into the (untracked) .xcf.
gas: all
	@test -n "$$OPENAI_API_KEY" || { echo "OPENAI_API_KEY is not set"; exit 1; }
	@mkdir -p gas
	@sed -e 's|@ROOT@|$(ROOT)|g' -e 's|@WCDIR@|$(WCDIR)|g' -e "s|@KEY@|$$OPENAI_API_KEY|" gas/app.xcf.in > $(GAS_APPDIR)/$(APP).xcf
	@chmod 600 $(GAS_APPDIR)/$(APP).xcf
	@if nc -z localhost $(GAS_PORT) >/dev/null 2>&1; then echo "httpdispatch already listening on :$(GAS_PORT)"; \
	else echo "starting httpdispatch (log: /tmp/$(APP)-httpdispatch.log)"; \
	  ( nohup httpdispatch > /tmp/$(APP)-httpdispatch.log 2>&1 < /dev/null & ); sleep 3; fi
	@echo "GBC: http://localhost:$(GAS_PORT)/ua/r/$(APP)"

clean:
	rm -f *.42m *.42f com/fourjs/aiagent/*.42m

.PHONY: all run gas clean
