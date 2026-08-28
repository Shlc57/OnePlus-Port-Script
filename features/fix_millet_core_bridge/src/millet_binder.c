// SPDX-License-Identifier: GPL-2.0
#define pr_fmt(fmt) "millet_core: binder: " fmt

#include <linux/module.h>
#include <linux/rbtree.h>
#include <linux/sched.h>
#include <linux/uaccess.h>
#include <trace/hooks/binder.h>
#include <uapi/linux/android/binder.h>

/* Exact Android 15/6.6 layouts used by the device's GKI binder driver. */
#include "binder_internal.h"

#include "millet_bridge.h"

#define MILLET_BINDER_BLACK_BASE 111
#define MILLET_BINDER_WARN_MULTIPLIER 3

static bool binder_trans_registered;
static bool binder_reply_registered;
static bool binder_wait_registered;
static bool binder_alloc_registered;
static bool binder_preset_registered;
static struct hlist_head *millet_binder_procs;
static struct mutex *millet_binder_procs_lock;

bool millet_binder_registry_ready(void)
{
	struct hlist_head *hhead = READ_ONCE(millet_binder_procs);

	smp_rmb();
	return hhead && READ_ONCE(millet_binder_procs_lock);
}

static struct task_struct *millet_binder_task(struct binder_proc *proc)
{
	return proc ? READ_ONCE(proc->tsk) : NULL;
}

static int millet_task_uid(struct task_struct *task)
{
	return task ? __kuid_val(task_uid(task)) : 0;
}

static void millet_fill_binder_event(struct millet_data *data,
				     struct task_struct *source,
				     struct task_struct *target,
				     struct binder_transaction_data *tr,
				     int caller_tid, int buffer)
{
	memset(data, 0, sizeof(*data));
	data->owner = MILLET_TYPE_BINDER;
	data->msg_type = MILLET_MSG_TO_USER;
	data->uid = millet_task_uid(target);
	data->pri[0] = buffer;
	data->priv.binder.trans.src_task = source;
	data->priv.binder.trans.dst_task = target;
	data->priv.binder.trans.caller_uid = millet_task_uid(source);
	data->priv.binder.trans.caller_pid = task_tgid_nr(source);
	data->priv.binder.trans.caller_tid = caller_tid > 0 ? caller_tid :
							 task_pid_nr(source);
	data->priv.binder.trans.dst_pid = task_tgid_nr(target);
	if (tr) {
		data->priv.binder.trans.tf_oneway = !!(tr->flags & TF_ONE_WAY);
		data->priv.binder.trans.code = tr->code;
	}
}

/*
 * Reimplementation of Xiaomi binder_gki::reset_isfrozen().  The Binder
 * driver's own frozen bit must be cleared for an allowed transaction before
 * userspace Greeze receives buffer=4 and thaws the cgroup.
 */
static int millet_reset_binder_frozen(struct binder_proc *target_proc,
				      bool caller_allowed)
{
	int result = 0;

	if (!target_proc)
		return 0;
	spin_lock(&target_proc->inner_lock);
	if (target_proc->tsk) {
		if (!target_proc->is_frozen)
			result = 2;
		else if (caller_allowed) {
			target_proc->is_frozen = false;
			result = 1;
		}
	}
	spin_unlock(&target_proc->inner_lock);
	return result;
}

static int millet_filter_binder_buffer(int buffer, bool caller_allowed,
				       bool oneway)
{
	if (!millet_freezebinder_enabled() || buffer == MILLET_BINDER_BUFF_WARN ||
	    buffer == 4 || caller_allowed)
		return buffer;
	if (oneway)
		return -ECANCELED;
	return buffer + MILLET_BINDER_BLACK_BASE;
}

