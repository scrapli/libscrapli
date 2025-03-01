pub fn getBackoffValue(
    cur_val: u64,
    max_val: u64,
    backoff_factor: u8,
) u64 {
    var new_val: u64 = cur_val;

    new_val *= backoff_factor;
    if (new_val > max_val) {
        new_val = max_val;
    }

    return new_val;
}
