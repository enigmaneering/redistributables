//! C FFI wrapper around Naga for WGSL ↔ SPIRV transpilation.
//!
//! This crate exposes a minimal C-compatible API so that non-Rust projects
//! (specifically libmental's Emscripten/WASM build) can link Naga directly
//! as a static library instead of invoking it as a subprocess.

use std::slice;

/// Compile WGSL source to SPIRV binary.
///
/// On success, returns 0 and writes the SPIRV data to `spirv_out` / `spirv_len`.
/// The caller must free the returned buffer with `naga_free()`.
/// On failure, returns non-zero and writes an error message to `spirv_out` / `spirv_len`.
#[no_mangle]
pub unsafe extern "C" fn naga_wgsl_to_spirv(
    wgsl_source: *const u8,
    wgsl_len: u32,
    spirv_out: *mut *mut u8,
    spirv_len: *mut u32,
) -> i32 {
    let source = match std::str::from_utf8(slice::from_raw_parts(wgsl_source, wgsl_len as usize)) {
        Ok(s) => s,
        Err(_) => return write_error(spirv_out, spirv_len, "Invalid UTF-8 in WGSL source"),
    };

    let module = match naga::front::wgsl::parse_str(source) {
        Ok(m) => m,
        Err(e) => return write_error(spirv_out, spirv_len, &format!("WGSL parse error: {e}")),
    };

    let info = match naga::valid::Validator::new(
        naga::valid::ValidationFlags::all(),
        naga::valid::Capabilities::all(),
    )
    .validate(&module)
    {
        Ok(i) => i,
        Err(e) => return write_error(spirv_out, spirv_len, &format!("Validation error: {e}")),
    };

    let options = naga::back::spv::Options {
        lang_version: (1, 3),
        ..Default::default()
    };

    match naga::back::spv::write_vec(&module, &info, &options, None) {
        Ok(words) => {
            let bytes: Vec<u8> = words
                .iter()
                .flat_map(|w| w.to_le_bytes())
                .collect();
            write_output(spirv_out, spirv_len, bytes)
        }
        Err(e) => write_error(spirv_out, spirv_len, &format!("SPIRV write error: {e}")),
    }
}

/// Convert SPIRV binary to WGSL source.
///
/// On success, returns 0 and writes the WGSL string to `wgsl_out` / `wgsl_len`.
/// The caller must free the returned buffer with `naga_free()`.
/// On failure, returns non-zero and writes an error message.
#[no_mangle]
pub unsafe extern "C" fn naga_spirv_to_wgsl(
    spirv_data: *const u8,
    spirv_len: u32,
    wgsl_out: *mut *mut u8,
    wgsl_len: *mut u32,
) -> i32 {
    let bytes = slice::from_raw_parts(spirv_data, spirv_len as usize);

    if bytes.len() % 4 != 0 {
        return write_error(wgsl_out, wgsl_len, "SPIRV data length is not a multiple of 4");
    }
    // (Earlier versions of naga::front::spv took &[u32]; current API takes
    //  &[u8] via parse_u8_slice — no word-buffer conversion needed here.)

    let options = naga::front::spv::Options {
        adjust_coordinate_space: false,
        ..Default::default()
    };

    let module = match naga::front::spv::parse_u8_slice(bytes, &options) {
        Ok(m) => m,
        Err(e) => return write_error(wgsl_out, wgsl_len, &format!("SPIRV parse error: {e}")),
    };

    let info = match naga::valid::Validator::new(
        naga::valid::ValidationFlags::all(),
        naga::valid::Capabilities::all(),
    )
    .validate(&module)
    {
        Ok(i) => i,
        Err(e) => return write_error(wgsl_out, wgsl_len, &format!("Validation error: {e}")),
    };

    let flags = naga::back::wgsl::WriterFlags::empty();
    match naga::back::wgsl::write_string(&module, &info, flags) {
        Ok(wgsl) => write_output(wgsl_out, wgsl_len, wgsl.into_bytes()),
        Err(e) => write_error(wgsl_out, wgsl_len, &format!("WGSL write error: {e}")),
    }
}

/// Free a buffer previously returned by `naga_wgsl_to_spirv` or `naga_spirv_to_wgsl`.
#[no_mangle]
pub unsafe extern "C" fn naga_free(ptr: *mut u8, len: u32) {
    if !ptr.is_null() && len > 0 {
        drop(Vec::from_raw_parts(ptr, len as usize, len as usize));
    }
}

// --- Internal helpers ---

unsafe fn write_output(out: *mut *mut u8, out_len: *mut u32, data: Vec<u8>) -> i32 {
    let len = data.len() as u32;
    let ptr = data.as_ptr() as *mut u8;
    std::mem::forget(data); // Caller owns the memory now
    *out = ptr;
    *out_len = len;
    0
}

unsafe fn write_error(out: *mut *mut u8, out_len: *mut u32, msg: &str) -> i32 {
    let data = msg.as_bytes().to_vec();
    write_output(out, out_len, data);
    -1
}