static void millet_binder_trans_hook(void *unused,
				     struct binder_proc *target_proc,
				     struct binder_proc *proc,
				     struct binder_thread *thread,
				     struct binder_transaction_data *tr)
{
	struct task_struct *source = millet_binder_task(proc);
	struct task_struct *target = millet_binder_task(target_proc);
	struct millet_data data;
	bool allowed;
	bool oneway;
	int target_uid;
	int reset;
	int buffer;

	if (!source || !target || !tr || source == target)
		return;
	target_uid = millet_task_uid(target);
	if (target_uid <= frozen_uid_min ||
	    task_tgid_nr(source) == task_tgid_nr(target) ||
	    !millet_task_is_frozen(target))
		return;

	oneway = !!(tr->flags & TF_ONE_WAY);
	allowed = millet_binder_caller_allowed(millet_task_uid(source),
						task_tgid_nr(source), target_uid);
	/* Stock code never clears Binder's frozen bit for an async call. */
	reset = 0;
	if (millet_freezebinder_enabled() && !oneway)
		reset = millet_reset_binder_frozen(target_proc, allowed);
	buffer = reset ? 4 : MILLET_BINDER_TRANS;
	buffer = millet_filter_binder_buffer(buffer, allowed, oneway);
	if (buffer < 0)
		return;

	millet_fill_binder_event(&data, source, target, tr,
				 thread ? thread->pid : task_pid_nr(source), buffer);
	millet_send_event(&data);
}

static void millet_binder_reply_hook(void *unused,
				     struct binder_proc *target_proc,
				     struct binder_proc *proc,
				     struct binder_thread *thread,
				     struct binder_transaction_data *tr)
{
	struct task_struct *source = millet_binder_task(proc);
	struct task_struct *target = millet_binder_task(target_proc);
	struct millet_data data;
	bool allowed;
	int buffer;

	if (!source || !target || !tr || source == target ||
	    millet_task_uid(target) > frozen_uid_min ||
	    !millet_task_is_frozen(target))
		return;
	allowed = millet_binder_caller_allowed(millet_task_uid(source),
						task_tgid_nr(source),
						millet_task_uid(target));
	buffer = millet_filter_binder_buffer(MILLET_BINDER_REPLY, allowed,
					     !!(tr->flags & TF_ONE_WAY));
	if (buffer < 0)
		return;
	millet_fill_binder_event(&data, source, target, tr,
				 thread ? thread->pid : task_pid_nr(source), buffer);
	millet_send_event(&data);
}

static void millet_binder_wait_hook(void *unused, bool do_proc_work,
				    struct binder_thread *thread,
				    struct binder_proc *proc)
{
	struct binder_transaction *transaction;
	struct task_struct *source;
	struct task_struct *target = NULL;
	struct millet_data data;
	struct binder_transaction_data tr = { };
	bool allowed;
	int buffer;

	if (!thread || !proc)
		return;
	/* Hook is invoked while proc->inner_lock is held. */
	if (READ_ONCE(thread->is_dead))
		return;
	transaction = thread->transaction_stack;
	if (!transaction)
		return;
	spin_lock(&transaction->lock);
	if (transaction->to_proc && transaction->to_proc->tsk) {
		target = transaction->to_proc->tsk;
		get_task_struct(target);
	}
	tr.flags = transaction->flags;
	tr.code = transaction->code;
	spin_unlock(&transaction->lock);
	if (!target)
		return;
	/* Xiaomi binder_gki reports proc->tsk -> transaction->to_proc->tsk. */
	source = millet_binder_task(proc);
	if (!source || !target || source == target ||
	    millet_task_uid(target) > frozen_uid_min ||
	    !millet_task_is_frozen(target))
		goto out_put;

	allowed = millet_binder_caller_allowed(millet_task_uid(source),
						task_tgid_nr(source),
						millet_task_uid(target));
	buffer = millet_filter_binder_buffer(MILLET_BINDER_THREAD_HAS_WORK,
					     allowed, !!(tr.flags & TF_ONE_WAY));
	if (buffer < 0)
		goto out_put;
	millet_fill_binder_event(&data, source, target, &tr, thread->pid, buffer);
	millet_send_event(&data);
out_put:
	put_task_struct(target);
}

