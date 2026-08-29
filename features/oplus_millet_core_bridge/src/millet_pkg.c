// SPDX-License-Identifier: GPL-2.0
#define pr_fmt(fmt) "millet_core: pkg: " fmt

#include <linux/module.h>
#include <linux/netfilter.h>
#include <linux/netfilter_ipv4.h>
#include <linux/netfilter_ipv6.h>
#include <linux/skbuff.h>
#include <net/ip.h>
#include <net/ipv6.h>
#include <net/net_namespace.h>
#include <net/sock.h>
#include <net/tcp.h>

#include "millet_bridge.h"

#define MILLET_UID_SLOTS 64
#define MILLET_CORE_UID_SLOTS 74
#define MILLET_BLACK_SLOTS 10

static atomic_t monitor_uids[MILLET_UID_SLOTS];
atomic_t core_uid_rec[MILLET_CORE_UID_SLOTS];
atomic_t core_black_pid_rec[MILLET_BLACK_SLOTS];
atomic_t core_black_uid_rec[MILLET_BLACK_SLOTS];
int freezebinder_enable;
static bool pkg_registered;

EXPORT_SYMBOL_GPL(core_uid_rec);
EXPORT_SYMBOL_GPL(core_black_pid_rec);
EXPORT_SYMBOL_GPL(core_black_uid_rec);
EXPORT_SYMBOL_GPL(freezebinder_enable);

bool millet_freezebinder_enabled(void)
{
	return READ_ONCE(freezebinder_enable) != 0;
}

static bool millet_array_has(atomic_t *array, int count, int value)
{
	int i;

	for (i = 0; i < count; i++)
		if (atomic_read(&array[i]) == value)
			return true;
	return false;
}

bool millet_binder_caller_allowed(int caller_uid, int caller_pid,
				  int target_uid)
{
	int app_id;

	/* This is find_and_clear_piduid() from the SM8750 millet_pkg KO. */
	if (caller_uid <= 0 || !millet_freezebinder_enabled())
		return true;
	if (millet_array_has(core_uid_rec, MILLET_CORE_UID_SLOTS, target_uid))
		return true;
	if (millet_array_has(core_black_pid_rec, MILLET_BLACK_SLOTS, caller_pid))
		return false;

	app_id = caller_uid % 100000;
	if (app_id < frozen_uid_min)
		return !millet_array_has(core_black_uid_rec, MILLET_BLACK_SLOTS, app_id);
	return millet_array_has(core_uid_rec, MILLET_CORE_UID_SLOTS, caller_uid);
}

static void millet_array_add(atomic_t *array, int count, int value)
{
	int empty = -1;
	int i;

	if (value <= 0)
		return;
	for (i = 0; i < count; i++) {
		int old = atomic_read(&array[i]);

		if (old == value)
			return;
		if (!old && empty < 0)
			empty = i;
	}
	if (empty >= 0)
		atomic_cmpxchg(&array[empty], 0, value);
}

static void millet_array_del(atomic_t *array, int count, int value)
{
	int i;

	for (i = 0; i < count; i++)
		if (atomic_cmpxchg(&array[i], value, 0) == value)
			return;
}

static void millet_array_clear(atomic_t *array, int count)
{
	int i;

	for (i = 0; i < count; i++)
		atomic_set(&array[i], 0);
}

static unsigned int millet_array_count(atomic_t *array, int count)
{
	unsigned int used = 0;
	int i;

	for (i = 0; i < count; i++)
		if (atomic_read(&array[i]) != 0)
			used++;
	return used;
}

void millet_pkg_get_counts(unsigned int *monitored, unsigned int *core,
			   unsigned int *black_pid, unsigned int *black_uid)
{
	if (monitored)
		*monitored = millet_array_count(monitor_uids, MILLET_UID_SLOTS);
	if (core)
		*core = millet_array_count(core_uid_rec, MILLET_CORE_UID_SLOTS);
	if (black_pid)
		*black_pid = millet_array_count(core_black_pid_rec, MILLET_BLACK_SLOTS);
	if (black_uid)
		*black_uid = millet_array_count(core_black_uid_rec, MILLET_BLACK_SLOTS);
}

static bool millet_uid_take(int uid)
{
	int i;

	for (i = 0; i < MILLET_UID_SLOTS; i++)
		if (atomic_cmpxchg(&monitor_uids[i], uid, 0) == uid)
			return true;
	return false;
}

