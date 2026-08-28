/* SPDX-License-Identifier: GPL-2.0 */
#ifndef MIO_MILLET_BRIDGE_H
#define MIO_MILLET_BRIDGE_H

#include <linux/atomic.h>
#include <linux/build_bug.h>
#include <linux/sched.h>
#include <linux/types.h>

#define MILLET_NETLINK_PROTO 31
#define MILLET_KERNEL_ID 0x12341234UL
#define MILLET_USER_ID   0xabcddcbaUL
#define MILLET_UID_MIN 10000
#define MILLET_EXT_LEN 6

enum millet_msg_type {
	MILLET_MSG_NONE = 0,
	MILLET_MSG_LOOPBACK = 1,
	MILLET_MSG_TO_USER = 2,
	MILLET_MSG_TO_KERN = 3,
};

enum millet_type {
	MILLET_TYPE_NONE = 0,
	MILLET_TYPE_SIGNAL = 1,
	MILLET_TYPE_BINDER = 2,
	MILLET_TYPE_BINDER_ST = 3,
	MILLET_TYPE_MEM = 4,
	MILLET_TYPE_PKG = 5,
	MILLET_TYPE_HANDSHAKE = 6,
	MILLET_TYPE_COUNT = 7,
};

enum millet_pkg_cmd {
	MILLET_PKG_NOP = 0,
	MILLET_PKG_ADD_UID = 1,
	MILLET_PKG_DEL_UID = 2,
	MILLET_PKG_CLEAR_UID = 3,
	MILLET_PKG_ADD_CORE_UID = 100,
	MILLET_PKG_DEL_CORE_UID = 101,
	MILLET_PKG_ADD_BLACK_PID = 102,
	MILLET_PKG_DEL_BLACK_PID = 103,
	MILLET_PKG_ADD_BLACK_UID = 104,
	MILLET_PKG_DEL_BLACK_UID = 105,
};

enum millet_binder_extra {
	MILLET_BINDER_BUFF_WARN = 0,
	MILLET_BINDER_REPLY = 1,
	MILLET_BINDER_TRANS = 2,
	MILLET_BINDER_THREAD_HAS_WORK = 3,
};

enum millet_binder_stat {
	BINDER_IN_IDLE = 0,
	BINDER_IN_BUSY = 1,
	BINDER_THREAD_IN_BUSY = 2,
	BINDER_PROC_IN_BUSY = 3,
	BINDER_IN_TRANSACTION = 4,
};

struct millet_timestamp {
	u64 sec;
	s64 nsec;
};

struct millet_signal_data {
	void *caller_task;
	void *killed_task;
	s32 killed_pid;
	s32 reason;
};

struct millet_binder_stat_data {
	void *task;
	s32 pid;
	s32 tid;
	s32 reason;
};

struct millet_binder_trans_data {
	void *src_task;
	void *dst_task;
	s32 caller_uid;
	s32 caller_pid;
	s32 caller_tid;
	s32 dst_pid;
	u8 tf_oneway;
	u8 reserved[3];
	u32 code;
};

struct millet_pkg_data {
	s32 pkg_owner;
	s32 owner_pid;
};

union millet_kernel_private {
	struct millet_signal_data signal;
	union {
		struct millet_binder_stat_data stat;
		struct millet_binder_trans_data trans;
	} binder;
	struct millet_pkg_data pkg;
	u8 raw[40];
};

struct millet_data {
	s32 owner;
	s32 monitor;
	s32 msg_type;
	u32 align0;
	u64 src_port;
	u64 dst_port;
	s32 uid;
	u32 align1;
	struct millet_timestamp tm;
	u64 pri[MILLET_EXT_LEN];
	union millet_kernel_private priv;
};

struct millet_userconf {
	s32 owner;
	s32 msg_type;
	u64 src_port;
	u64 dst_port;
	u64 pri[MILLET_EXT_LEN];
	union {
		u64 data;
		struct {
			s32 cmd;
			s32 uid;
		} pkg;
		struct {
			s32 uid;
			s32 reserved;
		} binder_st;
	} priv;
};

extern bool millet_enable_pkg;
extern bool millet_enable_signal;
extern bool millet_enable_binder;
extern unsigned int millet_debug;
extern int frozen_uid_min;
extern unsigned long binder_warn_ahead_space;
extern int millet_freeze_switch;
extern bool millet_binder_switch;

bool judge_millet_freeze_switch(void);

int millet_send_event(struct millet_data *data);
bool millet_task_is_frozen(struct task_struct *task);
void millet_note_pkg_command(const struct millet_userconf *msg);
void millet_note_binder_command(const struct millet_userconf *msg);
bool millet_binder_caller_allowed(int caller_uid, int caller_pid,
				  int target_uid);
bool millet_freezebinder_enabled(void);
bool millet_binder_registry_ready(void);
void millet_pkg_get_counts(unsigned int *monitored, unsigned int *core,
			   unsigned int *black_pid, unsigned int *black_uid);

int millet_pkg_register(void);
void millet_pkg_unregister(void);
int millet_signal_register(void);
void millet_signal_unregister(void);
int millet_binder_register(void);
void millet_binder_unregister(void);

#endif
