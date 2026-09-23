//! anland backend: render the desktop into dmabufs owned by an Android consumer.
//!
//! On Android (Adreno + kgsl, no DRM) the compositor cannot scan out itself.
//! Instead, an Android app (the consumer) allocates a set of shared dmabufs and
//! presents them to SurfaceFlinger; this backend (the producer) renders niri
//! into whichever buffer the consumer currently wants and relays input events
//! back. A daemon matches producers and consumers over a Unix socket and
//! forwards the file descriptors.
//!
//! The producer-side protocol state machine is vendored unmodified in
//! `src/backend/anland/` (see `display_producer.h`); `ffi.rs` binds it.

use std::cell::RefCell;
use std::env;
use std::ffi::{c_void, CString};
use std::mem;
use std::os::fd::BorrowedFd;
use std::ptr;
use std::rc::Rc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use anyhow::{ensure, Context as _};
use calloop::generic::{FdWrapper, Generic};
use calloop::timer::{TimeoutAction, Timer};
use calloop::{Interest, LoopHandle, Mode as PollMode, PostAction, RegistrationToken};
use niri_config::{Config, OutputName};
use smithay::backend::allocator::dmabuf::{Dmabuf, DmabufFlags};
use smithay::backend::allocator::{Fourcc, Modifier};
use smithay::backend::egl::native::EGLSurfacelessDisplay;
use smithay::backend::egl::{EGLContext, EGLDisplay};
use smithay::backend::input::{Axis, ButtonState, KeyState, Keycode, TouchSlot};
use smithay::backend::input::InputEvent;
use smithay::backend::renderer::damage::OutputDamageTracker;
use smithay::backend::renderer::gles::GlesRenderer;
use smithay::backend::renderer::{Bind, DebugFlags, ImportDma, ImportEgl, Renderer};
use smithay::output::{Mode, Output, PhysicalProperties, Subpixel};
use smithay::reexports::wayland_protocols::wp::presentation_time::server::wp_presentation_feedback;
use smithay::reexports::wayland_server::protocol::wl_surface::WlSurface;
use smithay::utils::Size;
use smithay::wayland::dmabuf::{DmabufFeedbackBuilder, DmabufGlobal};
use smithay::wayland::presentation::Refresh;

use super::{IpcOutputMap, OutputId, RenderResult};
use crate::niri::{Niri, RedrawState, State};
use crate::render_helpers::debug::draw_damage;
use crate::render_helpers::{resources, shaders, RenderCtx, RenderTarget};
use crate::utils::{get_monotonic_time, logical_output};

mod ffi;
pub mod input;

use input::{
    AnlandInput, AnlandInputDevice, AnlandKeyboardEvent, AnlandPointerAxisEvent,
    AnlandPointerButtonEvent, AnlandPointerMotionAbsoluteEvent, AnlandTouchCancelEvent,
    AnlandTouchDownEvent, AnlandTouchFrameEvent, AnlandTouchMotionEvent, AnlandTouchUpEvent,
};

/// Default daemon socket path (override with `ANLAND_SOCKET`).
pub const DEFAULT_SOCKET_PATH: &str = "/opt/anland/display_daemon.sock";

/// Fallback refresh rate in mHz when the daemon reports none.
const DEFAULT_REFRESH: u32 = 60_000;

/// Cadence of the reconnect loop that polls `try_exit_fallback()` while no
/// consumer is present.
const RECONNECT_INTERVAL: Duration = Duration::from_millis(200);

/// Mirrors `MAX_BUFS` in `protocol.h`.
const MAX_BUFS: usize = 8;

pub struct Anland {
    config: Rc<RefCell<Config>>,
    event_loop: LoopHandle<'static, State>,

    /// Producer-side protocol state machine (owned by the C library).
    ctx: *mut ffi::display_ctx,

    renderer: GlesRenderer,
    output: Output,
    damage_tracker: OutputDamageTracker,
    dmabuf_global: Option<DmabufGlobal>,
    ipc_outputs: Arc<Mutex<IpcOutputMap>>,

