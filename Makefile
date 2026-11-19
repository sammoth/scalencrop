.PHONY: app app-icon run test

app:
	./scripts/build-app.sh

app-icon:
	./scripts/generate-app-icon.sh

run:
	./scripts/run-app.sh

test:
	swift test
