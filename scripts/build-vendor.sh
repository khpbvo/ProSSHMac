#!/usr/bin/env bash
#
# build-vendor.sh — Build the vendored OpenSSL and libssh from pinned, checksummed sources.
#
# Usage:
#   ./scripts/build-vendor.sh                       # Build into build/vendor/stage/Vendor
#   ./scripts/build-vendor.sh --clean               # Same, after removing everything but the downloads
#   ./scripts/build-vendor.sh --jobs 8              # Parallel jobs (default: hw.ncpu)
#   ./scripts/build-vendor.sh --report DIR OUT      # Only report on a Vendor tree, e.g. today's Vendor/
#
# Output, all under build/vendor/ (git-ignored):
#   stage/Vendor/   the same layout as Vendor/, plus VERSIONS.md. The app links Vendor/, not this.
#   report/         lipo, minos, exported symbols, external imports and header hashes per library
#   logs/           one log per configure, build and install step
#
# Requirements: Xcode (via xcrun), Perl 5, CMake 3.23 or newer. Ninja is used if it's on PATH.
#
# Changing a pin: update the version and its SHA-256 together. Take the checksum from a tarball
# whose signature you have verified against the key below, never from a .sha256 file alone.
#

set -euo pipefail

# ── Pins ───────────────────────────────────────────────────────────────────────

PINNED_ON="2026-10-24"

OPENSSL_VERSION="3.5.9"
OPENSSL_SHA256="603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a"
OPENSSL_URL="https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz"
OPENSSL_SIGNING_KEY="B146 647E 45A7 B339 47AB  226B 2A2C 87D1 6169 2D40 (signing subkey C46E D3F2 CBEF DA1F DAAD  A442 64ED 7B1D CCE7 1CB2)"

LIBSSH_VERSION="0.12.2"
LIBSSH_SHA256="49560f677d96e3706a904ac2de1116e25f3680937d51e5c92198fcba4a1c1e9f"
LIBSSH_URL="https://www.libssh.org/files/${LIBSSH_VERSION%.*}/libssh-${LIBSSH_VERSION}.tar.xz"
LIBSSH_SIGNING_KEY="88A2 28D8 9B07 C2C7 7D0C  7809 03D5 DF8C FDD3 E8E7"

# ── Build options ──────────────────────────────────────────────────────────────

MACOS_MIN="26.0"
ARCHS=(arm64 x86_64)

# Baked into libcrypto as OPENSSLDIR, ENGINESDIR and MODULESDIR. Nothing is ever installed there:
# the install goes through DESTDIR. With no-autoload-config, OpenSSL reads no config file on its own.
OPENSSL_PREFIX="/opt/prosshmac-openssl"
OPENSSL_OPTIONS=(
    no-tests
    no-shared
    no-module
    no-autoload-config
)

# Every option the app depends on is set explicitly, so a change in libssh's defaults can't change
# the feature set. Anything not listed keeps libssh's default. Add a dependency (FIDO2, GSSAPI) here.
LIBSSH_CMAKE_OPTIONS=(
    -DWITH_GCRYPT=OFF
    -DWITH_MBEDTLS=OFF
    -DWITH_GSSAPI=OFF
    -DWITH_FIDO2=OFF
    -DWITH_SERVER=OFF
    -DWITH_ZLIB=ON
    -DWITH_SFTP=ON
    -DWITH_PCAP=ON
    -DWITH_NACL=OFF
    -DWITH_EXAMPLES=OFF
    -DUNIT_TESTING=OFF
    -DCLIENT_TESTING=OFF
    -DBUILD_SHARED_LIBS=OFF
)

# ── Paths ──────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
VENDOR_BUILD="${PROJECT_ROOT}/build/vendor"
DOWNLOADS="${VENDOR_BUILD}/downloads"
SRC="${VENDOR_BUILD}/src"
BUILD="${VENDOR_BUILD}/build"
INSTALL="${VENDOR_BUILD}/install"
STAGE="${VENDOR_BUILD}/stage/Vendor"
REPORT="${VENDOR_BUILD}/report"
LOGS="${VENDOR_BUILD}/logs"

# Library name, then its path inside a Vendor tree. Matches the project's search paths.
VENDOR_LIBS=(
    "libcrypto:OpenSSL/libcrypto.xcframework/macos-arm64_x86_64"
    "libssl:OpenSSL/libssl.xcframework/macos-arm64_x86_64"
    "libssh:libssh/libssh.xcframework/macos-arm64_x86_64"
)

# ── Parse arguments ────────────────────────────────────────────────────────────