    /// Screen size in physical pixels from `get_screen_info()`.
    screen_w: u32,
    screen_h: u32,
    /// Current refresh rate in mHz (may be updated by the consumer).
    refresh_mhz: u32,

    /// Consumer dmabuf set (imported on `try_exit_fallback()` success).
    dmabufs: Vec<Option<Dmabuf>>,
    buf_count: usize,
    /// Frame index of the last render into each buffer; 0 = never rendered.
    last_used_frame: [u64; MAX_BUFS],
    frame_counter: u64,

    /// A buffer-ready notification has been received but not yet answered with
    /// `trigger_refresh()`. At most one trigger per buffer-ready, matching
    /// weston: it keeps the consumer's 5 second watchdog fed without writing a
    /// buffer the consumer may still be reading.
    consumer_ready: bool,

    /// Set from the C fallback callback when the consumer goes away.
    /// Heap-allocated so the pointer given to C stays valid.
    fallback_pending: Box<AtomicBool>,

    reconnect_timer_token: RegistrationToken,
    buf_ready_token: Option<RegistrationToken>,
    data_token: Option<RegistrationToken>,

    /// Number of keys currently held down (for `KeyboardKeyEvent::count`).
    keys_pressed: u32,
    /// `INPUT_TYPE_DISPLAY_REFRESH` updated the advertised mode.
    refresh_changed: bool,
}

extern "C" fn on_fallback(userdata: *mut c_void) {
    // Called from within poll_input_event() when the consumer disappears. The
    // fd sources are torn down by the data handler once it sees this flag.
    let flag = unsafe { &*userdata.cast::<AtomicBool>() };
    flag.store(true, Ordering::Release);
}

