#!/bin/bash
set -e

init_port_env "${1:-}"

std_print "修复微信安全模式"
std_print

check_part_exists odm
check_file_exists "$(get_part_contexts_path odm)"
check_file_exists "$(get_part_fsconfig_path odm)"
check_partition_metadata_tool >/dev/null
remove_path_if_exists "$project_dir/odm/framework/androidx.camera.extensions.impl.fake.jar"
remove_part_metadata_prefix odm framework/androidx.camera.extensions.impl.fake.jar

std_print "处理完成"
