#!/bin/sh
# Legacy entry point: bump then stamp (used if invoked manually).
set -e
"$(dirname "$0")/bump_build_number.sh"
"$(dirname "$0")/stamp_build_number.sh"
