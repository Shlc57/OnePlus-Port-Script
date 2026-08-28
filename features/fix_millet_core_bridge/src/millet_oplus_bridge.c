// SPDX-License-Identifier: GPL-2.0
/* Single translation unit keeps the external-module build independent of lld. */
#include "millet_core.c"
#undef pr_fmt
#include "millet_pkg.c"
#undef pr_fmt
#include "millet_signal.c"
#undef pr_fmt
#include "millet_binder.c"
