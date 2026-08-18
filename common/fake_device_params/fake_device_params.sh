#!/system/bin/sh

# init transitions this script into the dedicated fake_device_params domain
# and runs it as Android's system UID/GID. The process therefore needs neither
# a root manager domain nor DAC-bypass capabilities.

set -u

default_source_file="/system/etc/device_params/device_params_pref.xml"
source_file="${1:-$default_source_file}"
package_dir="/data/user_de/0/com.android.settings"
target_dir="$package_dir/shared_prefs"
target_file="$target_dir/device_params_pref.xml"
temporary_file="$target_file.fake_device_params.$$"
max_attempts=120
attempt=0

# The primary template remains the fallback. An optional enUS template lets the
# port keep the spoofed strings in English when the system locale is en-US.
if [ "$source_file" = "$default_source_file" ]; then
    locale_code="$(getprop persist.sys.locale 2>/dev/null | tr -cd '[:alnum:]')"
    localized_source_file="${default_source_file%.xml}.${locale_code}.xml"
    if [ -n "$locale_code" ] && [ -f "$localized_source_file" ]; then
        source_file="$localized_source_file"
    fi
fi

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
