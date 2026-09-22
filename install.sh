#!/bin/sh -e

# DuckDB Linux/OSX installer script, revision $Id$
# Issues/PRs for this script: https://github.com/duckdb/duckdb-install-scripts

main () {
    OS=$(uname -s)
    ARCH=$(uname -m)

    INSTALL_COMPONENTS="${DUCKDB_INSTALL:-cli}"
    WANT_CLI=false
    WANT_STATIC=false
    WANT_SHARED=false

    case ",${INSTALL_COMPONENTS}," in
        *,,*)
            echo "Invalid DUCKDB_INSTALL value '${INSTALL_COMPONENTS}': components must be a comma-separated list." 1>&2
            exit 1
            ;;
    esac

    REMAINING_COMPONENTS=${INSTALL_COMPONENTS}
    while [ -n "${REMAINING_COMPONENTS}" ]
    do
        case "${REMAINING_COMPONENTS}" in
            *,*)
                COMPONENT=${REMAINING_COMPONENTS%%,*}
                REMAINING_COMPONENTS=${REMAINING_COMPONENTS#*,}
                ;;
            *)
                COMPONENT=${REMAINING_COMPONENTS}
                REMAINING_COMPONENTS=
                ;;
        esac

        case "${COMPONENT}" in
            cli)
                WANT_CLI=true
                ;;
            static)
                WANT_STATIC=true
                ;;
            shared)
                WANT_SHARED=true
                ;;
            *)
                echo "Invalid DUCKDB_INSTALL component '${COMPONENT}'. Expected cli, static, or shared." 1>&2
                exit 1
                ;;
        esac
    done

    command -v curl >/dev/null 2>&1 || { echo >&2 "Required tool curl could not be found. Aborting."; exit 1; }
    command -v zcat >/dev/null 2>&1 || { echo >&2 "Required tool zcat could not be found. Hint: install the gzip package. Aborting."; exit 1; }
    command -v tar >/dev/null 2>&1 || { echo >&2 "Required tool tar could not be found. Aborting."; exit 1; }
    if [ "${WANT_STATIC}" = true ] || [ "${WANT_SHARED}" = true ]; then
        command -v mktemp >/dev/null 2>&1 || { echo >&2 "Required tool mktemp could not be found. Aborting."; exit 1; }
    fi

    DUCKDB_STAGED="${DUCKDB_STAGED:-}"
    if [ -z "${DUCKDB_STAGED}" ] && [ "${DUCKDB_VERSION:-}" = "alpha" ]
    then
        if ! DUCKDB_STAGED=$(curl --fail --silent --show-error https://duckdb-staging.duckdb.org/latest_alpha_version.txt)
        then
            echo "Failed to determine the latest DuckDB alpha version." 1>&2
            exit 1
        fi
    fi

    LATEST_VER=
    if [ -n "${DUCKDB_STAGED}" ]
    then
        VER="${DUCKDB_STAGED#*/}"
        STAGED_COMMIT=$(printf '%.10s' "${DUCKDB_STAGED%%/*}")
        DUCKDB_STAGED="${STAGED_COMMIT}/${VER}"
    else
        LATEST_VER=$(curl --fail --silent --show-error https://duckdb.org/data/latest_stable_version.txt)

        # Figure out the latest version or use the one from the environment.
        if [ -z "${DUCKDB_VERSION:-}" ]
        then
            VER=$LATEST_VER
        else
            VER="$DUCKDB_VERSION"
        fi
    fi

    PATH_VER=${VER#v}
    CLI_PREFIX="${HOME}/.duckdb/cli"
    CLI_INST="${CLI_PREFIX}/${PATH_VER}"
    CLI_LATEST="${CLI_PREFIX}/latest"
    LIB_PREFIX="${HOME}/.duckdb/lib"
    LIB_INST="${LIB_PREFIX}/${PATH_VER}"
    LIB_LATEST="${LIB_PREFIX}/latest"
    UPDATE_LATEST=false
    if [ -n "${DUCKDB_STAGED}" ] || [ "${VER}" = "${LATEST_VER}" ]
    then
        UPDATE_LATEST=true
    fi

    DIST=
    STATIC_LIBRARY=
    SHARED_LIBRARY=

    if [ "${OS}" = "Linux" ]
    then
        if [ "${ARCH}" = "x86_64" ] || [ "${ARCH}" = "amd64" ]
        then
            DIST=linux-amd64
        elif [ "${ARCH}" = "aarch64" ] || [ "${ARCH}" = "arm64" ]
        then
            DIST=linux-arm64
        fi

        if [ -n "${DIST}" ] && ldd --version 2>&1 | grep -qi musl
        then
            DIST="${DIST}-musl"
        fi
        STATIC_LIBRARY=libduckdb_static.a
        SHARED_LIBRARY=libduckdb.so
    elif [ "${OS}" = "Darwin" ]
    then
        if [ "${ARCH}" = "x86_64" ]
        then
            DIST=osx-amd64
        elif [ "${ARCH}" = "arm64" ]
        then
            DIST=osx-arm64
        fi
        STATIC_LIBRARY=libduckdb_static.a
        SHARED_LIBRARY=libduckdb.dylib
    fi

    if [ -z "${DIST}" ]
    then
        echo "Operating system '${OS}' / architecture '${ARCH}' is unsupported." 1>&2
        exit 1
    fi

    TEMP_DIR=
    cleanup() {
        if [ -n "${TEMP_DIR}" ] && [ -d "${TEMP_DIR}" ]; then
            rm -rf "${TEMP_DIR}"
        fi
    }
    trap cleanup EXIT
    trap 'exit 1' HUP INT TERM

    make_temp_dir() {
        if [ -z "${TEMP_DIR}" ]; then
            TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/duckdb_install.XXXXXX") || exit 1
        fi
    }

    extract_cli_v1() {
        URL="https://install.duckdb.org/v${VER}/duckdb_cli-${DIST}.gz"
        curl --fail --location --progress-bar "${URL}" -o- | zcat > "$1" || exit 1
        chmod a+x "$1"
    }

    extract_cli_v2() {
        if [ -n "${DUCKDB_STAGED}" ]
        then
            URL="https://duckdb-staging.duckdb.org/${DUCKDB_STAGED}/duckdb/duckdb/github_release/duckdb-cli-${DIST}.tar.gz"
        else
            URL="https://install.duckdb.org/v${VER}/duckdb-cli-${DIST}.tar.gz"
        fi
        curl --fail --location --progress-bar "${URL}" | tar -C "$1" -xzf - || exit 1
    }

    library_url() {
        LIBRARY_COMPONENT=$1
        if [ -n "${DUCKDB_STAGED}" ]
        then
            printf '%s\n' "https://duckdb-staging.duckdb.org/${DUCKDB_STAGED}/duckdb/duckdb/github_release/duckdb-${LIBRARY_COMPONENT}-libs-${DIST}.tar.gz"
        else
            printf '%s\n' "https://install.duckdb.org/v${VER}/duckdb-${LIBRARY_COMPONENT}-libs-${DIST}.tar.gz"
        fi
    }

    test_installed_duckdb() {
        "${CLI_INST}/duckdb" -noheader -init /dev/null -csv -batch -s "SELECT 2*3*7" 2>/dev/null
    }

    install_cli() {
        if [ -f "${CLI_INST}/duckdb" ] && [ "$(test_installed_duckdb)" = "42" ]; then
            echo "Destination binary ${CLI_INST}/duckdb already exists and seems to work"
            return
        fi

        mkdir -p "${CLI_INST}"
        if [ ! -d "${CLI_INST}" ]; then
            echo "Failed to create install directory ${CLI_INST}." 1>&2
            exit 1
        fi

        if [ -z "${DUCKDB_STAGED}" ]; then
            case "${VER}" in
                1*) extract_cli_v1 "${CLI_INST}/duckdb" ;;
                *) extract_cli_v2 "${CLI_INST}" ;;
            esac
        else
            extract_cli_v2 "${CLI_INST}"
        fi

        if [ ! -f "${CLI_INST}/duckdb" ]; then
            echo "Failed to download/unpack binary at ${CLI_INST}/duckdb" 1>&2
            exit 1
        fi
        if [ "$(test_installed_duckdb)" != "42" ]; then
            echo "Failed to execute installed binary :/ ${CLI_INST}." 1>&2
            exit 1
        fi
        echo
        echo "Successfully installed DuckDB ${VER} to ${CLI_INST}/duckdb"
    }

    install_library() {
        LIBRARY_COMPONENT=$1
        EXPECTED_LIBRARY=$2

        if [ -s "${LIB_INST}/${EXPECTED_LIBRARY}" ] && [ -s "${LIB_INST}/duckdb.h" ]; then
            echo "DuckDB ${LIBRARY_COMPONENT} library already exists at ${LIB_INST}/${EXPECTED_LIBRARY}"
            return
        fi

        make_temp_dir
        COMPONENT_TEMP="${TEMP_DIR}/${LIBRARY_COMPONENT}"
        mkdir -p "${COMPONENT_TEMP}"
        URL=$(library_url "${LIBRARY_COMPONENT}")
        curl --fail --location --progress-bar "${URL}" | tar -C "${COMPONENT_TEMP}" -xzf - || exit 1

        if [ ! -s "${COMPONENT_TEMP}/duckdb.h" ] || [ ! -s "${COMPONENT_TEMP}/${EXPECTED_LIBRARY}" ]; then
            echo "The ${LIBRARY_COMPONENT} library archive did not contain duckdb.h and ${EXPECTED_LIBRARY}." 1>&2
            exit 1
        fi

        mkdir -p "${LIB_INST}"
        cp -R "${COMPONENT_TEMP}/." "${LIB_INST}/" || exit 1
        if [ ! -s "${LIB_INST}/${EXPECTED_LIBRARY}" ]; then
            echo "Failed to install ${LIBRARY_COMPONENT} library at ${LIB_INST}/${EXPECTED_LIBRARY}." 1>&2
            exit 1
        fi
        echo "Successfully installed DuckDB ${LIBRARY_COMPONENT} library to ${LIB_INST}/${EXPECTED_LIBRARY}"
    }

    echo
    echo "*** DuckDB Linux/MacOS installation script, version ${VER} ***"
    echo
    echo
    echo "         .;odxdl,            "
    echo "       .xXXXXXXXXKc          "
    echo "       0XXXXXXXXXXXd  cooo:  "
    echo "      ,XXXXXXXXXXXXK  OXXXXd "
    echo "       0XXXXXXXXXXXo  cooo:  "
    echo "       .xXXXXXXXXKc          "
    echo "         .;odxdl,  "
    echo
    echo

    if [ "${WANT_CLI}" = true ]; then
        install_cli

        if [ "${UPDATE_LATEST}" = true ]; then
            rm -f "${CLI_LATEST}" || exit 1
            ln -s "${CLI_INST}" "${CLI_LATEST}" || exit 1
            echo "Updated symlink from ${CLI_LATEST}/duckdb to"
            echo "                     ${CLI_INST}/duckdb"

            echo
            echo "Hint: Append the following line to your shell profile:"
            printf "export PATH=\"%s\":\$PATH\n" "${CLI_LATEST}"
        else
            echo
            echo "Hint: Append the following line to your shell profile:"
            printf "export PATH=\"%s\":\$PATH\n" "${CLI_INST}"
        fi

        LOCALBIN="${HOME}/.local/bin"
        if [ "${UPDATE_LATEST}" = true ] && [ -d "${LOCALBIN}" ] && [ -w "${LOCALBIN}" ] && [ ! -f "${LOCALBIN}/duckdb" ]; then
            ln -s "${CLI_LATEST}/duckdb" "${LOCALBIN}/duckdb" || exit 1
            echo "Also created a symlink from ${LOCALBIN}/duckdb"
            echo "                         to ${CLI_LATEST}/duckdb"
        fi
    fi

    REMAINING_COMPONENTS=${INSTALL_COMPONENTS}
    while [ -n "${REMAINING_COMPONENTS}" ]
    do
        case "${REMAINING_COMPONENTS}" in
            *,*)
                COMPONENT=${REMAINING_COMPONENTS%%,*}
                REMAINING_COMPONENTS=${REMAINING_COMPONENTS#*,}
                ;;
            *)
                COMPONENT=${REMAINING_COMPONENTS}
                REMAINING_COMPONENTS=
                ;;
        esac

        case "${COMPONENT}" in
            static) install_library static "${STATIC_LIBRARY}" ;;
            shared) install_library shared "${SHARED_LIBRARY}" ;;
        esac
    done

    if [ "${WANT_STATIC}" = true ] || [ "${WANT_SHARED}" = true ]; then
        LIB_DISPLAY=${LIB_INST}
        if [ "${UPDATE_LATEST}" = true ]; then
            rm -f "${LIB_LATEST}" || exit 1
            ln -s "${LIB_INST}" "${LIB_LATEST}" || exit 1
            LIB_DISPLAY=${LIB_LATEST}
            echo "Updated symlink ${LIB_LATEST} to ${LIB_INST}"
        fi
        echo
        echo "DuckDB C/C++ headers and libraries are installed in ${LIB_DISPLAY}"
        printf "Compile with -I\"%s\" and -L\"%s\".\n" "${LIB_DISPLAY}" "${LIB_DISPLAY}"
    fi

    if [ "${WANT_CLI}" = true ]; then
        echo
        echo "To launch DuckDB ${VER} now, type"
        if [ "${UPDATE_LATEST}" = true ]; then
            echo "${CLI_LATEST}/duckdb"
        else
            echo "${CLI_INST}/duckdb"
        fi
    fi
}

main
