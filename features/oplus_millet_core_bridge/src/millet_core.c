// SPDX-License-Identifier: GPL-2.0
#define pr_fmt(fmt) "millet_core: " fmt

#include <linux/cgroup.h>
#include <linux/freezer.h>
#include <linux/ktime.h>
#include <linux/module.h>
#include <linux/netlink.h>
#include <linux/proc_fs.h>
#include <linux/seq_file.h>
#include <linux/skbuff.h>
#include <linux/sched/jobctl.h>
#include <linux/uaccess.h>
#include <net/net_namespace.h>
#include <net/sock.h>

#include "millet_bridge.h"

bool millet_enable_pkg;
bool millet_enable_signal;
bool millet_enable_binder;
unsigned int millet_debug;
int frozen_uid_min = MILLET_UID_MIN;
unsigned long binder_warn_ahead_space = 1UL << 17;
int millet_freeze_switch;
bool millet_binder_switch = true;

module_param_named(enable_pkg, millet_enable_pkg, bool, 0444);
MODULE_PARM_DESC(enable_pkg, "Register IPv4/IPv6 packet wake hooks");
module_param_named(enable_signal, millet_enable_signal, bool, 0444);
MODULE_PARM_DESC(enable_signal, "Register Android signal vendor hook");
module_param_named(enable_binder, millet_enable_binder, bool, 0444);
MODULE_PARM_DESC(enable_binder, "Register Android Binder vendor hooks");
/* Keep the stock SM8750 millet_core parameter ABI, including permissions. */
module_param_named(millet_debug, millet_debug, uint, 0644);
module_param_named(frozen_uid_min, frozen_uid_min, uint, 0644);
module_param_named(binder_warn_ahead_space, binder_warn_ahead_space, ulong, 0644);
module_param_named(millet_freeze_switch, millet_freeze_switch, int, 0660);
module_param_named(millet_binder_switch, millet_binder_switch, bool, 0644);

EXPORT_SYMBOL_GPL(millet_debug);
EXPORT_SYMBOL_GPL(frozen_uid_min);
EXPORT_SYMBOL_GPL(binder_warn_ahead_space);
EXPORT_SYMBOL_GPL(millet_binder_switch);

static struct sock *millet_nl_sock;
static atomic_t millet_ports[MILLET_TYPE_COUNT];
static atomic64_t millet_sent[MILLET_TYPE_COUNT];
static atomic64_t millet_failed[MILLET_TYPE_COUNT];
static atomic64_t millet_received[MILLET_TYPE_COUNT];
static struct proc_dir_entry *millet_proc_dir;

static inline bool millet_valid_type(int type)
{
	return type > MILLET_TYPE_NONE && type < MILLET_TYPE_COUNT;
}

/* Keep Xiaomi's in-kernel query ABI in addition to the module parameter. */
bool judge_millet_freeze_switch(void)
{
	return READ_ONCE(millet_freeze_switch) == 1;
}

static int millet_monitor_for_owner(int owner)
{
	/* Stock BINDER_STAT replies use the already registered BINDER socket. */
	if (owner == MILLET_TYPE_BINDER_ST)
		return MILLET_TYPE_BINDER;
	if (owner == MILLET_TYPE_HANDSHAKE)
		return MILLET_TYPE_SIGNAL;
	return owner;
}

bool millet_task_is_frozen(struct task_struct *task)
{
	struct task_struct *leader;

	if (!task)
		return false;
	if (freezing(task) || cgroup_task_frozen(task) ||
	    (READ_ONCE(task->jobctl) & JOBCTL_TRAP_FREEZE) ||
	    (READ_ONCE(task->__state) & TASK_FROZEN))
		return true;

	leader = READ_ONCE(task->group_leader);
	return leader && ((READ_ONCE(leader->jobctl) & JOBCTL_TRAP_FREEZE) ||
			  (READ_ONCE(leader->__state) & TASK_FROZEN));
}

int millet_send_event(struct millet_data *data)
{
	struct millet_data *payload;
	struct sk_buff *skb;
	struct nlmsghdr *nlh;
	struct timespec64 ts;
	int monitor;
	int port;
	int ret;

	if (!millet_nl_sock || !data || !millet_valid_type(data->owner))
		return -EINVAL;

	monitor = millet_monitor_for_owner(data->owner);
	port = atomic_read(&millet_ports[monitor]);
	if (port <= 0) {
		atomic64_inc(&millet_failed[data->owner]);
		return -ENOTCONN;
	}

	skb = nlmsg_new(sizeof(*payload), GFP_ATOMIC);
	if (!skb) {
		atomic64_inc(&millet_failed[data->owner]);
		return -ENOMEM;
	}

	nlh = nlmsg_put(skb, 0, 0, 0, sizeof(*payload), 0);
	if (!nlh) {
		kfree_skb(skb);
		atomic64_inc(&millet_failed[data->owner]);
		return -EMSGSIZE;
	}

	payload = nlmsg_data(nlh);
	memset(payload, 0, sizeof(*payload));
	memcpy(payload, data, sizeof(*payload));
	payload->monitor = monitor;
	payload->src_port = MILLET_KERNEL_ID;
	payload->dst_port = MILLET_USER_ID;
	ktime_get_ts64(&ts);
	payload->tm.sec = ts.tv_sec;
	payload->tm.nsec = ts.tv_nsec;

	ret = nlmsg_unicast(millet_nl_sock, skb, port);
	if (ret < 0) {
		atomic64_inc(&millet_failed[data->owner]);
		if (millet_debug)
			pr_info("send owner=%d monitor=%d port=%d failed=%d\n",
				data->owner, monitor, port, ret);
		return ret;
	}

	atomic64_inc(&millet_sent[data->owner]);
	if (millet_debug)
		pr_info("sent owner=%d monitor=%d port=%d uid=%d\n",
			data->owner, monitor, port, data->uid);
	return 0;
}

