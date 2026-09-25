# DuckDB install scripts for Linux/macOS and Windows

This repository contains the scripts that power the DuckDB installer.

Install the latest stable duckdb CLI:
```shell
curl install.duckdb.org | sh
```

Install the latest alpha version:
```shell
curl https://install.duckdb.org | DUCKDB_VERSION=alpha sh
```

Install staged artifacts for a specific commit:
```shell
curl https://install.duckdb.org | DUCKDB_STAGED=31adc8b766 sh
```

> [!NOTE]
> The installer looks up the latest alpha version associated with that commit.

Or, install an explicit `commit/version` pair:
```shell
curl https://install.duckdb.org | DUCKDB_STAGED=31adc8b766/v2.0.0-alpha42839 sh
```

## Components

The installer downloads the DuckDB CLI by default. Set `DUCKDB_INSTALL` to a comma-separated list containing `cli`, `static`, or `shared` to choose the components to install:

```bash
# Install only the shared library.
curl https://install.duckdb.org | DUCKDB_INSTALL=shared sh

# Install the CLI and both libraries.
curl https://install.duckdb.org | DUCKDB_INSTALL=cli,static,shared sh
```

Static and shared library artifacts are available for DuckDB 2.0 and newer.

On Windows:

```powershell
$env:DUCKDB_INSTALL = "cli,static,shared"
./install.ps1
```

The installers use the following versioned locations:

| Component | Linux/macOS | Windows |
| --- | --- | --- |
| CLI | `~/.duckdb/cli/<version>` | `%LOCALAPPDATA%\duckdb\cli\<version>` |
| Libraries | `~/.duckdb/lib/<version>/release_<platform>` | `%LOCALAPPDATA%\duckdb\lib\<version>\release_<platform>` |

Platform names follow the artifact target with underscores, such as `linux_amd64`, `linux_amd64_musl`, `osx_arm64`, or `windows_amd64`.

For latest-stable and staged installs, the Linux/macOS installer updates the `cli/latest` symlink. Pinned versions do not update this symlink. Libraries always use their versioned build/platform path. Windows uses version-specific paths.

## Using the libraries from C++

The distributed library exposes DuckDB's C API, which can be called directly from C++. For example:

```cpp
#include <duckdb.h>

#include <iostream>

int main() {
    duckdb_database database;
    duckdb_connection connection;
    duckdb_result result;

    if (duckdb_open(nullptr, &database) == DuckDBError) {
        return 1;
    }
    if (duckdb_connect(database, &connection) == DuckDBError) {
        duckdb_close(&database);
        return 1;
    }
    if (duckdb_query(connection, "SELECT 42", &result) == DuckDBError) {
        duckdb_disconnect(&connection);
        duckdb_close(&database);
        return 1;
    }

    std::cout << duckdb_value_int64(&result, 0, 0) << '\n';

    duckdb_destroy_result(&result);
    duckdb_disconnect(&connection);
    duckdb_close(&database);
}
```

### Linking on Linux and macOS

Link the shared library on Linux or macOS with:

```bash
DUCKDB_PREFIX="$HOME/.duckdb/lib/<version>/release_linux_amd64"
c++ main.cpp -I"$DUCKDB_PREFIX" -L"$DUCKDB_PREFIX" -lduckdb \
    -Wl,-rpath,"$DUCKDB_PREFIX" -o example
```

Link the static library explicitly so the linker does not select the shared library:

```bash
DUCKDB_PREFIX="$HOME/.duckdb/lib/<version>/release_linux_amd64"
c++ main.cpp -I"$DUCKDB_PREFIX" "$DUCKDB_PREFIX/libduckdb_static.a" \
    -pthread -o example
```

On Linux, a static build may additionally need `-ldl`, depending on the release build.

### Linking on Windows

On Windows with MSVC, use `duckdb.lib` for the shared library or `duckdb_static.lib` for the static library:

```powershell
$DuckDBPrefix = "$env:LOCALAPPDATA\duckdb\lib\<version>\release_windows_amd64"
cl /EHsc main.cpp /I "$DuckDBPrefix" /link "/LIBPATH:$DuckDBPrefix" duckdb.lib
```

> [!NOTE]
> When linking the shared library on Windows, place `duckdb.dll` beside the resulting executable or add its directory to `PATH`.

## Alpine Linux

On Alpine Linux, install curl and C++ runtime before running the installer:

```bash
apk add --no-cache curl libstdc++
curl https://install.duckdb.org | sh
```
