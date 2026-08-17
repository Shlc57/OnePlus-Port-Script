#!/system/bin/sh

# init transitions this script into the dedicated fake_device_params domain
# and runs it as Android's system UID/GID. The process therefore needs neither
# a root manager domain nor DAC-bypass capabilities.

set -u

source_file="${1:-/system/etc/device_params/device_params_pref.xml}"
package_dir="/data/user_de/0/com.android.settings"
target_dir="$package_dir/shared_prefs"
target_file="$target_dir/device_params_pref.xml"
temporary_file="$target_file.fake_device_params.$$"
max_attempts=120
attempt=0

# The function is invoked by the EXIT/HUP/INT/TERM trap below.
# shellcheck disable=SC2329
cleanup() {
    rm -f "$temporary_file"
}
trap cleanup EXIT HUP INT TERM

if [ ! -f "$source_file" ]; then
    exit 1
fi

while [ ! -d "$package_dir" ] && [ "$attempt" -lt "$max_attempts" ]; do
    sleep 1
    attempt=$((attempt + 1))
done

if [ ! -d "$package_dir" ]; then
    exit 1
fi

if [ ! -d "$target_dir" ]; then
    mkdir -p "$target_dir" || exit 1
    chmod 0700 "$target_dir" || exit 1
fi

umask 077
rm -f "$temporary_file" || exit 1
cp "$source_file" "$temporary_file" || exit 1
chmod 0600 "$temporary_file" || exit 1
mv -f "$temporary_file" "$target_file" || exit 1
exit 0
