//! Hand-written FFI to the vendored anland display producer library.
//!
//! The C side lives in `src/backend/anland/` and is compiled by `build.rs`.
//! See `protocol.h` and `display_producer.h` for the semantics; those files are
//! vendored unmodified and are the source of truth for the wire format.

#![allow(non_camel_case_types)]

use std::ffi::{c_char, c_void};

/// Opaque producer-side state machine (see `display_producer.c`).
pub enum display_ctx {}

/// `struct buf_info` from `protocol.h` (packed on the wire).
#[repr(C, packed)]
#[derive(Debug, Clone, Copy)]
pub struct buf_info {
    pub stride: u32,
    pub format: u32,
    pub modifier: u64,
    pub offset: u32,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct TouchData {
    pub action: i32,
    pub x: f32,
    pub y: f32,
    pub pointer_id: i32,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct KeyData {
    pub action: i32,
    pub keycode: i32,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct PointerMotionData {
    pub x: f32,
    pub y: f32,
    pub dx: f32,
    pub dy: f32,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct PointerButtonData {
    pub button: u32,
    pub pressed: i32,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct PointerAxisData {
    pub axis: u32,
    pub value: f32,
    pub discrete: i32,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct DisplayData {
    pub refresh_mhz: u32,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub union InputEventData {
    pub touch: TouchData,
    pub key: KeyData,
    pub pointer_motion: PointerMotionData,
    pub pointer_button: PointerButtonData,
    pub pointer_axis: PointerAxisData,
    pub display: DisplayData,
}

/// `struct InputEvent` from `protocol.h` (packed on the wire).
#[repr(C, packed)]
#[derive(Clone, Copy)]
pub struct InputEvent {
    pub type_: u32,
    pub data: InputEventData,
}

pub const INPUT_TYPE_TOUCH: u32 = 1;
pub const INPUT_TYPE_KEY: u32 = 2;
pub const INPUT_TYPE_POINTER_MOTION: u32 = 3;
pub const INPUT_TYPE_POINTER_BUTTON: u32 = 4;
pub const INPUT_TYPE_POINTER_AXIS: u32 = 5;
pub const INPUT_TYPE_TOUCH_FRAME: u32 = 6;
pub const INPUT_TYPE_DISPLAY_REFRESH: u32 = 7;

pub const INPUT_ACTION_DOWN: i32 = 0;
pub const INPUT_ACTION_UP: i32 = 1;
pub const INPUT_ACTION_MOVE: i32 = 2;

extern "C" {
    pub fn connect_to_deamon(ctx: *mut *mut display_ctx, socket_path: *const c_char) -> i32;
    pub fn disconnect(ctx: *mut display_ctx);
    pub fn get_screen_info(
        ctx: *mut display_ctx,
        width: *mut u32,
        height: *mut u32,
        format: *mut u32,
        refresh: *mut u32,
    ) -> i32;
    pub fn trigger_refresh(ctx: *mut display_ctx) -> i32;
    pub fn poll_input_event(ctx: *mut display_ctx, event: *mut InputEvent, timeout_ms: i32) -> i32;
    pub fn set_fallback_callback(
        ctx: *mut display_ctx,
        on_fallback: Option<unsafe extern "C" fn(*mut c_void)>,
        userdata: *mut c_void,
    ) -> i32;
    pub fn is_fallback(ctx: *mut display_ctx) -> bool;
    pub fn try_exit_fallback(ctx: *mut display_ctx) -> i32;
    pub fn get_data_fd(ctx: *mut display_ctx) -> i32;
    pub fn get_buffer_ready_fd(ctx: *mut display_ctx) -> i32;
    pub fn get_buf_count(ctx: *mut display_ctx) -> i32;
    pub fn get_selected_idx(ctx: *mut display_ctx) -> i32;
    pub fn get_dmabuf_fd_at(ctx: *mut display_ctx, idx: i32) -> i32;
    pub fn get_dmabuf_info_at(ctx: *mut display_ctx, idx: i32, info: *mut buf_info) -> i32;
}
