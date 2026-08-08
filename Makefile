APP      := UsageRing
DIST     := dist/$(APP).app
CONTENTS := $(DIST)/Contents

.PHONY: build test app run install uninstall clean

build:
	swift build -c release

test:
	swift test

app: build
	rm -rf dist
	mkdir -p $(CONTENTS)/MacOS $(CONTENTS)/Resources
	cp Resources/Info.plist $(CONTENTS)/Info.plist
	cp "$$(swift build -c release --show-bin-path)/$(APP)" $(CONTENTS)/MacOS/$(APP)
	printf 'APPL????' > $(CONTENTS)/PkgInfo
	codesign --force --sign - $(DIST)
	@echo "Built $(DIST)"

# Run from dist/ without installing.
run: app
	@pkill -x $(APP) 2>/dev/null || true
	open $(DIST)

install: app
	@pkill -x $(APP) 2>/dev/null || true
	rm -rf /Applications/$(APP).app
	cp -R $(DIST) /Applications/$(APP).app
	@# LaunchServices needs a moment to notice the replaced bundle, else -600.
	@sleep 1
	@open /Applications/$(APP).app || (sleep 2; open /Applications/$(APP).app)
	@echo "Installed /Applications/$(APP).app"

uninstall:
	@pkill -x $(APP) 2>/dev/null || true
	rm -rf /Applications/$(APP).app

clean:
	rm -rf .build dist