static void millet_send_loopback(int owner)
{
	struct millet_data data = { };

	data.owner = owner;
	data.msg_type = MILLET_MSG_LOOPBACK;
	millet_send_event(&data);
}

static void millet_send_handshake(void)
{
	struct millet_data data = { };

	data.owner = MILLET_TYPE_HANDSHAKE;
	data.msg_type = MILLET_MSG_TO_USER;
	millet_send_event(&data);
}

static void millet_recv(struct sk_buff *skb)
{
	const struct millet_userconf *msg;
	struct nlmsghdr *nlh;
	uid_t uid;
	int owner;
	int port;

	if (!skb || skb->len < NLMSG_HDRLEN)
		return;

	uid = __kuid_val(NETLINK_CB(skb).creds.uid);
	if (uid > 1000) {
		pr_warn_ratelimited("reject netlink uid=%u\n", uid);
		return;
	}

	nlh = nlmsg_hdr(skb);
	if (nlh->nlmsg_len < NLMSG_LENGTH(sizeof(*msg))) {
		pr_warn_ratelimited("short message len=%u expected=%zu\n",
				    nlh->nlmsg_len, NLMSG_LENGTH(sizeof(*msg)));
		return;
	}

	msg = nlmsg_data(nlh);
	owner = msg->owner;
	if (!millet_valid_type(owner) || msg->src_port != MILLET_USER_ID ||
	    msg->dst_port != MILLET_KERNEL_ID) {
		pr_warn_ratelimited("invalid message owner=%d src=%llx dst=%llx\n",
				    owner, msg->src_port, msg->dst_port);
		return;
	}

	atomic64_inc(&millet_received[owner]);
	port = nlh->nlmsg_pid ? nlh->nlmsg_pid : NETLINK_CB(skb).portid;

	switch (msg->msg_type) {
	case MILLET_MSG_LOOPBACK:
		atomic_set(&millet_ports[owner], port);
		if (millet_debug)
			pr_info("registered owner=%d port=%d\n", owner, port);
		millet_send_loopback(owner);
		break;
	case MILLET_MSG_TO_KERN:
		if (owner == MILLET_TYPE_PKG)
			millet_note_pkg_command(msg);
		else if (owner == MILLET_TYPE_BINDER_ST)
			millet_note_binder_command(msg);
		else if (owner == MILLET_TYPE_HANDSHAKE)
			millet_send_handshake();
		break;
	default:
		pr_warn_ratelimited("invalid message type=%d owner=%d\n",
				    msg->msg_type, owner);
		break;
	}
}

static int millet_stats_show(struct seq_file *seq, void *unused)
{
	static const char * const names[MILLET_TYPE_COUNT] = {
		"NONE", "SIG", "BINDER", "BINDER_STAT", "MEM", "PKG", "HANDSHK"
	};
	unsigned int monitored = 0;
	unsigned int core = 0;
	unsigned int black_pid = 0;
	unsigned int black_uid = 0;
	int i;

	seq_printf(seq, "protocol=%d abi_data=%zu abi_userconf=%zu\n",
		   MILLET_NETLINK_PROTO, sizeof(struct millet_data),
		   sizeof(struct millet_userconf));
	seq_printf(seq, "hooks pkg=%d signal=%d binder=%d\n",
		   millet_enable_pkg, millet_enable_signal, millet_enable_binder);
	millet_pkg_get_counts(&monitored, &core, &black_pid, &black_uid);
	seq_printf(seq,
		   "policy freeze=%d binder_switch=%d freezebinder=%d binder_registry=%d uid_min=%d warn_ahead=%lu\n",
		   millet_freeze_switch, millet_binder_switch,
		   millet_freezebinder_enabled(), millet_binder_registry_ready(),
		   frozen_uid_min,
		   binder_warn_ahead_space);
	seq_printf(seq, "lists monitored=%u core=%u black_pid=%u black_uid=%u\n",
		   monitored, core, black_pid, black_uid);
	for (i = 1; i < MILLET_TYPE_COUNT; i++)
		seq_printf(seq,
			   "%s owner=%d port=%d route=%d route_port=%d recv=%lld sent=%lld failed=%lld\n",
			   names[i], i, atomic_read(&millet_ports[i]),
			   millet_monitor_for_owner(i),
			   atomic_read(&millet_ports[millet_monitor_for_owner(i)]),
			   atomic64_read(&millet_received[i]),
			   atomic64_read(&millet_sent[i]),
			   atomic64_read(&millet_failed[i]));
	return 0;
}

