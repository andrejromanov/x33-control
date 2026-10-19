APP_NAME   = X33 Control
BUNDLE     = build/$(APP_NAME).app
INSTALL_TO = $(HOME)/Applications
# Sign with the local "X33 Control Dev" certificate when it exists (see `make cert`),
# otherwise ad-hoc. Ad-hoc signatures change on every build, and macOS then
# forgets the Input Monitoring grant.
CERT_NAME  = X33 Control Dev
SIGN_IDENTITY := $(shell security find-identity -v -p codesigning 2>/dev/null | grep -q "$(CERT_NAME)" && echo "$(CERT_NAME)" || echo "-")
SWIFTC     = swiftc
FRAMEWORKS = -framework IOKit -framework AppKit -framework ServiceManagement -framework UserNotifications
SOURCES    = $(wildcard Sources/X33Control/*.swift)
CORE       = $(filter-out Sources/X33Control/main.swift Sources/X33Control/AppDelegate.swift Sources/X33Control/CommandLineTool.swift,$(SOURCES))

.PHONY: build test bundle install run clean cert icon

build: build/X33Control

build/X33Control: $(SOURCES)
	mkdir -p build
	$(SWIFTC) -O -swift-version 5 -target arm64-apple-macosx13.0 $(FRAMEWORKS) $(SOURCES) -o $@

test: $(CORE) Tests/SelfTest/main.swift
	mkdir -p build
	$(SWIFTC) -swift-version 5 -target arm64-apple-macosx13.0 -framework IOKit $(CORE) Tests/SelfTest/main.swift -o build/selftest
	./build/selftest

bundle: build/X33Control Packaging/AppIcon.icns
	rm -rf "$(BUNDLE)"
	mkdir -p "$(BUNDLE)/Contents/MacOS" "$(BUNDLE)/Contents/Resources"
	cp Packaging/AppIcon.icns "$(BUNDLE)/Contents/Resources/AppIcon.icns"
	cp build/X33Control "$(BUNDLE)/Contents/MacOS/X33Control"
	cp Packaging/Info.plist "$(BUNDLE)/Contents/Info.plist"
	codesign --force --sign "$(SIGN_IDENTITY)" "$(BUNDLE)"
	@echo "signed with: $(SIGN_IDENTITY)"

install: bundle
	mkdir -p "$(INSTALL_TO)"
	rm -rf "$(INSTALL_TO)/$(APP_NAME).app"
	cp -R "$(BUNDLE)" "$(INSTALL_TO)/"

run: install
	pkill -x X33Control || true
	open "$(INSTALL_TO)/$(APP_NAME).app"

clean:
	rm -rf .build build

# One-time: create a self-signed code-signing certificate in the login keychain
# so every build keeps the same identity and the Input Monitoring grant sticks.
cert:
	@security find-identity -v -p codesigning | grep -q "$(CERT_NAME)" && echo "certificate already present" && exit 0; \
	tmp=$$(mktemp -d) && cd $$tmp && \
	printf '[req]\ndistinguished_name=dn\nx509_extensions=v3\nprompt=no\n[dn]\nCN=$(CERT_NAME)\n[v3]\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=critical,codeSigning\nsubjectKeyIdentifier=hash\n' > ext.cnf && \
	openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 3650 -config ext.cnf 2>/dev/null && \
	(openssl pkcs12 -export -legacy -inkey key.pem -in cert.pem -out id.p12 -passout pass:x33 -name "$(CERT_NAME)" 2>/dev/null || \
	 openssl pkcs12 -export -inkey key.pem -in cert.pem -out id.p12 -passout pass:x33 -name "$(CERT_NAME)") && \
	security import id.p12 -k ~/Library/Keychains/login.keychain-db -P x33 -T /usr/bin/codesign && \
	security add-trusted-cert -p codeSign -k ~/Library/Keychains/login.keychain-db cert.pem ; \
	rm -rf $$tmp; \
	security find-identity -v -p codesigning | grep "$(CERT_NAME)" || echo "import failed"

# App icon: Packaging/icon.svg -> Packaging/AppIcon.icns (needs rsvg-convert, iconutil)
ICONSET = build/AppIcon.iconset
Packaging/AppIcon.icns: Packaging/icon.svg
	rm -rf $(ICONSET) && mkdir -p $(ICONSET)
	for s in 16 32 128 256 512; do \
	  rsvg-convert -w $$s -h $$s Packaging/icon.svg -o $(ICONSET)/icon_$${s}x$${s}.png; \
	  rsvg-convert -w $$((s*2)) -h $$((s*2)) Packaging/icon.svg -o $(ICONSET)/icon_$${s}x$${s}@2x.png; \
	done
	iconutil -c icns $(ICONSET) -o $@

icon: Packaging/AppIcon.icns
