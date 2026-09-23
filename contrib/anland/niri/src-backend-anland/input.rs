//! anland input: converts the daemon's `struct InputEvent` stream into smithay
//! input events (see `protocol.h` for the wire format).

use std::path::PathBuf;

use smithay::backend::input::{
    AbsolutePositionEvent, Axis, AxisRelativeDirection, AxisSource, ButtonState, Device,
    DeviceCapability, Event, InputBackend, KeyState, KeyboardKeyEvent, Keycode, PointerAxisEvent,
    PointerButtonEvent, PointerMotionAbsoluteEvent, TouchCancelEvent, TouchDownEvent, TouchEvent,
    TouchFrameEvent, TouchMotionEvent, TouchSlot, TouchUpEvent, UnusedEvent,
};

/// Marker used to define the [`InputBackend`] types for the anland backend.
#[derive(Debug)]
pub struct AnlandInput;

/// Virtual input device: the consumer feeds us keyboard, pointer and touch.
#[derive(PartialEq, Eq, Hash, Debug, Clone, Copy)]
pub struct AnlandInputDevice;

impl Device for AnlandInputDevice {
    fn id(&self) -> String {
        String::from("anland")
    }

    fn name(&self) -> String {
        String::from("anland virtual input")
    }

    fn has_capability(&self, capability: DeviceCapability) -> bool {
        matches!(
            capability,
            DeviceCapability::Keyboard | DeviceCapability::Pointer | DeviceCapability::Touch
        )
    }

    fn usb_id(&self) -> Option<(u32, u32)> {
        None
    }

    fn syspath(&self) -> Option<PathBuf> {
        None
    }
}

/// Keyboard event. The consumer sends Linux evdev keycodes; smithay/xkb want
/// them in xkb space (evdev + 8), which the backend applies before constructing.
#[derive(Debug, Clone, Copy)]
pub struct AnlandKeyboardEvent {
    pub time: u64,
    pub key_code: Keycode,
    pub state: KeyState,
    pub count: u32,
}

impl Event<AnlandInput> for AnlandKeyboardEvent {
    fn time(&self) -> u64 {
        self.time
    }

    fn device(&self) -> AnlandInputDevice {
        AnlandInputDevice
    }
}

impl KeyboardKeyEvent<AnlandInput> for AnlandKeyboardEvent {
    fn key_code(&self) -> Keycode {
        self.key_code
    }

    fn state(&self) -> KeyState {
        self.state
    }

    fn count(&self) -> u32 {
        self.count
    }
}

/// Absolute pointer motion. Coordinates arrive in screen physical pixels.
#[derive(Debug, Clone, Copy)]
pub struct AnlandPointerMotionAbsoluteEvent {
    pub time: u64,
    pub x_px: f64,
    pub y_px: f64,
    pub screen_w: f64,
    pub screen_h: f64,
}

impl Event<AnlandInput> for AnlandPointerMotionAbsoluteEvent {
    fn time(&self) -> u64 {
        self.time
    }

    fn device(&self) -> AnlandInputDevice {
        AnlandInputDevice
    }
}

impl AbsolutePositionEvent<AnlandInput> for AnlandPointerMotionAbsoluteEvent {
    fn x(&self) -> f64 {
        self.x_px
    }

    fn y(&self) -> f64 {
        self.y_px
    }

    fn x_transformed(&self, width: i32) -> f64 {
        self.x_px / self.screen_w * f64::from(width)
    }

    fn y_transformed(&self, height: i32) -> f64 {
        self.y_px / self.screen_h * f64::from(height)
    }
}

impl PointerMotionAbsoluteEvent<AnlandInput> for AnlandPointerMotionAbsoluteEvent {}

/// Pointer button event. The button code is a Linux `BTN_*` code.
#[derive(Debug, Clone, Copy)]
pub struct AnlandPointerButtonEvent {
    pub time: u64,
    pub button_code: u32,
    pub state: ButtonState,
}

impl Event<AnlandInput> for AnlandPointerButtonEvent {
    fn time(&self) -> u64 {
        self.time
    }

    fn device(&self) -> AnlandInputDevice {
        AnlandInputDevice
    }
}

impl PointerButtonEvent<AnlandInput> for AnlandPointerButtonEvent {
    fn button_code(&self) -> u32 {
        self.button_code
    }

    fn state(&self) -> ButtonState {
        self.state
    }
}

/// Pointer scroll event. Protocol axis: 0 = vertical, 1 = horizontal.
#[derive(Debug, Clone, Copy)]
pub struct AnlandPointerAxisEvent {
    pub time: u64,
    pub axis: Axis,
    pub value: f32,
    pub discrete: i32,
}

impl Event<AnlandInput> for AnlandPointerAxisEvent {
    fn time(&self) -> u64 {
        self.time
    }

    fn device(&self) -> AnlandInputDevice {
        AnlandInputDevice
    }
}

impl PointerAxisEvent<AnlandInput> for AnlandPointerAxisEvent {
    fn amount(&self, axis: Axis) -> Option<f64> {
        (axis == self.axis).then_some(f64::from(self.value))
    }

    fn amount_v120(&self, axis: Axis) -> Option<f64> {
        (axis == self.axis && self.discrete != 0).then_some(f64::from(self.discrete) * 120.0)
    }

    fn source(&self) -> AxisSource {
        if self.discrete != 0 {
            AxisSource::Wheel
        } else {
            AxisSource::Continuous
        }
    }

    fn relative_direction(&self, _axis: Axis) -> AxisRelativeDirection {
        AxisRelativeDirection::Identical
    }
}