impl Anland {
    pub fn new(
        config: Rc<RefCell<Config>>,
        event_loop: LoopHandle<'static, State>,
    ) -> anyhow::Result<Self> {
        let _span = tracy_client::span!("Anland::new");

        let socket_path = env::var("ANLAND_SOCKET")
            .unwrap_or_else(|_| DEFAULT_SOCKET_PATH.to_owned());
        let socket_path_c = CString::new(socket_path.as_str())
            .context("ANLAND_SOCKET contains a nul byte")?;

        let mut ctx = ptr::null_mut();
        let ret = unsafe { ffi::connect_to_deamon(&mut ctx, socket_path_c.as_ptr()) };
        ensure!(
            ret == 0 && !ctx.is_null(),
            "error connecting to the anland daemon at {socket_path}",
        );
        info!("anland: connected to daemon at {socket_path}");

        // Heap-allocate so the pointer handed to C outlives the move into Self.
        let fallback_pending = Box::new(AtomicBool::new(false));
        unsafe {
            ffi::set_fallback_callback(
                ctx,
                Some(on_fallback),
                (&*fallback_pending as *const AtomicBool).cast_mut().cast(),
            );
        }

        let (mut width, mut height, mut format, mut refresh) = (0u32, 0u32, 0u32, 0u32);
        unsafe { ffi::get_screen_info(ctx, &mut width, &mut height, &mut format, &mut refresh) };
        // The consumer-side pixel format of the buffers is per-buf (buf_info),
        // so the screen_info format is not used here.
        debug!("anland: screen_info format {format}");
        ensure!(width > 0 && height > 0, "daemon reported a zero screen size");
        if refresh == 0 {
            refresh = DEFAULT_REFRESH;
        }
        info!("anland: screen {width}x{height}, refresh {refresh} mHz");

        // Same GL setup as the headless backend: there is no window system on
        // this device, we render into the consumer's dmabufs via FBOs.
        let renderer = unsafe {
            let display =
                EGLDisplay::new(EGLSurfacelessDisplay).context("error creating EGL display")?;
            let context = EGLContext::new(&display).context("error creating EGL context")?;
            GlesRenderer::new(context).context("error creating renderer")?
        };

        let connector = "anland-1".to_string();
        let make = "anland".to_string();
        let model = "anland".to_string();
        let serial = "1".to_string();

        let output = Output::new(
            connector.clone(),
            PhysicalProperties {
                size: (0, 0).into(),
                subpixel: Subpixel::Unknown,
                make: make.clone(),
                model: model.clone(),
                serial_number: serial.clone(),
            },
        );

        let mode = Mode {
            size: Size::from((width as i32, height as i32)),
            refresh: refresh as i32,
        };
        output.change_current_state(Some(mode), None, None, None);
        output.set_preferred(mode);

        output.user_data().insert_if_missing(|| OutputName {
            connector,
            make: Some(make),
            model: Some(model),
            serial: Some(serial),
        });

        let physical_properties = output.physical_properties();
        let ipc_outputs = Arc::new(Mutex::new(std::iter::once((
            OutputId::next(),
            niri_ipc::Output {
                name: output.name(),
                make: physical_properties.make,
                model: physical_properties.model,
                serial: None,
                physical_size: None,
                modes: vec![niri_ipc::Mode {
                    width: width.clamp(0, u16::MAX as u32) as u16,
                    height: height.clamp(0, u16::MAX as u32) as u16,
                    refresh_rate: refresh,
                    is_preferred: true,
                }],
                current_mode: Some(0),
                is_custom_mode: true,
                vrr_supported: false,
                vrr_enabled: false,
                logical: Some(logical_output(&output)),
            },
        ))
        .collect()));

        let damage_tracker = OutputDamageTracker::from_output(&output);

        // connect_to_deamon() only did the daemon handshake, so we start in
        // fallback with no consumer fds or dmabufs. Drive the reconnect loop to
        // pick them up via try_exit_fallback() once a consumer appears.
        let reconnect_timer_token = event_loop
            .insert_source(
                Timer::from_duration(RECONNECT_INTERVAL),
                |_, _, state: &mut State| {
                    let connected = {
                        let this = state.backend.anland();
                        this.poll_connect()
                    };
                    if connected {
                        // Sets up the touch device on the seat.
                        state.process_input_event(InputEvent::<AnlandInput>::DeviceAdded {
                            device: AnlandInputDevice,
                        });
                    }
                    TimeoutAction::ToDuration(RECONNECT_INTERVAL)
                },
            )
            .map_err(|err| {
                anyhow::anyhow!("error registering the reconnect timer: {err:?}")
            })?;

        Ok(Self {
            config,
            event_loop,
            ctx,
            renderer,
            output,
            damage_tracker,
            dmabuf_global: None,
            ipc_outputs,
            screen_w: width,
            screen_h: height,
            refresh_mhz: refresh,
            dmabufs: (0..MAX_BUFS).map(|_| None).collect(),
            buf_count: 0,
            last_used_frame: [0; MAX_BUFS],
            frame_counter: 0,
            consumer_ready: false,
            fallback_pending,
            reconnect_timer_token,
            buf_ready_token: None,
            data_token: None,
            keys_pressed: 0,
            refresh_changed: false,
        })
    }

    pub fn init(&mut self, niri: &mut Niri) {
        if let Err(err) = self.renderer.bind_wl_display(&niri.display_handle) {
            // wl_drm is on its way out so this is expected on most modern distros.
            trace!("error binding legacy EGL to wl_display: {err}");
        }

        resources::init(&mut self.renderer);
        shaders::init(&mut self.renderer);

        {
            let config = self.config.borrow();
            if let Some(src) = config.animations.window_resize.custom_shader.as_deref() {
                shaders::set_custom_resize_program(&mut self.renderer, Some(src));
            }
            if let Some(src) = config.animations.window_close.custom_shader.as_deref() {
                shaders::set_custom_close_program(&mut self.renderer, Some(src));
            }
            if let Some(src) = config.animations.window_open.custom_shader.as_deref() {
                shaders::set_custom_open_program(&mut self.renderer, Some(src));
            }
        }

        niri.update_shaders();

        self.create_dmabuf_global(niri);

        niri.add_output(
            self.output.clone(),
            Some(self.refresh_interval()),
            false,
        );
    }

