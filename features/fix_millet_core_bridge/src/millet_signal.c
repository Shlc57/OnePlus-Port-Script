// SPDX-License-Identifier: GPL-2.0
#define pr_fmt(fmt) "millet_core: signal: " fmt

#include <linux/module.h>
#include <linux/sched/signal.h>
#include <trace/hooks/signal.h>

#include "millet_bridge.h"

static bool signal_registered;
static atomic_t last_signal_tgid = ATOMIC_INIT(0);

static void millet_signal_hook(void *unused, int sig,
			       struct task_struct *killer,
			       struct task_struct *dst)
{
	struct millet_data data = { };
	int target_tgid;

	if (!killer || !dst || !millet_task_is_frozen(dst))
		return;
	if (sig != SIGQUIT && sig != SIGABRT && sig != SIGKILL &&
	    sig != SIGTERM)
		return;
	target_tgid = task_tgid_nr(dst);
	if (target_tgid <= 0 ||
	    atomic_xchg(&last_signal_tgid, target_tgid) == target_tgid)
		return;

	data.owner = MILLET_TYPE_SIGNAL;
	data.msg_type = MILLET_MSG_TO_USER;
	data.uid = __kuid_val(task_uid(dst));
	/* millet_monitor::reportSignal reads the signal number from pri[0]. */
	data.pri[0] = sig;
	data.priv.signal.caller_task = killer;
	data.priv.signal.killed_task = dst;
	data.priv.signal.killed_pid = target_tgid;
	data.priv.signal.reason = 0;
	millet_send_event(&data);
}

int millet_signal_register(void)
{
	int ret;

	atomic_set(&last_signal_tgid, 0);
	ret = register_trace_android_vh_do_send_sig_info(millet_signal_hook, NULL);
	if (!ret)
		signal_registered = true;
	return ret;
}

void millet_signal_unregister(void)
{
	if (signal_registered) {
		unregister_trace_android_vh_do_send_sig_info(millet_signal_hook, NULL);
		signal_registered = false;
	}
}
