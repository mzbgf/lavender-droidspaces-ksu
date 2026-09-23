/*
 * Smoke test host for the anland backend: create the backend against the mock
 * daemon, start it, drive the event loop, and report what happened.
 */
#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <wayland-server-core.h>
#include <wlr/backend.h>
#include <wlr/backend/anland.h>
#include <wlr/backend/interface.h>
#include <wlr/render/allocator.h>
#include <wlr/render/pass.h>
#include <wlr/render/pixman.h>
#include <wlr/types/wlr_input_device.h>
#include <wlr/types/wlr_output.h>
#include <wlr/util/log.h>

static int outputs_seen = 0;
static int inputs_seen = 0;
static struct wlr_output *the_output = NULL;

static void on_new_output(struct wl_listener *listener, void *data) {
	struct wlr_output *output = data;
	outputs_seen++;
	the_output = output;
	printf("host: new_output name=%s %dx%d refresh=%d impl_is_anland=%d\n",
		output->name, output->width, output->height, output->refresh,
		wlr_output_is_anland(output));
	fflush(stdout);
}

static void on_new_input(struct wl_listener *listener, void *data) {
	struct wlr_input_device *dev = data;
	inputs_seen++;
	printf("host: new_input type=%d name=%s\n", dev->type,
		dev->name ? dev->name : "(none)");
	fflush(stdout);
}

int main(void) {
	wlr_log_init(WLR_DEBUG, NULL);

	setenv("ANLAND_SOCKET", "/tmp/anland-test.sock", 1);

	struct wl_display *display = wl_display_create();
	if (!display) {
		fprintf(stderr, "host: wl_display_create failed\n");
		return 1;
	}
	struct wl_event_loop *loop = wl_display_get_event_loop(display);

	struct wlr_backend *backend = wlr_anland_backend_create(loop);
	if (!backend) {
		fprintf(stderr, "host: FAIL wlr_anland_backend_create\n");
		return 1;
	}
	printf("host: backend created, is_anland=%d\n",
		wlr_backend_is_anland(backend));
	fflush(stdout);

	struct wl_listener new_output = { .notify = on_new_output };
	struct wl_listener new_input = { .notify = on_new_input };
	wl_signal_add(&backend->events.new_output, &new_output);
	wl_signal_add(&backend->events.new_input, &new_input);

	if (!wlr_backend_start(backend)) {
		fprintf(stderr, "host: FAIL wlr_backend_start\n");
		return 1;
	}
	printf("host: backend started\n");
	fflush(stdout);

	// Let the reconnect timer pick up the consumer and import its dmabufs.
	for (int i = 0; i < 6; i++) {
		wl_event_loop_dispatch(loop, 50);
	}

	/*
	 * Compose one frame the way a real compositor does (pixman renderer: the
	 * container has no GPU) and commit it. The backend must copy it into the
	 * consumer's selected buffer and trigger_refresh().
	 */
	if (the_output != NULL) {
		// Enable the output first: wlroots rejects buffer commits on a
		// disabled output (sway does this enable commit on new_output).
		{
			struct wlr_output_state en;
			wlr_output_state_init(&en);
			wlr_output_state_set_enabled(&en, true);
			bool ok = wlr_output_commit_state(the_output, &en);
			printf("host: enable commit ok=%d\n", ok);
			wlr_output_state_finish(&en);
		}

		struct wlr_renderer *renderer = wlr_pixman_renderer_create();
		struct wlr_allocator *alloc = renderer ?
			wlr_allocator_autocreate(backend, renderer) : NULL;
		if (renderer && alloc && wlr_output_init_render(the_output,
				alloc, renderer)) {
			struct wlr_output_state state;
			wlr_output_state_init(&state);
			struct wlr_render_pass *pass =
				wlr_output_begin_render_pass(the_output, &state,
					NULL, NULL);
			if (pass) {
				wlr_render_pass_add_rect(pass,
					&(struct wlr_render_rect_options){
					.box = { .width = the_output->width,
						.height = the_output->height },
					.color = { .r = 0.25, .g = 0.5,
						.b = 0.75, .a = 1.0 },
					.blend_mode = WLR_RENDER_BLEND_MODE_NONE,
				});
				wlr_render_pass_submit(pass);
				bool ok = wlr_output_commit_state(the_output, &state);
				printf("host: frame commit ok=%d\n", ok);
			} else {
				printf("host: begin_render_pass failed\n");
			}
			wlr_output_state_finish(&state);
		} else {
			printf("host: pixman render setup failed\n");
		}
	}

	// Drive the loop so buffer-ready, input and trigger_refresh paths run.
	for (int i = 0; i < 30; i++) {
		wl_event_loop_dispatch(loop, 50);
		wl_display_flush_clients(display);
	}

	printf("host: outputs_seen=%d inputs_seen=%d\n", outputs_seen, inputs_seen);
	fflush(stdout);

	wlr_backend_destroy(backend);
	wl_display_destroy(display);

	printf("host: %s\n",
		(outputs_seen == 1 && inputs_seen == 3) ? "HOST_OK" : "HOST_FAIL");
	return (outputs_seen == 1 && inputs_seen == 3) ? 0 : 1;
}
