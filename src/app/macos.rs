//! macOS: clicking the Dock icon shows the window again after it was closed.
//!
//! winit's application delegate doesn't implement
//! `applicationShouldHandleReopen:hasVisibleWindows:`, so the method is added to its
//! class at run time through the Objective-C runtime.

use std::cell::RefCell;
use std::ffi::{c_char, c_void};

#[link(name = "objc")]
unsafe extern "C" {
    fn objc_getClass(name: *const c_char) -> *mut c_void;
    fn sel_registerName(name: *const c_char) -> *mut c_void;
    fn class_addMethod(class: *mut c_void, selector: *mut c_void, implementation: *const c_void, types: *const c_char) -> i8;
}

thread_local! {
    static ON_REOPEN: RefCell<Option<Box<dyn Fn()>>> = RefCell::new(None);
}

/// `BOOL` is one byte on both Apple silicon and Intel.
extern "C" fn should_handle_reopen(_delegate: *mut c_void, _selector: *mut c_void, _application: *mut c_void, has_visible_windows: i8) -> i8 {
    #[cfg(debug_assertions)]
    eprintln!("reopen: visible windows = {has_visible_windows}");
    if has_visible_windows == 0 {
        ON_REOPEN.with(|handler| {
            if let Some(handler) = handler.borrow().as_ref() {
                handler();
            }
        });
    }
    1
}

/// Must run once the event loop exists (the delegate class is registered by then).
pub fn on_reopen(handler: impl Fn() + 'static) {
    ON_REOPEN.with(|slot| *slot.borrow_mut() = Some(Box::new(handler)));
    // SAFETY: plain Objective-C runtime calls with valid C strings; the implementation
    // matches the method signature (id self, SEL _cmd, NSApplication *, BOOL) -> BOOL.
    unsafe {
        let class = objc_getClass(c"WinitApplicationDelegate".as_ptr());
        if class.is_null() {
            return;
        }
        let selector = sel_registerName(c"applicationShouldHandleReopen:hasVisibleWindows:".as_ptr());
        class_addMethod(class, selector, should_handle_reopen as *const c_void, c"c@:@c".as_ptr());
    }
}