static ssize_t millet_stats_write(struct file *file, const char __user *buf,
				  size_t count, loff_t *ppos)
{
	char value;
	int i;

	if (!count)
		return 0;
	if (get_user(value, buf))
		return -EFAULT;
	if (value != '1')
		return count;
	for (i = 1; i < MILLET_TYPE_COUNT; i++) {
		atomic64_set(&millet_sent[i], 0);
		atomic64_set(&millet_failed[i], 0);
	}
	return count;
}

static int millet_stats_open(struct inode *inode, struct file *file)
{
	return single_open(file, millet_stats_show, NULL);
}

static const struct proc_ops millet_stats_ops = {
	.proc_open = millet_stats_open,
	.proc_read = seq_read,
	.proc_write = millet_stats_write,
	.proc_lseek = seq_lseek,
	.proc_release = single_release,
};

static int millet_version_show(struct seq_file *seq, void *unused)
{
	/* Current SM8750 HyperOS millet_core.ko exports VERSION_1_0. */
	seq_puts(seq, "1\n");
	return 0;
}

static int millet_version_open(struct inode *inode, struct file *file)
{
	return single_open(file, millet_version_show, NULL);
}

static const struct proc_ops millet_version_ops = {
	.proc_open = millet_version_open,
	.proc_read = seq_read,
	.proc_lseek = seq_lseek,
	.proc_release = single_release,
};

static int __init millet_bridge_init(void)
{
	struct netlink_kernel_cfg cfg = { .input = millet_recv };
	int ret;
	int i;

	static_assert(sizeof(struct millet_userconf) == 80);
	static_assert(sizeof(struct millet_data) == 144);
	static_assert(offsetof(struct millet_data, priv) == 104);

	for (i = 0; i < MILLET_TYPE_COUNT; i++) {
		atomic_set(&millet_ports[i], 0);
		atomic64_set(&millet_sent[i], 0);
		atomic64_set(&millet_failed[i], 0);
		atomic64_set(&millet_received[i], 0);
	}

	millet_nl_sock = netlink_kernel_create(&init_net, MILLET_NETLINK_PROTO, &cfg);
	if (!millet_nl_sock) {
		pr_err("cannot create raw netlink protocol %d\n", MILLET_NETLINK_PROTO);
		return -EADDRINUSE;
	}

	millet_proc_dir = proc_mkdir("millet", NULL);
	if (millet_proc_dir) {
		proc_create("millet_stat", 0644, millet_proc_dir, &millet_stats_ops);
		proc_create("version", 0644, millet_proc_dir, &millet_version_ops);
	}

	if (millet_enable_pkg) {
		ret = millet_pkg_register();
		if (ret)
			goto err_pkg;
	}
	if (millet_enable_signal) {
		ret = millet_signal_register();
		if (ret)
			goto err_signal;
	}
	if (millet_enable_binder) {
		ret = millet_binder_register();
		if (ret)
			goto err_binder;
	}

	pr_info("loaded protocol=%d abi=%zu/%zu hooks=%d/%d/%d\n",
		MILLET_NETLINK_PROTO, sizeof(struct millet_userconf),
		sizeof(struct millet_data), millet_enable_pkg,
		millet_enable_signal, millet_enable_binder);
	return 0;

err_binder:
	if (millet_enable_signal)
		millet_signal_unregister();
err_signal:
	if (millet_enable_pkg)
		millet_pkg_unregister();
err_pkg:
	remove_proc_subtree("millet", NULL);
	netlink_kernel_release(millet_nl_sock);
	millet_nl_sock = NULL;
	return ret;
}

static void __exit millet_bridge_exit(void)
{
	if (millet_enable_binder)
		millet_binder_unregister();
	if (millet_enable_signal)
		millet_signal_unregister();
	if (millet_enable_pkg)
		millet_pkg_unregister();
	remove_proc_subtree("millet", NULL);
	if (millet_nl_sock)
		netlink_kernel_release(millet_nl_sock);
	pr_info("unloaded\n");
}

module_init(millet_bridge_init);
module_exit(millet_bridge_exit);

MODULE_LICENSE("GPL v2");
MODULE_AUTHOR("MIO compatibility research");
MODULE_DESCRIPTION("Xiaomi Millet raw-netlink/event bridge for OnePlus Android 15 kernel");
MODULE_VERSION("0.3.2");
