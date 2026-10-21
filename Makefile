.PHONY: build test test-launchd format lint package clean
build:
	./build.sh
test:
	./Scripts/test.sh
test-launchd:
	./Scripts/test-launchd.sh
format:
	./Scripts/format.sh
lint:
	./Scripts/format.sh --check
package:
	./Scripts/package.sh
clean:
	rm -rf build .build dist