SCRIPT_ARGS="$*"
CLEAN=false
JOBS="$(sysctl -n hw.ncpu)"
REPORT_ONLY=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --clean) CLEAN=true; shift ;;
        --jobs) JOBS="${2:?--jobs needs a number}"; shift 2 ;;
        --report)
            REPORT_ONLY=true
            REPORT_VENDOR="${2:?--report needs a Vendor directory and an output directory}"
            REPORT_OUT="${3:?--report needs a Vendor directory and an output directory}"
            shift 3 ;;
        -h|--help) sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ── Helpers ────────────────────────────────────────────────────────────────────

info()  { echo "==> $*"; }
warn()  { echo "WARNING: $*" >&2; }
error() { echo "ERROR: $*" >&2; exit 1; }

relative() { echo "${1#"${PROJECT_ROOT}"/}"; }

# Runs one step with its output in logs/<name>.log and prints its time. The step runs as a
# background job so that `set -e` still applies inside it: bash ignores -e in any function
# called from an `if`, `||` or `!` context, which would let a failing configure carry on.
run_step() {
    local name="$1"; shift
    local log="${LOGS}/${name}.log"
    local start=$SECONDS
    local status=0
    echo "==> ${name}"
    "$@" >"$log" 2>&1 &
    wait $! || status=$?
    if [[ $status -ne 0 ]]; then
        tail -n 50 "$log" >&2
        error "${name} failed with status ${status} (log: $(relative "$log"))"
    fi
    echo "    $(( SECONDS - start ))s"
}

verify_sha256() {
    local file="$1" expected="$2"
    local actual
    actual="$(shasum -a 256 "$file" | awk '{print $1}')"
    if [[ "$actual" != "$expected" ]]; then
        error "Checksum mismatch for $(relative "$file"): expected ${expected}, got ${actual}. Nothing was built. Delete the file to download it again."
    fi
}

# A cached tarball is verified again on every run.
fetch() {
    local url="$1" sha256="$2" dest="$3"
    if [[ -f "$dest" ]]; then
        info "Verifying $(relative "$dest")"
        verify_sha256 "$dest" "$sha256"
        return
    fi
    info "Downloading ${url}"
    curl -fL --proto '=https' --tlsv1.2 --retry 3 --silent --show-error -o "${dest}.part" "$url"
    verify_sha256 "${dest}.part" "$sha256"
    mv "${dest}.part" "$dest"
}

openssl_root() { echo "${INSTALL}/openssl-$1${OPENSSL_PREFIX}"; }

# ── Environment ────────────────────────────────────────────────────────────────

# OpenSSL's Configure lets CFLAGS replace its own defaults (-O3 -Wall), which is how the
# previous build ended up unoptimized. Nothing from the caller's environment reaches a compiler.
unset CFLAGS CXXFLAGS CPPFLAGS LDFLAGS LDLIBS CC CXX CPP AR RANLIB CROSS_COMPILE
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
CC="$(xcrun --sdk macosx -f clang)"
export SDKROOT CC
export MACOSX_DEPLOYMENT_TARGET="$MACOS_MIN"

# ── Report ─────────────────────────────────────────────────────────────────────

