.PHONY: build-cli build-agent build-agent-visionos install clean

DEVICE ?= $(or $(SIMPILOT_DEFAULT_DEVICE),iPhone 17 Pro)
VISION_DEVICE ?= Apple Vision Pro
PORT ?= 8222
INSTALL_DIR ?= /usr/local/bin

build-cli:
	cd cli && swift build -c release

build-agent:
	cd agent && xcodebuild build-for-testing \
		-project AgentApp.xcodeproj \
		-scheme AgentUITests \
		-destination 'platform=iOS Simulator,name=$(DEVICE)' \
		-quiet

build-agent-visionos:
	cd agent && xcodebuild build-for-testing \
		-project AgentApp.xcodeproj \
		-scheme AgentUITests \
		-destination 'platform=visionOS Simulator,name=$(VISION_DEVICE)' \
		-quiet

build: build-cli build-agent

install: build-cli
	cp cli/.build/arm64-apple-macosx/release/simpilot $(INSTALL_DIR)/simpilot
	@echo "Installed simpilot to $(INSTALL_DIR)/simpilot"

clean:
	cd cli && swift package clean
	cd agent && xcodebuild clean -project AgentApp.xcodeproj -scheme AgentUITests -quiet 2>/dev/null || true

agent-start:
	cd agent && xcodebuild test \
		-project AgentApp.xcodeproj \
		-scheme AgentUITests \
		-destination 'platform=iOS Simulator,name=$(DEVICE)' \
		-only-testing:AgentUITests/AgentUITests/testAgent \
		-parallel-testing-enabled NO &
	@echo "Waiting for agent..."
	@for i in $$(seq 1 30); do \
		sleep 2; \
		curl -s http://localhost:$(PORT)/health >/dev/null 2>&1 && echo "Agent ready on port $(PORT)" && exit 0; \
	done; echo "Agent failed to start"

agent-start-visionos:
	cd agent && xcodebuild test \
		-project AgentApp.xcodeproj \
		-scheme AgentUITests \
		-destination 'platform=visionOS Simulator,name=$(VISION_DEVICE)' \
		-only-testing:AgentUITests/AgentUITests/testAgent \
		-parallel-testing-enabled NO &
	@echo "Waiting for agent..."
	@for i in $$(seq 1 30); do \
		sleep 2; \
		curl -s http://localhost:$(PORT)/health >/dev/null 2>&1 && echo "Agent ready on port $(PORT)" && exit 0; \
	done; echo "Agent failed to start"

agent-stop:
	@pkill -f "xcodebuild.*AgentUITests" 2>/dev/null && echo "Agent stopped" || echo "Agent not running"
