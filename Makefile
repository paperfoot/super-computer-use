BIN     := scu
SRC     := $(wildcard src/*.swift)
PREFIX  ?= $(HOME)/.local

.PHONY: all clean install uninstall test conform

all: $(BIN)

$(BIN): $(SRC)
	swiftc -O -o $(BIN) $(SRC)

install: $(BIN)
	@mkdir -p $(PREFIX)/bin
	@cp $(BIN) $(PREFIX)/bin/$(BIN)
	@echo "installed $(PREFIX)/bin/$(BIN)"
	@echo "run '$(BIN) doctor' to check permissions"

uninstall:
	@rm -f $(PREFIX)/bin/$(BIN)

test: $(BIN)
	@./test/regression.sh ./$(BIN)

conform: $(BIN)
	@./conformance/conformance.sh ./$(BIN)

clean:
	@rm -f $(BIN)
