const core = @import("tobiifree_core.zig");
const c = @cImport({
    @cInclude("libusb.h");
});

const VID: u16 = 0x2104;
const PID: u16 = 0x030E;

var ctx: ?*c.libusb_context = null;
var dev: ?*c.libusb_device_handle = null;
var phase: u8 = 0;
var in_buf: [16384]u8 = undefined;

const GazeCallback = *const fn (
    x: f64,
    y: f64,
    left_valid: u32,
    right_valid: u32,
) callconv(.c) void;

var gaze_callback: ?GazeCallback = null;

fn onGaze(ptr: [*]const u8) void {
    const sample: *const core.GazeSample =
        @ptrCast(@alignCast(ptr));

    if (gaze_callback) |callback| {
        callback(
            sample.gaze_point_2d_norm[0],
            sample.gaze_point_2d_norm[1],
            sample.validity_L,
            sample.validity_R,
        );
    }
}

pub export fn tobii_set_gaze_callback(
    callback: ?GazeCallback,
) void {
    gaze_callback = callback;
    core.set_hooks(null, null, null, onGaze, null);
}

fn sendFrame() bool {
    const n = core.session_out_len_();
    if (n == 0 or n > 8192) return false;

    var written: c_int = 0;

    const r = c.libusb_bulk_transfer(
        dev,
        0x05,
        @constCast(core.session_out_ptr()),
        @intCast(n),
        &written,
        2000,
    );

    return r == 0 and written == @as(c_int, @intCast(n));
}

fn receiveFrame() c_int {
    var received: c_int = 0;

    const result = c.libusb_bulk_transfer(
        dev,
        0x83,
        &in_buf,
        @intCast(in_buf.len),
        &received,
        250,
    );

    if (result == c.LIBUSB_ERROR_TIMEOUT) {
        return 0;
    }

    if (result != 0) {
        return result;
    }

    if (received > 0) {
        const n: usize = @intCast(received);
        core.feed_usb_in(&in_buf, n);
    }

    return received;
}

pub export fn tobii_open() c_int {
    if (dev != null) return -100;

    const r = c.libusb_init(&ctx);
    if (r != 0) return r;

    dev = c.libusb_open_device_with_vid_pid(
        ctx, VID, PID,
    );

    if (dev == null) {
        c.libusb_exit(ctx);
        ctx = null;
        return -101;
    }

    const claimed = c.libusb_claim_interface(dev, 0);
    if (claimed != 0) {
        tobii_close();
        return claimed;
    }

    const opened = c.libusb_control_transfer(
        dev,
        0x41,
        0x41,
        0,
        0,
        null,
        0,
        1000,
    );

    if (opened < 0) {
        tobii_close();
        return opened;
    }

    core.set_hooks(null, null, null, onGaze, null);
    core.handshake_init(0x500);
    phase = 1;

    return 0;
}

pub export fn tobii_step() c_int {
    if (dev == null) return -100;

    if (phase == 1) {
        const action = core.handshake_poll();

        switch (action) {
            1 => {
                if (!sendFrame()) return -102;
                return 0;
            },
            2 => {
                const n = receiveFrame();
                return if (n < 0) n else 0;
            },
            3 => {
                _ = core.request_subscribe(0x500);

                if (!sendFrame()) return -103;

                phase = 2;
                return 2;
            },
            4 => return -104,
            else => return -105,
        }
    }

    if (phase == 2) {
        const n = receiveFrame();
        return if (n < 0) n else 1;
    }

    return -106;
}

pub export fn tobii_close() void {
    if (dev) |handle| {
        _ = c.libusb_control_transfer(
            handle,
            0x41,
            0x42,
            0,
            0,
            null,
            0,
            500,
        );

        _ = c.libusb_release_interface(handle, 0);
        c.libusb_close(handle);
        dev = null;
    }

    if (ctx) |context| {
        c.libusb_exit(context);
        ctx = null;
    }

    phase = 0;
}
