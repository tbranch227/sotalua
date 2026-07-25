#!/usr/bin/env bash
# Task runner. `make` is not assumed to be installed; this script is the only
# entry point the repo needs.
#
#   ./run.sh setup     fetch a Lua interpreter into .tooling/ if there is none
#   ./run.sh scrape    re-vendor the API docs and regenerate docs/api-index.*
#   ./run.sh build     bundle every plugin into dist/
#   ./run.sh check     parse every bundle with the interpreter
#   ./run.sh test      run the spec suite (optionally: ./run.sh test <pattern>)
#   ./run.sh lint      flag accidental globals in core/ and plugins/
#   ./run.sh install   copy bundles into the game's Lua/ folder
#   ./run.sh all       build + check + lint + test

set -euo pipefail
cd "$(dirname "$0")"
ROOT="$PWD"

lua_bin() {
    if [ -x "$ROOT/.tooling/bin/lua" ]; then
        echo "$ROOT/.tooling/bin/lua"
    elif command -v lua >/dev/null 2>&1; then
        command -v lua
    elif command -v lua5.4 >/dev/null 2>&1; then
        command -v lua5.4
    else
        echo ""
    fi
}

require_lua() {
    LUA="$(lua_bin)"
    if [ -z "$LUA" ]; then
        echo "No Lua interpreter found. Run: ./run.sh setup" >&2
        exit 1
    fi
}

cmd_setup() {
    python3 tools/get_lua.py
}

cmd_scrape() {
    python3 tools/scrape.py
    python3 tools/genindex.py
    # Keep the linter's view of the API in step with the docs it came from.
    python3 tools/genglobals.py
}

cmd_build() {
    python3 tools/build.py "$@"
}

cmd_check() {
    require_lua
    local failed=0
    shopt -s nullglob
    for file in dist/*/*.lua; do
        if "$LUA" -e "assert(loadfile('$file'))" 2>/dev/null; then
            printf 'ok   %s\n' "$file"
        else
            printf 'FAIL %s\n' "$file"
            "$LUA" -e "loadfile('$file')" || true
            "$LUA" -e "local _, err = loadfile('$file'); if err then print(err) end"
            failed=1
        fi
    done
    return $failed
}

cmd_test() {
    require_lua
    "$LUA" tests/run.lua "$@"
}

cmd_lint() {
    require_lua
    local status=0

    # The in-repo check: no accidental globals, every module is a factory.
    "$LUA" tools/lint.lua || status=1

    # luacheck adds what a regex cannot: misspelled Shroud API names, unused
    # locals, shadowing. Optional, because the repo's premise is that a bare
    # interpreter is enough.
    if command -v luacheck >/dev/null 2>&1; then
        [ -f .luacheckrc ] || python3 tools/genglobals.py
        luacheck core plugins tests tools || status=1
    else
        echo "luacheck not installed; skipping static analysis"
        echo "  install it with: sudo apt install -y lua-check"
    fi

    return $status
}

cmd_install() {
    python3 tools/install.py "$@"
}

cmd_all() {
    cmd_build
    cmd_check
    cmd_lint
    cmd_test
}

target="${1:-all}"
shift || true
case "$target" in
    setup)   cmd_setup "$@" ;;
    scrape)  cmd_scrape "$@" ;;
    build)   cmd_build "$@" ;;
    check)   cmd_check "$@" ;;
    test)    cmd_test "$@" ;;
    lint)    cmd_lint "$@" ;;
    install) cmd_install "$@" ;;
    all)     cmd_all "$@" ;;
    *)       sed -n '2,12p' "$0"; exit 1 ;;
esac
