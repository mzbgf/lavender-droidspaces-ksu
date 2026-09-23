/* Verify wlr_backend_autocreate() picks the anland backend the way stock
 * compositors do: WLR_BACKENDS=anland and ANLAND=1. */
#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wayland-server-core.h>
#include <wlr/backend.h>
#include <wlr/backend/anland.h>
#include <wlr/backend/interface.h>
#include <wlr/util/log.h>

static int outputs_seen = 0;
static struct wlr_output *the_output = NULL;

static void on_new_output(struct wl_listener *listener, void *data) {
	struct wlr_output *output = data;
	outputs_seen++;
	the_output = output;
	printf("auto: new_output name=%s %dx%d is_anland=%d\n",
		output->name, output->width, output->height,
		wlr_output_is_anland(output));
	fflush(stdout);
}

int main(int argc, char **argv) {
	wlr_log_init(WLR_INFO, NULL);
	setenv("ANLAND_SOCKET", "/tmp/anland-test.sock", 1);

	struct wl_display *display = wl_display_create();
	struct wl_event_loop *loop = wl_display_get_event_loop(display);

	struct wlr_session *session = NULL;
	struct wlr_backend *backend = wlr_backend_autocreate(loop, &session);
	if (!backend) {
		printf("auto: FAIL autocreate returned NULL\n");
		return 1;
	}
	printf("auto: autocreate ok (multi)\n");

	struct wl_listener new_output = { .notify = on_new_output };
	wl_signal_add(&backend->events.new_output, &new_output);

	if (!wlr_backend_start(backend)) {
		printf("auto: FAIL start\n");
		return 1;
	}
	for (int i = 0; i < 8; i++) {
		wl_event_loop_dispatch(loop, 50);
	}
	printf("auto: outputs_seen=%d\n", outputs_seen);

	bool ok = outputs_seen == 1 && the_output != NULL &&
		strcmp(the_output->name, "ANLAND-1") == 0 &&
		wlr_output_is_anland(the_output);
	printf("auto: %s\n", ok ? "AUTO_OK" : "AUTO_FAIL");

	wlr_backend_destroy(backend);
	return ok ? 0 : 1;
}
