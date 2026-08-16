#!/bin/bash
set -e

init_port_env "${1:-}"

std_print "修复微信安全模式"
std_print

check_part_exists odm
remove_path_if_exists "$project_dir/odm/framework/androidx.camera.extensions.impl.fake.jar"

std_print "处理完成"
