/* Diagnostic client: send the official Millet owner-6 MSG_TO_KERN frame. */
#include <errno.h>
#include <linux/netlink.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#define MILLET_PROTO 31
#define MILLET_KERNEL_ID 0x12341234ULL
#define MILLET_USER_ID   0xabcddcbaULL

struct millet_userconf {
    int32_t owner;
    int32_t msg_type;
    uint64_t src_port;
    uint64_t dst_port;
    uint64_t pri[6];
    uint64_t data;
};

struct millet_frame {
    struct nlmsghdr hdr;
    struct millet_userconf msg;
};

int main(void)
{
    struct sockaddr_nl local = { .nl_family = AF_NETLINK, .nl_pid = getpid() };
    struct sockaddr_nl kernel = { .nl_family = AF_NETLINK, .nl_pid = 0 };
    struct millet_frame frame;
    int fd;

    _Static_assert(sizeof(struct millet_userconf) == 80, "Millet ABI mismatch");
    _Static_assert(sizeof(struct millet_frame) == 96, "Netlink ABI mismatch");

    fd = socket(AF_NETLINK, SOCK_RAW, MILLET_PROTO);
    if (fd < 0) {
        fprintf(stderr, "socket: %s\n", strerror(errno));
        return 1;
    }
    if (bind(fd, (struct sockaddr *)&local, sizeof(local)) < 0) {
        fprintf(stderr, "bind: %s\n", strerror(errno));
        close(fd);
        return 2;
    }

    memset(&frame, 0, sizeof(frame));
    frame.hdr.nlmsg_len = sizeof(frame);
    frame.hdr.nlmsg_pid = getpid();
    frame.msg.owner = 6;
    frame.msg.msg_type = 3;
    frame.msg.src_port = MILLET_USER_ID;
    frame.msg.dst_port = MILLET_KERNEL_ID;

    if (sendto(fd, &frame, sizeof(frame), 0,
               (struct sockaddr *)&kernel, sizeof(kernel)) != sizeof(frame)) {
        fprintf(stderr, "sendto: %s\n", strerror(errno));
        close(fd);
        return 3;
    }
    puts("sent Millet HANDSHK request");
    close(fd);
    return 0;
}
