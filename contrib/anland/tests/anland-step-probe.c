/*
 * Probe: which step of the producer's try_exit_fallback() fails?
 *
 * Links display_producer.c + socket_utils.c and drives the real daemon and the
 * real consumer (the Android app). Prints per-attempt which of the two steps
 * failed so we can tell "the daemon never hands the fds over" apart from
 * "the consumer never pushes its dmabuf set in time".
 *
 * Build (in the Debian 13 arm64 container):
 *   cc -O0 -g -o anland-step-probe anland-step-probe.c \
 *      display_producer.c socket_utils.c
 * Run (in the Droidspaces container):
 *   ANLAND_SOCKET=/opt/anland/display_daemon.sock ./anland-step-probe
 */
#include <errno.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "display_producer.h"
#include "protocol.h"
#include "socket_utils.h"

/* Mirrors the statics in display_producer.c — see HANDSHAKE_TIMEOUT_MS there. */
#define HANDSHAKE_TIMEOUT_MS 100

int main(int argc, char **argv)
{
	const char *sock = getenv("ANLAND_SOCKET");
	if (!sock)
		sock = "/opt/anland/display_daemon.sock";

	display_ctx *ctx = NULL;
	if (connect_to_deamon(&ctx, sock) < 0) {
		fprintf(stderr, "connect_to_deamon(%s) failed: %s\n", sock, strerror(errno));
		return 1;
	}
	printf("connected; is_fallback=%d\n", (int)is_fallback(ctx));

	for (int attempt = 0; attempt < 20; attempt++) {
		/*
		 * Re-implement try_exit_fallback() one step at a time so we can
		 * see which half fails. Keep it in lockstep with
		 * display_producer.c — if that file changes, this drifts.
		 */
		if (!is_fallback(ctx)) {
			printf("[%02d] already out of fallback\n", attempt);
			break;
		}

		int rv = try_exit_fallback(ctx);
		int buf_count = get_buf_count(ctx);
		int data_fd = get_data_fd(ctx);
		int buf_ready = get_buffer_ready_fd(ctx);
		printf("[%02d] try_exit_fallback=%d buf_count=%d data_fd=%d buf_ready_efd=%d "
		       "still_fallback=%d\n",
		       attempt, rv, buf_count, data_fd, buf_ready, (int)is_fallback(ctx));
		if (rv == 0) {
			printf("SUCCESS after %d attempt(s)\n", attempt + 1);
			printf("buf_count=%d selected=%d\n", buf_count, get_selected_idx(ctx));
			for (int i = 0; i < buf_count && i < MAX_BUFS; i++) {
				struct buf_info info;
				int fd = get_dmabuf_fd_at(ctx, i);
				int irv = get_dmabuf_info_at(ctx, i, &info);
				printf("  buf[%d] fd=%d info_rv=%d fmt=%u stride=%u mod=%llu off=%u\n",
				       i, fd, irv, info.format, info.stride,
				       (unsigned long long)info.modifier, info.offset);
			}
			return 0;
		}
		usleep(200 * 1000);
	}
	fprintf(stderr, "try_exit_fallback never succeeded\n");
	return 2;
}