void millet_note_pkg_command(const struct millet_userconf *msg)
{
	int cmd = msg->priv.pkg.cmd;
	int value = msg->priv.pkg.uid;

	if (millet_debug)
		pr_info("command=%d value=%d\n", cmd, value);

	switch (cmd) {
	case MILLET_PKG_ADD_UID:
		millet_array_add(monitor_uids, MILLET_UID_SLOTS, value);
		break;
	case MILLET_PKG_DEL_UID:
		millet_array_del(monitor_uids, MILLET_UID_SLOTS, value);
		break;
	case MILLET_PKG_CLEAR_UID:
		millet_array_clear(monitor_uids, MILLET_UID_SLOTS);
		millet_array_clear(core_uid_rec, MILLET_CORE_UID_SLOTS);
		millet_array_clear(core_black_pid_rec, MILLET_BLACK_SLOTS);
		millet_array_clear(core_black_uid_rec, MILLET_BLACK_SLOTS);
		WRITE_ONCE(freezebinder_enable, 0);
		break;
	case MILLET_PKG_ADD_CORE_UID:
		if (value == 111) {
			struct millet_data ack = { };

			WRITE_ONCE(freezebinder_enable, 1);
			/* Official acknowledgement: reportNet(111) enables new ABI. */
			ack.owner = MILLET_TYPE_PKG;
			ack.msg_type = MILLET_MSG_TO_USER;
			ack.uid = 111;
			ack.priv.pkg.pkg_owner = 111;
			millet_send_event(&ack);
		} else {
			millet_array_add(core_uid_rec, MILLET_CORE_UID_SLOTS, value);
		}
		break;
	case MILLET_PKG_DEL_CORE_UID:
		if (value == 111)
			WRITE_ONCE(freezebinder_enable, 0);
		else
			millet_array_del(core_uid_rec, MILLET_CORE_UID_SLOTS, value);
		break;
	case MILLET_PKG_ADD_BLACK_PID:
		millet_array_add(core_black_pid_rec, MILLET_BLACK_SLOTS, value);
		break;
	case MILLET_PKG_DEL_BLACK_PID:
		millet_array_del(core_black_pid_rec, MILLET_BLACK_SLOTS, value);
		break;
	case MILLET_PKG_ADD_BLACK_UID:
		millet_array_add(core_black_uid_rec, MILLET_BLACK_SLOTS, value);
		break;
	case MILLET_PKG_DEL_BLACK_UID:
		millet_array_del(core_black_uid_rec, MILLET_BLACK_SLOTS, value);
		break;
	default:
		break;
	}
}

static uid_t millet_sock_uid(struct sock *sk)
{
	uid_t uid = 0;

	if (!sk)
		return 0;
	read_lock_bh(&sk->sk_callback_lock);
	if (sk->sk_socket)
		uid = SOCK_INODE(sk->sk_socket)->i_uid.val;
	read_unlock_bh(&sk->sk_callback_lock);
	return uid;
}

static unsigned int millet_pkg_in(void *priv, struct sk_buff *skb,
				  const struct nf_hook_state *state)
{
	struct millet_data data = { };
	struct sock *sk;
	uid_t uid;

	if (!skb || !state || state->hook != NF_INET_LOCAL_IN)
		return NF_ACCEPT;

	if (state->pf == NFPROTO_IPV4) {
		if (!pskb_may_pull(skb, sizeof(struct iphdr)) ||
		    ip_hdr(skb)->protocol != IPPROTO_TCP)
			return NF_ACCEPT;
#if IS_ENABLED(CONFIG_IPV6)
	} else if (state->pf == NFPROTO_IPV6) {
		unsigned int offset = 0;
		unsigned short frag = 0;

		if (ipv6_find_hdr(skb, &offset, -1, &frag, NULL) != IPPROTO_TCP)
			return NF_ACCEPT;
#endif
	} else {
		return NF_ACCEPT;
	}

	sk = skb_to_full_sk(skb);
	if (!sk || !sk_fullsock(sk))
		return NF_ACCEPT;
	uid = millet_sock_uid(sk);
	/* Stock packet wake uses the fixed Android app-UID boundary. */
	if (uid < MILLET_UID_MIN || !millet_uid_take(uid))
		return NF_ACCEPT;

	data.owner = MILLET_TYPE_PKG;
	data.msg_type = MILLET_MSG_TO_USER;
	data.uid = uid;
	data.priv.pkg.pkg_owner = uid;
	data.priv.pkg.owner_pid = 0;
	millet_send_event(&data);
	return NF_ACCEPT;
}

static struct nf_hook_ops millet_nf_ops[] = {
	{
		.hook = millet_pkg_in,
		.pf = NFPROTO_IPV4,
		.hooknum = NF_INET_LOCAL_IN,
		.priority = NF_IP_PRI_SELINUX_LAST + 1,
	},
#if IS_ENABLED(CONFIG_IPV6)
	{
		.hook = millet_pkg_in,
		.pf = NFPROTO_IPV6,
		.hooknum = NF_INET_LOCAL_IN,
		.priority = NF_IP6_PRI_SELINUX_LAST + 1,
	},
#endif
};

int millet_pkg_register(void)
{
	int ret;

	millet_array_clear(monitor_uids, MILLET_UID_SLOTS);
	millet_array_clear(core_uid_rec, MILLET_CORE_UID_SLOTS);
	millet_array_clear(core_black_pid_rec, MILLET_BLACK_SLOTS);
	millet_array_clear(core_black_uid_rec, MILLET_BLACK_SLOTS);
	WRITE_ONCE(freezebinder_enable, 0);
	ret = nf_register_net_hooks(&init_net, millet_nf_ops,
				    ARRAY_SIZE(millet_nf_ops));
	if (!ret)
		pkg_registered = true;
	return ret;
}

void millet_pkg_unregister(void)
{
	if (pkg_registered) {
		nf_unregister_net_hooks(&init_net, millet_nf_ops,
					ARRAY_SIZE(millet_nf_ops));
		pkg_registered = false;
	}
}
