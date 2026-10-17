#!/bin/sh
# Pure fixtures only. No certificates, builds, network, app launch or real install.
set -eu
script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
/bin/sh -n "$script_directory/../install.sh"
exec /usr/bin/python3 -I -B -S "$script_directory/test-bootstrap-install.py"