static void millet_binder_alloc_hook(void *unused, size_t size,
				     size_t *free_async_space, int is_async,
				     bool *should_fail)
{
	struct binder_alloc *alloc;
	struct binder_proc *target_proc;
	struct task_struct *target;
	struct millet_data data;
	size_t threshold;

	if (!is_async || !free_async_space)
		return;
	if (size > (SIZE_MAX / MILLET_BINDER_WARN_MULTIPLIER) -
		   sizeof(struct binder_buffer))
		threshold = SIZE_MAX;
	else
		threshold = (size + sizeof(struct binder_buffer)) *
			    MILLET_BINDER_WARN_MULTIPLIER;
	if (*free_async_space >= threshold &&
	    *free_async_space >= binder_warn_ahead_space)
		return;

	alloc = container_of(free_async_space, struct binder_alloc,
			     free_async_space);
	target_proc = container_of(alloc, struct binder_proc, alloc);
	target = millet_binder_task(target_proc);
	if (!target || !millet_task_is_frozen(target))
		return;
	millet_fill_binder_event(&data, current, target, NULL,
				 task_pid_nr(current), MILLET_BINDER_BUFF_WARN);
	millet_send_event(&data);
}

static void millet_binder_preset_hook(void *unused, struct hlist_head *hhead,
				      struct mutex *lock,
				      struct binder_proc *proc)
{
	if (!READ_ONCE(millet_binder_procs) && hhead && lock) {
		WRITE_ONCE(millet_binder_procs_lock, lock);
		smp_wmb();
		WRITE_ONCE(millet_binder_procs, hhead);
	}
}

static bool millet_binder_transaction_matches(struct binder_transaction *trans,
					      struct binder_thread *thread)
{
	bool matches = false;

	if (!trans)
		return false;
	spin_lock(&trans->lock);
	if ((!thread && !trans->to_thread) ||
	    (thread && trans->to_thread == thread))
		matches = trans->need_reply;
	spin_unlock(&trans->lock);
	return matches;
}

static bool millet_binder_todo_busy_locked(struct list_head *todo,
					   struct binder_thread *thread)
{
	struct binder_work *work;

	list_for_each_entry(work, todo, entry) {
		struct binder_transaction *trans;

		if (work->type != BINDER_WORK_TRANSACTION)
			continue;
		trans = container_of(work, struct binder_transaction, work);
		/* Stock binder_switch=1 only treats synchronous work as busy. */
		if (millet_binder_transaction_matches(trans, thread))
			return true;
	}
	return false;
}

static bool millet_binder_proc_busy_locked(struct binder_proc *proc)
{
	struct rb_node *node;

	/* Stock SM8750 defaults millet_binder_switch=1 and ignores non-TXN work. */
	if (!millet_binder_switch && !list_empty(&proc->todo))
		return true;
	if (millet_binder_switch &&
	    millet_binder_todo_busy_locked(&proc->todo, NULL))
		return true;
	for (node = rb_first(&proc->threads); node; node = rb_next(node)) {
		struct binder_thread *thread = rb_entry(node, struct binder_thread,
							 rb_node);

		if (!millet_binder_switch) {
			if (thread->transaction_stack || !list_empty(&thread->todo))
				return true;
			continue;
		}
		if (millet_binder_todo_busy_locked(&thread->todo, thread) ||
		    millet_binder_transaction_matches(thread->transaction_stack,
						      thread))
			return true;
	}
	return false;
}