# Symbols the SDK's libSystem (with its sub-libraries) and zlib export, for checking imports.
# ___dso_handle is synthesized by the linker for each image.
sdk_symbols() {
    {
        cat "${SDKROOT}/usr/lib/libSystem.B.tbd" "${SDKROOT}"/usr/lib/system/*.tbd "${SDKROOT}/usr/lib/libz.tbd" \
            | grep -oE "(^|[][ ,'])_[A-Za-z0-9_\$.]+" | sed -E "s/^[][ ,']//"
        echo "___dso_handle"
    } | sort -u
}

# Writes the report for one Vendor tree. Sets UNRESOLVED_IMPORTS and BUILD_PATHS (counts).
report() {
    local vendor="$1" out="$2"
    rm -rf "$out"
    mkdir -p "$out"

    local entry name dir lib arch paths=()
    for entry in "${VENDOR_LIBS[@]}"; do
        name="${entry%%:*}"
        dir="${vendor}/${entry#*:}"
        lib="${dir}/${name}.a"
        [[ -f "$lib" ]] || error "Missing ${lib}"
        paths+=("$lib")
        {
            echo "archs: $(lipo -archs "$lib" | tr ' ' '\n' | sort | tr '\n' ' ')"
            for arch in "${ARCHS[@]}"; do
                echo "${arch}:"
                otool -arch "$arch" -l "$lib" | awk '$1 == "minos" || $1 == "sdk" { print "  " $1 " " $2 }' | sort | uniq -c
            done
        } >"${out}/${name}.info.txt"
        for arch in "${ARCHS[@]}"; do
            nm -g -arch "$arch" "$lib" 2>/dev/null | awk '$2 == "T" { print $3 }' | sort -u >"${out}/${name}.exports.${arch}.txt"
        done
        (cd "${dir}/Headers" && find . -type f -exec shasum -a 256 {} + | sort -k 2) >"${out}/${name}.headers.txt"
    done

    # Imports: what the three libraries need and none of them defines.
    local sdk
    sdk="$(mktemp)"
    sdk_symbols >"$sdk"
    UNRESOLVED_IMPORTS=0
    for arch in "${ARCHS[@]}"; do
        nm -g -j -U -arch "$arch" "${paths[@]}" 2>/dev/null | grep -v -e ':$' -e '^$' | sort -u >"${out}/defined.${arch}.tmp"
        nm -g -j -u -arch "$arch" "${paths[@]}" 2>/dev/null | grep -v -e ':$' -e '^$' | sort -u \
            | comm -23 - "${out}/defined.${arch}.tmp" >"${out}/imports.${arch}.txt"
        rm "${out}/defined.${arch}.tmp"
        comm -23 "${out}/imports.${arch}.txt" "$sdk" >"${out}/imports-not-in-sdk.${arch}.txt"
        UNRESOLVED_IMPORTS=$(( UNRESOLVED_IMPORTS + $(wc -l <"${out}/imports-not-in-sdk.${arch}.txt") ))
    done
    rm "$sdk"

    # Build-machine paths baked into the binaries.
    local p
    : >"${out}/build-paths.txt"
    for p in "${paths[@]}"; do
        strings -a "$p" | grep -F -e "/Users/" -e "$VENDOR_BUILD" | sed "s|^|$(basename "$p"): |" >>"${out}/build-paths.txt" || true
    done
    BUILD_PATHS="$(wc -l <"${out}/build-paths.txt" | tr -d ' ')"

    info "Report: $(relative "$out")"
    for entry in "${VENDOR_LIBS[@]}"; do
        name="${entry%%:*}"
        printf "    %-10s exports arm64 %5d, x86_64 %5d\n" "$name" \
            "$(wc -l <"${out}/${name}.exports.arm64.txt")" "$(wc -l <"${out}/${name}.exports.x86_64.txt")"
    done
    echo "    imports: arm64 $(wc -l <"${out}/imports.arm64.txt" | tr -d ' '), x86_64 $(wc -l <"${out}/imports.x86_64.txt" | tr -d ' '); not in libSystem or zlib: ${UNRESOLVED_IMPORTS}"
    echo "    build-machine paths in binaries: ${BUILD_PATHS}"
}

if $REPORT_ONLY; then
    report "$(cd "$REPORT_VENDOR" && pwd)" "$REPORT_OUT"
    exit 0
fi

# ── Preflight checks ──────────────────────────────────────────────────────────

for tool in xcrun perl make cmake curl shasum tar lipo nm otool strings; do
    command -v "$tool" >/dev/null || error "${tool} not found. CMake: brew install cmake"
done

CMAKE_VERSION="$(cmake --version | awk 'NR == 1 { print $3 }')"
if [[ "$(printf '%s\n' "3.23" "$CMAKE_VERSION" | sort -V | sed -n 1p)" != "3.23" ]]; then
    error "CMake ${CMAKE_VERSION} is too old: CMAKE_IGNORE_PREFIX_PATH needs 3.23 or newer"
fi

if command -v ninja >/dev/null; then
    CMAKE_GENERATOR="Ninja"
    GENERATOR_VERSION="Ninja $(ninja --version)"
else
    CMAKE_GENERATOR="Unix Makefiles"
    GENERATOR_VERSION="Unix Makefiles"
fi

if $CLEAN; then
    info "Cleaning build/vendor (keeping downloads)"
    rm -rf "$SRC" "$BUILD" "$INSTALL" "${VENDOR_BUILD}/stage" "$REPORT" "$LOGS"
fi
mkdir -p "$DOWNLOADS" "$SRC" "$BUILD" "$INSTALL" "$LOGS"

TOTAL_START=$SECONDS

# ── Sources ────────────────────────────────────────────────────────────────────

OPENSSL_TARBALL="${DOWNLOADS}/openssl-${OPENSSL_VERSION}.tar.gz"
LIBSSH_TARBALL="${DOWNLOADS}/libssh-${LIBSSH_VERSION}.tar.xz"
fetch "$OPENSSL_URL" "$OPENSSL_SHA256" "$OPENSSL_TARBALL"
fetch "$LIBSSH_URL" "$LIBSSH_SHA256" "$LIBSSH_TARBALL"

LIBSSH_SRC="${SRC}/libssh-${LIBSSH_VERSION}"
rm -rf "$LIBSSH_SRC"
tar -xJf "$LIBSSH_TARBALL" -C "$SRC"

# ── OpenSSL ────────────────────────────────────────────────────────────────────

# In-tree build from a fresh extract per arch: OpenSSL's source paths (__FILE__) stay relative.
openssl_configure() {
    local arch="$1"
    local dir="${BUILD}/openssl-${arch}"
    rm -rf "$dir" "${INSTALL}/openssl-${arch}"
    mkdir -p "$dir"
    tar -xzf "$OPENSSL_TARBALL" -C "$dir" --strip-components 1
    cd "$dir"
    ./Configure "darwin64-${arch}-cc" "${OPENSSL_OPTIONS[@]}" \
        "-mmacosx-version-min=${MACOS_MIN}" \
        --prefix="$OPENSSL_PREFIX" \
        --openssldir="${OPENSSL_PREFIX}/ssl" \
        --libdir=lib
    local cflags
    cflags="$(perl configdata.pm -d | grep -E '^ *CFLAGS')"
    echo "$cflags"
    [[ "$cflags" == *-O3* ]] || { echo "Configured CFLAGS lack -O3"; exit 1; }
}

# Only the libraries and headers: the openssl command-line tool isn't needed.
openssl_build() {
    cd "${BUILD}/openssl-$1"
    make -j"$JOBS" build_libs
}

openssl_install() {
    cd "${BUILD}/openssl-$1"
    make install_dev DESTDIR="${INSTALL}/openssl-$1"
}

for arch in "${ARCHS[@]}"; do
    run_step "openssl-${arch}-configure" openssl_configure "$arch"
    run_step "openssl-${arch}-build" openssl_build "$arch"
    run_step "openssl-${arch}-install" openssl_install "$arch"
done

# ── libssh ─────────────────────────────────────────────────────────────────────

# CMake compiles by absolute path, and OpenSSL's allocation macros (OPENSSL_free) pass __FILE__,
# so without the prefix map libssh.a would carry this checkout's path.
libssh_configure() {
    local arch="$1"
    local ossl
    ossl="$(openssl_root "$arch")"
    rm -rf "${BUILD}/libssh-${arch}" "${INSTALL}/libssh-${arch}"
    cmake -S "$LIBSSH_SRC" -B "${BUILD}/libssh-${arch}" -G "$CMAKE_GENERATOR" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_FLAGS="-ffile-prefix-map=${VENDOR_BUILD}=build/vendor" \
        -DCMAKE_OSX_ARCHITECTURES="$arch" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOS_MIN" \
        -DCMAKE_OSX_SYSROOT="$SDKROOT" \
        -DCMAKE_INSTALL_PREFIX="${INSTALL}/libssh-${arch}" \
        -DCMAKE_IGNORE_PREFIX_PATH="/opt/homebrew;/usr/local;/opt/local" \
        -DOPENSSL_ROOT_DIR="$ossl" \
        -DOPENSSL_INCLUDE_DIR="${ossl}/include" \
        -DOPENSSL_CRYPTO_LIBRARY="${ossl}/lib/libcrypto.a" \
        -DOPENSSL_SSL_LIBRARY="${ossl}/lib/libssl.a" \
        -DOPENSSL_USE_STATIC_LIBS=TRUE \
        "${LIBSSH_CMAKE_OPTIONS[@]}"
}

libssh_build() {
    cmake --build "${BUILD}/libssh-$1" --parallel "$JOBS"
}

libssh_install() {
    cmake --install "${BUILD}/libssh-$1"
}

for arch in "${ARCHS[@]}"; do
    run_step "libssh-${arch}-configure" libssh_configure "$arch"
    run_step "libssh-${arch}-build" libssh_build "$arch"
    run_step "libssh-${arch}-install" libssh_install "$arch"
done

# ── Stage ──────────────────────────────────────────────────────────────────────

info "Staging $(relative "$STAGE")"
rm -rf "${VENDOR_BUILD}/stage"

stage_library() {
    local name="$1" subdir="$2" include_arm64="$3" include_x86_64="$4" lib_arm64="$5" lib_x86_64="$6"
    local dir="${STAGE}/${subdir}"
    diff -r "$include_arm64" "$include_x86_64" >/dev/null \
        || error "${name}: arm64 and x86_64 headers differ ($(relative "$include_arm64") vs $(relative "$include_x86_64"))"
    mkdir -p "$dir"
    lipo -create "$lib_arm64" "$lib_x86_64" -output "${dir}/${name}.a"
    cp -R "$include_arm64" "${dir}/Headers"
}

for entry in "${VENDOR_LIBS[@]}"; do
    name="${entry%%:*}"
    subdir="${entry#*:}"
    case "$name" in
        libssh)
            stage_library "$name" "$subdir" \
                "${INSTALL}/libssh-arm64/include" "${INSTALL}/libssh-x86_64/include" \
                "${INSTALL}/libssh-arm64/lib/${name}.a" "${INSTALL}/libssh-x86_64/lib/${name}.a" ;;
        *)
            stage_library "$name" "$subdir" \
                "$(openssl_root arm64)/include" "$(openssl_root x86_64)/include" \
                "$(openssl_root arm64)/lib/${name}.a" "$(openssl_root x86_64)/lib/${name}.a" ;;
    esac
done

# ── VERSIONS.md ────────────────────────────────────────────────────────────────

COMMIT="$(git -C "$PROJECT_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
if [[ -n "$(git -C "$PROJECT_ROOT" status --porcelain 2>/dev/null)" ]]; then
    COMMIT="${COMMIT} (uncommitted changes)"
fi

{
    cat <<EOF
# Vendored libraries

Generated by \`scripts/build-vendor.sh\`. Don't edit it by hand: change the pins in the script and
rebuild.

| Library | Version | Source | SHA-256 |
|---|---|---|---|
| OpenSSL | ${OPENSSL_VERSION} | ${OPENSSL_URL} | \`${OPENSSL_SHA256}\` |
| libssh | ${LIBSSH_VERSION} | ${LIBSSH_URL} | \`${LIBSSH_SHA256}\` |

Each tarball's signature was verified when its pin was set (${PINNED_ON}):

- OpenSSL: ${OPENSSL_SIGNING_KEY}
- libssh: ${LIBSSH_SIGNING_KEY}

## Build

- Command: \`scripts/build-vendor.sh${SCRIPT_ARGS:+ ${SCRIPT_ARGS}}\`
- Built $(date -u '+%Y-%m-%d %H:%M UTC') from commit ${COMMIT}
- Host: macOS $(sw_vers -productVersion) ($(uname -m))
- $(xcodebuild -version | paste -sd ' ' - | sed 's/ Build version/, build/'), macOS SDK $(xcrun --sdk macosx --show-sdk-version)
- $("$CC" --version | sed -n 1p)
- CMake ${CMAKE_VERSION}, ${GENERATOR_VERSION}
- Architectures: ${ARCHS[*]}, combined with \`lipo\`. Deployment target: macOS ${MACOS_MIN}.

## OpenSSL options

\`\`\`
./Configure darwin64-<arch>-cc ${OPENSSL_OPTIONS[*]} -mmacosx-version-min=${MACOS_MIN} \\
    --prefix=${OPENSSL_PREFIX} --openssldir=${OPENSSL_PREFIX}/ssl --libdir=lib
make build_libs && make install_dev DESTDIR=<staging>
\`\`\`

The prefix is baked into libcrypto (OPENSSLDIR, ENGINESDIR, MODULESDIR) and never exists on disk.
With \`no-autoload-config\`, OpenSSL reads no \`openssl.cnf\` and ignores \`OPENSSL_CONF\` unless the app
loads a config itself.

## libssh CMake options

\`\`\`
EOF
    printf '%s\n' "${LIBSSH_CMAKE_OPTIONS[@]}"
    cat <<EOF
\`\`\`

Every other option keeps libssh's default. zlib is the SDK's \`libz\`; the OpenSSL above is linked
statically.
EOF
} >"${STAGE}/VERSIONS.md"

# ── Report ─────────────────────────────────────────────────────────────────────

report "$STAGE" "$REPORT"
if [[ "$BUILD_PATHS" -ne 0 ]]; then
    error "The staged binaries contain build-machine paths: see $(relative "$REPORT")/build-paths.txt"
fi
if [[ "$UNRESOLVED_IMPORTS" -ne 0 ]]; then
    warn "Some imports are not in libSystem or zlib: see $(relative "$REPORT")/imports-not-in-sdk.*.txt"
fi

info "OpenSSL ${OPENSSL_VERSION} and libssh ${LIBSSH_VERSION} staged in $(relative "$STAGE") in $(( SECONDS - TOTAL_START ))s"