    fn refresh_interval(&self) -> Duration {
        // refresh_mhz is in mHz: interval (ns) = 1e12 / refresh_mhz.
        Duration::from_nanos(1_000_000_000_000 / u64::from(self.refresh_mhz.max(1)))
    }

    pub fn create_dmabuf_global(&mut self, niri: &mut Niri) {
        // Identical to the winit backend: let clients allocate dmabufs our GL
        // context can import. Note that the EGL device here is kgsl, which has
        // no DRM render node; we fall back to the plain v3 global in that case.
        let default_feedback = || {
            use smithay::backend::egl::EGLDevice;

            let display = self.renderer.egl_context().display();
            let device = EGLDevice::device_for_display(display).context("error getting EGL device")?;
            let node = device
                .try_get_render_node()
                .context("error getting EGL device render node")?
                .context("failed to query EGL device render node")?;

            let primary_formats = self.renderer.dmabuf_formats();
            DmabufFeedbackBuilder::new(node.dev_id(), primary_formats)
                .build()
                .context("error building dmabuf feedback")
        };

        let dmabuf_global = match default_feedback() {
            Ok(feedback) => niri
                .dmabuf_state
                .create_global_with_default_feedback::<State>(&niri.display_handle, &feedback),
            Err(err) => {
                debug!("failed building default dmabuf feedback, falling back to v3: {err:?}");
                let primary_formats = self.renderer.dmabuf_formats();
                niri.dmabuf_state
                    .create_global::<State>(&niri.display_handle, primary_formats)
            }
        };
        assert!(self.dmabuf_global.replace(dmabuf_global).is_none());
    }

    pub fn seat_name(&self) -> String {
        "anland".to_owned()
    }

    pub fn with_primary_renderer<T>(
        &mut self,
        f: impl FnOnce(&mut GlesRenderer) -> T,
    ) -> Option<T> {
        Some(f(&mut self.renderer))
    }

    pub fn output(&self) -> &Output {
        &self.output
    }

    pub fn ipc_outputs(&self) -> Arc<Mutex<IpcOutputMap>> {
        self.ipc_outputs.clone()
    }

    pub fn toggle_debug_tint(&mut self) {
        let renderer = &mut self.renderer;
        renderer.set_debug_flags(renderer.debug_flags() ^ DebugFlags::TINT);
    }

    pub fn import_dmabuf(&mut self, dmabuf: &Dmabuf) -> bool {
        match self.renderer.import_dmabuf(dmabuf, None) {
            Ok(_texture) => true,
            Err(err) => {
                debug!("error importing dmabuf: {err:?}");
                false
            }
        }
    }

    pub fn early_import(&mut self, _surface: &WlSurface) {}

    /// Called on the 200 ms reconnect timer while waiting for a consumer.
    /// Returns true when a consumer just connected.
    fn poll_connect(&mut self) -> bool {
        if !unsafe { ffi::is_fallback(self.ctx) } {
            return false;
        }

        // -1 = still no consumer; retry on the next tick.
        if unsafe { ffi::try_exit_fallback(self.ctx) } != 0 {
            return false;
        }

        info!("anland: consumer connected");

        if let Err(err) = self.import_consumer_buffers() {
            warn!("anland: error importing consumer dmabufs: {err:?}");
        }
        self.register_consumer_sources();
        true
    }