/// Touch down event. Coordinates arrive in screen physical pixels.
#[derive(Debug, Clone, Copy)]
pub struct AnlandTouchDownEvent {
    pub time: u64,
    pub slot: TouchSlot,
    pub x_px: f64,
    pub y_px: f64,
    pub screen_w: f64,
    pub screen_h: f64,
}

impl Event<AnlandInput> for AnlandTouchDownEvent {
    fn time(&self) -> u64 {
        self.time
    }

    fn device(&self) -> AnlandInputDevice {
        AnlandInputDevice
    }
}

impl TouchEvent<AnlandInput> for AnlandTouchDownEvent {
    fn slot(&self) -> TouchSlot {
        self.slot
    }
}

impl AbsolutePositionEvent<AnlandInput> for AnlandTouchDownEvent {
    fn x(&self) -> f64 {
        self.x_px
    }

    fn y(&self) -> f64 {
        self.y_px
    }

    fn x_transformed(&self, width: i32) -> f64 {
        self.x_px / self.screen_w * f64::from(width)
    }

    fn y_transformed(&self, height: i32) -> f64 {
        self.y_px / self.screen_h * f64::from(height)
    }
}

impl TouchDownEvent<AnlandInput> for AnlandTouchDownEvent {}

/// Touch motion event.
#[derive(Debug, Clone, Copy)]
pub struct AnlandTouchMotionEvent {
    pub time: u64,
    pub slot: TouchSlot,
    pub x_px: f64,
    pub y_px: f64,
    pub screen_w: f64,
    pub screen_h: f64,
}

impl Event<AnlandInput> for AnlandTouchMotionEvent {
    fn time(&self) -> u64 {
        self.time
    }

    fn device(&self) -> AnlandInputDevice {
        AnlandInputDevice
    }
}

impl TouchEvent<AnlandInput> for AnlandTouchMotionEvent {
    fn slot(&self) -> TouchSlot {
        self.slot
    }
}

impl AbsolutePositionEvent<AnlandInput> for AnlandTouchMotionEvent {
    fn x(&self) -> f64 {
        self.x_px
    }

    fn y(&self) -> f64 {
        self.y_px
    }

    fn x_transformed(&self, width: i32) -> f64 {
        self.x_px / self.screen_w * f64::from(width)
    }

    fn y_transformed(&self, height: i32) -> f64 {
        self.y_px / self.screen_h * f64::from(height)
    }
}

impl TouchMotionEvent<AnlandInput> for AnlandTouchMotionEvent {}

/// Touch up event.
#[derive(Debug, Clone, Copy)]
pub struct AnlandTouchUpEvent {
    pub time: u64,
    pub slot: TouchSlot,
}

impl Event<AnlandInput> for AnlandTouchUpEvent {
    fn time(&self) -> u64 {
        self.time
    }

    fn device(&self) -> AnlandInputDevice {
        AnlandInputDevice
    }
}

impl TouchEvent<AnlandInput> for AnlandTouchUpEvent {
    fn slot(&self) -> TouchSlot {
        self.slot
    }
}

impl TouchUpEvent<AnlandInput> for AnlandTouchUpEvent {}

/// Touch cancel event (sent when the consumer goes away mid-touch).
#[derive(Debug, Clone, Copy)]
pub struct AnlandTouchCancelEvent {
    pub time: u64,
}

impl Event<AnlandInput> for AnlandTouchCancelEvent {
    fn time(&self) -> u64 {
        self.time
    }

    fn device(&self) -> AnlandInputDevice {
        AnlandInputDevice
    }
}

impl TouchEvent<AnlandInput> for AnlandTouchCancelEvent {
    fn slot(&self) -> TouchSlot {
        TouchSlot::from(None)
    }
}

impl TouchCancelEvent<AnlandInput> for AnlandTouchCancelEvent {}

/// Touch frame event.
#[derive(Debug, Clone, Copy)]
pub struct AnlandTouchFrameEvent {
    pub time: u64,
}

impl Event<AnlandInput> for AnlandTouchFrameEvent {
    fn time(&self) -> u64 {
        self.time
    }

    fn device(&self) -> AnlandInputDevice {
        AnlandInputDevice
    }
}

impl TouchFrameEvent<AnlandInput> for AnlandTouchFrameEvent {}

impl InputBackend for AnlandInput {
    type Device = AnlandInputDevice;
    type KeyboardKeyEvent = AnlandKeyboardEvent;
    type PointerAxisEvent = AnlandPointerAxisEvent;
    type PointerButtonEvent = AnlandPointerButtonEvent;
    type PointerMotionEvent = UnusedEvent;
    type PointerMotionAbsoluteEvent = AnlandPointerMotionAbsoluteEvent;

    type GestureSwipeBeginEvent = UnusedEvent;
    type GestureSwipeUpdateEvent = UnusedEvent;
    type GestureSwipeEndEvent = UnusedEvent;
    type GesturePinchBeginEvent = UnusedEvent;
    type GesturePinchUpdateEvent = UnusedEvent;
    type GesturePinchEndEvent = UnusedEvent;
    type GestureHoldBeginEvent = UnusedEvent;
    type GestureHoldEndEvent = UnusedEvent;

    type TouchDownEvent = AnlandTouchDownEvent;
    type TouchUpEvent = AnlandTouchUpEvent;
    type TouchMotionEvent = AnlandTouchMotionEvent;
    type TouchCancelEvent = AnlandTouchCancelEvent;
    type TouchFrameEvent = AnlandTouchFrameEvent;

    type TabletToolAxisEvent = UnusedEvent;
    type TabletToolProximityEvent = UnusedEvent;
    type TabletToolTipEvent = UnusedEvent;
    type TabletToolButtonEvent = UnusedEvent;
    type SwitchToggleEvent = UnusedEvent;

    type SpecialEvent = ();
}