void millet_note_binder_command(const struct millet_userconf *msg)
{
	struct hlist_head *hhead = READ_ONCE(millet_binder_procs);
	struct mutex *lock;
	struct binder_proc *proc;
	struct millet_data data = { };
	int uid = msg->priv.binder_st.uid;
	bool busy = false;

	smp_rmb();
	lock = READ_ONCE(millet_binder_procs_lock);

	if (millet_debug)
		pr_info("binder-stat command uid=%d\n", uid);
	/* Stock query_binder_app_stat emits no reply until Binder is discoverable. */
	if (!hhead || !lock)
		return;
	mutex_lock(lock);
	hlist_for_each_entry(proc, hhead, proc_node) {
		struct task_struct *task = millet_binder_task(proc);

		if (!task || millet_task_uid(task) != uid)
			continue;
		spin_lock(&proc->inner_lock);
		busy |= millet_binder_proc_busy_locked(proc);
		spin_unlock(&proc->inner_lock);
		if (busy)
			break;
	}
	mutex_unlock(lock);

	data.owner = MILLET_TYPE_BINDER_ST;
	data.msg_type = MILLET_MSG_TO_USER;
	data.uid = uid;
	data.priv.binder.stat.task = current;
	data.priv.binder.stat.pid = task_pid_nr(current);
	data.priv.binder.stat.tid = 0;
	data.priv.binder.stat.reason = busy ? BINDER_IN_BUSY : BINDER_IN_IDLE;
	millet_send_event(&data);
}

int millet_binder_register(void)
{
	int ret;

	ret = register_trace_android_vh_binder_preset(millet_binder_preset_hook,
						      NULL);
	if (ret)
		return ret;
	binder_preset_registered = true;

	ret = register_trace_android_vh_binder_alloc_new_buf_locked(
		millet_binder_alloc_hook, NULL);
	if (ret)
		goto err_alloc;
	binder_alloc_registered = true;

	ret = register_trace_android_vh_binder_trans(millet_binder_trans_hook, NULL);
	if (ret)
		goto err_trans;
	binder_trans_registered = true;

	ret = register_trace_android_vh_binder_reply(millet_binder_reply_hook, NULL);
	if (ret)
		goto err_reply;
	binder_reply_registered = true;

	ret = register_trace_android_vh_binder_wait_for_work(
		millet_binder_wait_hook, NULL);
	if (ret)
		goto err_wait;
	binder_wait_registered = true;
	return 0;

err_wait:
	unregister_trace_android_vh_binder_reply(millet_binder_reply_hook, NULL);
	binder_reply_registered = false;
err_reply:
	unregister_trace_android_vh_binder_trans(millet_binder_trans_hook, NULL);
	binder_trans_registered = false;
err_trans:
	unregister_trace_android_vh_binder_alloc_new_buf_locked(
		millet_binder_alloc_hook, NULL);
	binder_alloc_registered = false;
err_alloc:
	unregister_trace_android_vh_binder_preset(millet_binder_preset_hook, NULL);
	binder_preset_registered = false;
	return ret;
}

void millet_binder_unregister(void)
{
	if (binder_wait_registered) {
		unregister_trace_android_vh_binder_wait_for_work(
			millet_binder_wait_hook, NULL);
		binder_wait_registered = false;
	}
	if (binder_reply_registered) {
		unregister_trace_android_vh_binder_reply(millet_binder_reply_hook,
							 NULL);
		binder_reply_registered = false;
	}
	if (binder_trans_registered) {
		unregister_trace_android_vh_binder_trans(millet_binder_trans_hook,
							 NULL);
		binder_trans_registered = false;
	}
	if (binder_alloc_registered) {
		unregister_trace_android_vh_binder_alloc_new_buf_locked(
			millet_binder_alloc_hook, NULL);
		binder_alloc_registered = false;
	}
	if (binder_preset_registered) {
		unregister_trace_android_vh_binder_preset(millet_binder_preset_hook,
							  NULL);
		binder_preset_registered = false;
	}
	WRITE_ONCE(millet_binder_procs, NULL);
	WRITE_ONCE(millet_binder_procs_lock, NULL);
}