    /// Wrap the consumer's dmabufs so we can render into them.
    ///
    /// `get_dmabuf_fd_at` only borrows the fd from the C context, so each
    /// `Dmabuf` gets its own dup: their lifetimes then don't depend on the
    /// producer library closing its copies when the consumer drops.
    fn import_consumer_buffers(&mut self) -> anyhow::Result<()> {
        let count = unsafe { ffi::get_buf_count(self.ctx) };
        ensure!(count > 0, "consumer provided no dmabufs");
        let count = usize::try_from(count).unwrap_or(0).clamp(1, MAX_BUFS);

        self.drop_consumer_buffers();

        for i in 0..count {
            let fd = unsafe { ffi::get_dmabuf_fd_at(self.ctx, i as i32) };
            ensure!(fd >= 0, "missing dmabuf fd at index {i}");

            let mut info: ffi::buf_info = unsafe { mem::zeroed() };
            let rv = unsafe { ffi::get_dmabuf_info_at(self.ctx, i as i32, &mut info) };
            ensure!(rv == 0, "missing dmabuf info at index {i}");

            let owned = unsafe { BorrowedFd::borrow_raw(fd) }
                .try_clone_to_owned()
                .context("error dup'ing consumer dmabuf fd")?;

            // buf_info.format 1 = Android RGBA_8888 = DRM ABGR8888; everything
            // else is treated as XRGB8888 (mirrors weston's
            // protocol_format_to_drm). modifier is currently always 0 = LINEAR.
            let format = if info.format == 1 {
                Fourcc::Abgr8888
            } else {
                Fourcc::Xrgb8888
            };
            let modifier = Modifier::from(info.modifier);

            let mut builder = Dmabuf::builder(
                (self.screen_w as i32, self.screen_h as i32),
                format,
                modifier,
                DmabufFlags::empty(),
            );
            let ok = builder.add_plane(owned, 0, info.offset, info.stride);
            ensure!(ok, "failed to add dmabuf plane for buffer {i}");
            let dmabuf = builder.build().context("error building Dmabuf")?;

            let stride = info.stride;
            info!(
                "anland: importing buf[{i}] {format:?} {}x{} stride={stride} mod={modifier:?}",
                self.screen_w, self.screen_h,
            );

            // A freshly imported dmabuf has undefined contents: leave
            // last_used_frame at 0 so the first render into it is a full
            // repaint (buffer age 0).
            self.dmabufs[i] = Some(dmabuf);
        }

        self.buf_count = count;
        self.last_used_frame = [0; MAX_BUFS];
        Ok(())
    }

    fn drop_consumer_buffers(&mut self) {
        for dmabuf in &mut self.dmabufs {
            *dmabuf = None;
        }
        self.buf_count = 0;
    }

    /// Watch the consumer's buffer-ready eventfd and its data channel.
    fn register_consumer_sources(&mut self) {
        // The C library owns these fds and closes them when the consumer goes
        // away; FdWrapper keeps the event loop from closing them as well (we
        // unregister the sources in on_consumer_lost).
        let buf_ready_fd = unsafe { ffi::get_buffer_ready_fd(self.ctx) };
        if buf_ready_fd >= 0 && self.buf_ready_token.is_none() {
            let source = Generic::new(
                unsafe { FdWrapper::new(buf_ready_fd) },
                Interest::READ,
                PollMode::Level,
            );
            match self
                .event_loop
                .insert_source(source, |_, _, state: &mut State| {
                    let output = {
                        let this = state.backend.anland();
                        if unsafe { ffi::is_fallback(this.ctx) } {
                            this.buf_ready_token = None;
                            return Ok(PostAction::Remove);
                        }
                        this.drain_buffer_ready_fd();
                        // The consumer is waiting for this buffer.
                        this.consumer_ready = true;
                        this.output.clone()
                    };
                    state.niri.queue_redraw(&output);
                    Ok(PostAction::Continue)
                }) {
                Ok(token) => self.buf_ready_token = Some(token),
                Err(err) => warn!("anland: error registering buffer-ready source: {err:?}"),
            }
        }

        let data_fd = unsafe { ffi::get_data_fd(self.ctx) };
        if data_fd >= 0 && self.data_token.is_none() {
            let source = Generic::new(
                unsafe { FdWrapper::new(data_fd) },
                Interest::READ,
                PollMode::Level,
            );
            match self
                .event_loop
                .insert_source(source, |_, _, state: &mut State| {
                    let mut events = Vec::new();
                    let mut lost = false;
                    let post = {
                        let this = state.backend.anland();
                        let mut fell_back = false;

                        loop {
                            let mut ev = mem::MaybeUninit::<ffi::InputEvent>::uninit();
                            let rv =
                                unsafe { ffi::poll_input_event(this.ctx, ev.as_mut_ptr(), 0) };
                            if rv > 0 {
                                let ev = unsafe { ev.assume_init() };
                                if let Some(event) = this.convert_event(ev) {
                                    events.push(event);
                                }
                            } else if rv < 0 {
                                // poll_input_event() already dropped us back to
                                // fallback and closed the consumer fds.
                                fell_back = true;
                                break;
                            } else {
                                break;
                            }
                        }

                        if fell_back
                            || this.fallback_pending.swap(false, Ordering::Acquire)
                        {
                            this.on_consumer_lost();
                            lost = true;
                            this.data_token = None;
                            PostAction::Remove
                        } else {
                            PostAction::Continue
                        }
                    };

                    if lost {
                        warn!("anland: consumer disconnected, entering fallback");
                        state.process_input_event(InputEvent::<AnlandInput>::TouchCancel {
                            event: AnlandTouchCancelEvent {
                                time: get_monotonic_time().as_micros() as u64,
                            },
                        });
                        state.process_input_event(InputEvent::<AnlandInput>::DeviceRemoved {
                            device: AnlandInputDevice,
                        });
                    }
                    if mem::take(&mut state.backend.anland().refresh_changed) {
                        state.niri.ipc_outputs_changed = true;
                    }
                    for event in events {
                        state.process_input_event(event);
                    }
                    Ok(post)
                }) {
                Ok(token) => self.data_token = Some(token),
                Err(err) => warn!("anland: error registering input source: {err:?}"),
            }
        }
    }

