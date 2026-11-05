PUB_FLAG ?= ''
# Override for VS Code: `make install CODE=code`
CODE ?= codium
VSCE ?= npx --yes @vscode/vsce@3.2.2
# Linux and Windows server binaries are bundled; macOS is not (see server/PATCHED-LSP.md).
# Default is one universal VSIX. Set e.g. TARGET=linux-x64 to mark it platform-specific.
TARGET ?=

build: cleanup
	${VSCE} package $(if ${TARGET},--target ${TARGET})

cleanup:
	find ./ -name 'openscad-language-support-*.vsix' | xargs -r rm

install: build
	${CODE} --install-extension $(shell find ./ -name 'openscad-language-support-*.vsix')

publish: build
	vsce publish ${PUB_FLAG}
	ovsx publish ${PUB_FLAG} $(shell find ./ -name openscad-language-support-*.vsix) -p ${OVSX_TOKEN}

copy_debug_file:
	cp  ../openscad-lsp/target/debug/openscad-lsp ../openscad-lsp/target/release/openscad-lsp

debug: copy_debug_file install