    fn drain_buffer_ready_fd(&self) {
        let fd = unsafe { ffi::get_buffer_ready_fd(self.ctx) };
        if fd < 0 {
            return;
        }
        // It's an eventfd: clear it with an 8-byte read.
        let mut buf = [0u8; 8];
        let _ = unsafe {
            libc::read(
                fd,
                buf.as_mut_ptr().cast::<c_void>(),
                buf.len(),
            )
        };
    }

    /// Consumer went away: the C library has already released the consumer
    /// resources; drop our render targets and go back to the reconnect loop.
    fn on_consumer_lost(&mut self) {
        self.drop_consumer_buffers();
        self.consumer_ready = false;
        self.keys_pressed = 0;
        self.fallback_pending.store(false, Ordering::Release);

        // The data source removes itself via PostAction::Remove.
        if let Some(token) = self.buf_ready_token.take() {
            self.event_loop.remove(token);
        }
    }

    /// Convert one wire event; also handles the non-input
    /// `INPUT_TYPE_DISPLAY_REFRESH`. Returns None to swallow the event.
    fn convert_event(&mut self, ev: ffi::InputEvent) -> Option<InputEvent<AnlandInput>> {
        let time = get_monotonic_time().as_micros() as u64;
        let screen_w = f64::from(self.screen_w);
        let screen_h = f64::from(self.screen_h);
        let type_ = ev.type_;
        let data = ev.data;

        match type_ {
            ffi::INPUT_TYPE_KEY => {
                let k = unsafe { data.key };
                let state = if k.action == ffi::INPUT_ACTION_DOWN {
                    KeyState::Pressed
                } else {
                    KeyState::Released
                };
                if state == KeyState::Pressed {
                    self.keys_pressed = self.keys_pressed.saturating_add(1);
                } else {
                    self.keys_pressed = self.keys_pressed.saturating_sub(1);
                }
                // The consumer sends Linux evdev codes; xkb wants evdev + 8.
                let key_code =
                    Keycode::from(u32::try_from(k.keycode).unwrap_or(0).saturating_add(8));
                Some(InputEvent::Keyboard {
                    event: AnlandKeyboardEvent {
                        time,
                        key_code,
                        state,
                        count: self.keys_pressed,
                    },
                })
            }
            ffi::INPUT_TYPE_POINTER_MOTION => {
                let m = unsafe { data.pointer_motion };
                Some(InputEvent::PointerMotionAbsolute {
                    event: AnlandPointerMotionAbsoluteEvent {
                        time,
                        x_px: f64::from(m.x),
                        y_px: f64::from(m.y),
                        screen_w,
                        screen_h,
                    },
                })
            }
            ffi::INPUT_TYPE_POINTER_BUTTON => {
                let b = unsafe { data.pointer_button };
                let state = if b.pressed != 0 {
                    ButtonState::Pressed
                } else {
                    ButtonState::Released
                };
                Some(InputEvent::PointerButton {
                    event: AnlandPointerButtonEvent {
                        time,
                        button_code: b.button,
                        state,
                    },
                })
            }
            ffi::INPUT_TYPE_POINTER_AXIS => {
                let a = unsafe { data.pointer_axis };
                // Protocol axis: 0 = vertical scroll, 1 = horizontal scroll.
                let axis = if a.axis == 0 {
                    Axis::Vertical
                } else {
                    Axis::Horizontal
                };
                Some(InputEvent::PointerAxis {
                    event: AnlandPointerAxisEvent {
                        time,
                        axis,
                        value: a.value,
                        discrete: a.discrete,
                    },
                })
            }
            ffi::INPUT_TYPE_TOUCH => {
                let t = unsafe { data.touch };
                let slot = TouchSlot::from(u32::try_from(t.pointer_id).ok());
                let (x_px, y_px) = (f64::from(t.x), f64::from(t.y));
                match t.action {
                    ffi::INPUT_ACTION_DOWN => Some(InputEvent::TouchDown {
                        event: AnlandTouchDownEvent {
                            time,
                            slot,
                            x_px,
                            y_px,
                            screen_w,
                            screen_h,
                        },
                    }),
                    ffi::INPUT_ACTION_UP => Some(InputEvent::TouchUp {
                        event: AnlandTouchUpEvent { time, slot },
                    }),
                    ffi::INPUT_ACTION_MOVE => Some(InputEvent::TouchMotion {
                        event: AnlandTouchMotionEvent {
                            time,
                            slot,
                            x_px,
                            y_px,
                            screen_w,
                            screen_h,
                        },
                    }),
                    _ => None,
                }
            }
            ffi::INPUT_TYPE_TOUCH_FRAME => Some(InputEvent::TouchFrame {
                event: AnlandTouchFrameEvent { time },
            }),
            ffi::INPUT_TYPE_DISPLAY_REFRESH => {
                // Not input: the consumer reports its live display refresh rate.
                let d = unsafe { data.display };
                let refresh_mhz = d.refresh_mhz;
                if refresh_mhz != 0 && refresh_mhz != self.refresh_mhz {
                    self.refresh_mhz = refresh_mhz;
                    self.refresh_changed = true;

                    // Update the advertised mode. Note: niri's FrameClock has
                    // no interval setter, so animation pacing keeps using the
                    // startup refresh rate (see the port notes).
                    let mode = Mode {
                        size: self.output.current_mode().unwrap().size,
                        refresh: refresh_mhz as i32,
                    };
                    self.output.change_current_state(Some(mode), None, None, None);
                    self.output.set_preferred(mode);

                    for output in self.ipc_outputs.lock().unwrap().values_mut() {
                        if let Some(m) = output.modes.first_mut() {
                            m.refresh_rate = refresh_mhz;
                        }
                    }
                }
                None
            }
            _ => None,
        }
    }

    pub fn render(&mut self, niri: &mut Niri, output: &Output) -> RenderResult {
        let _span = tracy_client::span!("Anland::render");

        if unsafe { ffi::is_fallback(self.ctx) } || self.buf_count == 0 {
            return RenderResult::Skipped;
        }

        // The consumer rotates the buffer index externally (shared memory).
        let idx = {
            let i = unsafe { ffi::get_selected_idx(self.ctx) };
            usize::try_from(i).unwrap_or(0).min(self.buf_count - 1)
        };
        let Some(dmabuf) = self.dmabufs[idx].as_mut() else {
            return RenderResult::Skipped;
        };

        // Buffer age: how many frames ago this buffer was last rendered. 0
        // means unknown contents, which makes the damage tracker repaint fully.
        let age = if self.last_used_frame[idx] == 0 {
            0
        } else {
            usize::try_from(self.frame_counter.saturating_sub(self.last_used_frame[idx]))
                .unwrap_or(0)
        };

        // Render the elements.
        let ctx = RenderCtx {
            renderer: &mut self.renderer,
            target: RenderTarget::Output,
            xray: None,
        };
        let mut elements = niri.render_to_vec(ctx, output, true);

        // Visualize the damage, if enabled.
        if niri.debug_draw_damage {
            let output_state = niri.output_state.get_mut(output).unwrap();
            draw_damage(&mut output_state.debug_damage_tracker, &mut elements);
        }

        // Bind the consumer's dmabuf as our render target (EGLImage + FBO) and
        // draw the damage into it. This is the same path the TTY backend uses
        // for GBM buffers, so the orientation matches DRM scanout: the consumer
        // reads the dmabuf top-down and needs no y-flip.
        let rendered = self
            .renderer
            .bind(dmabuf)
            .map_err(|err| anyhow::anyhow!("error binding dmabuf {idx}: {err:?}"))
            .and_then(|mut target| {
                self.damage_tracker
                    .render_output(&mut self.renderer, &mut target, age, &elements, [0.; 4])
                    .map_err(|err| anyhow::anyhow!("error rendering frame: {err:?}"))
            });

        let rv = match rendered {
            Ok(res) => {
                self.frame_counter += 1;
                self.last_used_frame[idx] = self.frame_counter;

                niri.update_primary_scanout_output(output, &res.states);

                if res.damage.is_some() {
                    let mut presentation_feedbacks =
                        niri.take_presentation_feedbacks(output, &res.states);
                    presentation_feedbacks.presented::<_, smithay::utils::Monotonic>(
                        get_monotonic_time(),
                        Refresh::Unknown,
                        0,
                        wp_presentation_feedback::Kind::empty(),
                    );
                    RenderResult::Submitted
                } else {
                    // Nothing changed since this buffer was last painted, but
                    // the consumer is still waiting: answer below.
                    RenderResult::NoDamage
                }
            }
            Err(err) => {
                warn!("{err:?}");
                RenderResult::Skipped
            }
        };

        // The frame is complete: signal the consumer. Gated on consumer_ready
        // (i.e. at most one trigger per buffer-ready) like weston, so we don't
        // write a buffer the consumer may still be reading.
        if self.consumer_ready {
            self.consumer_ready = false;
            unsafe { ffi::trigger_refresh(self.ctx) };
        }

        if rv == RenderResult::Skipped {
            // Leave the redraw state for niri to clean up (like Tty).
            return rv;
        }

        let output_state = niri.output_state.get_mut(output).unwrap();
        match mem::replace(&mut output_state.redraw_state, RedrawState::Idle) {
            RedrawState::Idle => unreachable!(),
            RedrawState::Queued => (),
            RedrawState::WaitingForVBlank { .. } => unreachable!(),
            RedrawState::WaitingForEstimatedVBlank(_) => unreachable!(),
            RedrawState::WaitingForEstimatedVBlankAndQueued(_) => unreachable!(),
        }

        output_state.frame_callback_sequence =
            output_state.frame_callback_sequence.wrapping_add(1);

        rv
    }
}

impl Drop for Anland {
    fn drop(&mut self) {
        self.drop_consumer_buffers();
        if let Some(token) = self.buf_ready_token.take() {
            self.event_loop.remove(token);
        }
        if let Some(token) = self.data_token.take() {
            self.event_loop.remove(token);
        }
        self.event_loop.remove(self.reconnect_timer_token);
        if !self.ctx.is_null() {
            unsafe { ffi::disconnect(self.ctx) };
            self.ctx = ptr::null_mut();
        }
    }
}
