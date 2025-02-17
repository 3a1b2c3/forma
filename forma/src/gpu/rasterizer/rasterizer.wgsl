// Copyright 2022 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

let WORKGROUP_SIZE = 256u;
let MAX_INVOCATION_COUNT = 16u;

let TILE_WIDTH: i32 = 16;
let TILE_WIDTH_SHIFT: u32 = 4u;
let TILE_HEIGHT: i32 = 4;
let TILE_HEIGHT_SHIFT: u32 = 2u;

let PIXEL_WIDTH: i32 = 16;
let PIXEL_SHIFT: u32 = 4u;

let MAX_WIDTH_SHIFT = 16u;
let MAX_HEIGHT_SHIFT = 15u;

let TILE_BIAS = 1;
let LAYER_ID_BIT_SIZE = 21u;
let DOUBLE_AREA_MULTIPLIER_BIT_SIZE = 6u;
let COVER_BIT_SIZE = 6u;

let NONE: u32 = 0xffffffffu;

// black-box methods that ensure precise results in the presence of ffast-math.

fn bbAdd(x: f32, y: f32) -> f32 {
    return select(x, x + y, y != 0.0);
}

fn bbSub(x: f32, y: f32) -> f32 {
    return select(x, x - y, y != 0.0);
}

fn bbMul(x: f32, y: f32) -> f32 {
    return select(x, x * y, y != 1.0);
}

fn bbDiv(x: f32, y: f32) -> f32 {
    return select(x, x / y, y != 1.0);
}

fn twoSum(x: f32, y: f32) -> vec2<f32> {
    let r = bbAdd(x, y);
    let t = bbSub(r, x);
    let e = bbAdd(bbSub(x, bbSub(r, t)), bbSub(y, t));
    
    return vec2(r, e);
}

fn twoSumQuick(x: f32, y: f32) -> vec2<f32> {
    let r = bbAdd(x, y);
    let e = bbSub(y, bbSub(r, x));
    
    return vec2(r, e);
}

fn twoDifference(x: f32, y: f32) -> vec2<f32> {
    let r = bbSub(x, y);
    let t = bbSub(r, x);
    let e = bbSub(bbSub(x,  bbSub(r, t)), bbAdd(y, t));

    return vec2(r, e);
}

fn twoProduct(x: f32, y: f32) -> vec2<f32> {
    let r = bbMul(x, y);
    let e = fma(x, y, -r);
    
    return vec2(r, e);
}

// A "float-float" adaptiation of the double-double arithmetic. Adapted from
// https://github.com/sukop/doubledouble.
struct ff64 {
    hi: f32,
    lo: f32,
}

fn ff64F32(val: f32) -> ff64 {
    return ff64(val, 0.0);
}

fn add(x: ff64, y: ff64) -> ff64 {
    var r = twoSum(x.hi, y.hi);
    r.y = bbAdd(r.y, bbAdd(x.lo, y.lo));
    r = twoSumQuick(r.x, r.y);
    
    return ff64(r.x, r.y);
}

fn sub(x: ff64, y: ff64) -> ff64 {
    var r = twoDifference(x.hi, y.hi);
    r.y = bbAdd(r.y, bbSub(x.lo, y.lo));
    r = twoSumQuick(r.x, r.y);
    
    return ff64(r.x, r.y);
}

fn mul(x: ff64, y: ff64) -> ff64 {
    var r = twoProduct(x.hi, y.hi);
    r.y = bbAdd(r.y, bbAdd(bbMul(x.hi, y.lo), bbMul(x.lo, y.hi)));
    r = twoSumQuick(r.x, r.y);
    
    return ff64(r.x, r.y);
}

fn div(x: ff64, y: ff64) -> ff64 {
    let r = bbDiv(x.hi, y.hi);
    let s = twoProduct(r, y.hi);
    let e = bbDiv(
        bbSub(bbAdd(bbSub(bbSub(x.hi, s.x), s.y), x.lo), bbMul(r, y.lo)),
        y.hi,
    );
    let v = twoSumQuick(r, e);
    
    return ff64(v.x, v.y);
}

fn ff64Ceil(val: ff64) -> f32 {
    let ceilHi = ceil(val.hi);
    let ceilLo = ceil(val.lo);

    return select(
        ceilHi + ceilLo,
        ceilHi,
        ceilHi > val.hi,
    );
}

struct Config {
    lines_len: u32,
    segments_len: u32,
}

struct PixelSegment {
    lo: u32,
    hi: u32,
}

struct Line {
    a: f32,
    b: f32,
    c: f32,
    d: f32,
    x0: f32,
    y0: f32,
    dx: f32,
    dy: f32,
    order: u32,
}

@group(0) @binding(0) var<uniform> config: Config;
@group(0) @binding(1) var<storage> points: array<vec2<f32>>;
@group(0) @binding(2) var<storage> orders: array<u32>;
@group(0) @binding(3) var<storage, write> lines_out: array<Line>;
@group(0) @binding(4) var<storage> lines_in: array<Line>;
@group(0) @binding(5) var<storage> line_lens: array<u32>;
@group(0) @binding(6) var<storage, write> segments: array<PixelSegment>;

fn prepareLine(p0: vec2<f32>, p1: vec2<f32>, order: u32) -> Line {
    if order == NONE {
        return Line(0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0u);
    }

    let dp = p1 - p0;
    let dp_recip = 1.0 / dp;

    let t_offset = select(
        vec2(0.0, 0.0),
        max((ceil(p0) - p0) * dp_recip, -fract(p0) * dp_recip),
        dp != vec2<f32>(0.0, 0.0),
    );

    let a = abs(dp_recip.x);
    let b = abs(dp_recip.y);
    let c = t_offset.x;
    let d = t_offset.y;

    // Converting to sub-pixel by multiplying with `PIXEL_WIDTH`.
    let sp0 = p0 * f32(PIXEL_WIDTH);
    let sdp = dp * f32(PIXEL_WIDTH);

    return Line(a, b, c, d, sp0.x, sp0.y, sdp.x, sdp.y, order);
}

// Binary search.
fn findLineId(segment_index: u32, line_len: u32) -> u32 {
    // Let line_id be min(i) ∀ i ∈ [0; segments_len) where
    // lines_orders[i] > segment_index. Binary search in range [lo; hi].
    var lo: u32 = 0u;
    var hi: u32 = line_len;

    for (var i = line_len; i > 0u; i >>= 1u){
        let mid: u32 = lo + ((hi - lo) >> 1u);
        let is_greater = line_lens[mid] > segment_index;

        lo = select(mid + 1u, lo, is_greater);
        hi = select(hi, mid, is_greater);
    }

    return lo;
}

// Returns true when the value equals +Inf or -Inf.
fn isInf(v: f32) -> bool {
    let clear_sign_mask = 0x7fffffffu;
    let infinity = 0x7f800000u;
    return (bitcast<u32>(v) & clear_sign_mask) == infinity;
}

// Rounds to closest integer or towards -Inf if there is a draw.
fn roundToI32(v: f32) -> i32 {
    return i32(floor(v + 0.5));
}

fn packPixelSegment(
    layer_id: u32,
    tile_x: i32,
    tile_y: i32,
    local_x: u32,
    local_y: u32,
    double_area_multiplier: u32,
    cover: i32,
) -> PixelSegment {
    var seg: PixelSegment;

    seg.hi = u32(max(0, tile_y + TILE_BIAS)) <<
        (32u - (MAX_HEIGHT_SHIFT - TILE_HEIGHT_SHIFT));

    seg.hi = insertBits(
        seg.hi,
        u32(max(0, tile_x + TILE_BIAS)),
        32u - (MAX_WIDTH_SHIFT - TILE_WIDTH_SHIFT) -
            (MAX_HEIGHT_SHIFT - TILE_HEIGHT_SHIFT),
        MAX_WIDTH_SHIFT - TILE_WIDTH_SHIFT,
    );

    seg.hi = insertBits(
        seg.hi,
        layer_id >> (32u - TILE_WIDTH_SHIFT - TILE_HEIGHT_SHIFT -
            DOUBLE_AREA_MULTIPLIER_BIT_SIZE - COVER_BIT_SIZE),
        0u,
        32u - (MAX_WIDTH_SHIFT - TILE_WIDTH_SHIFT) -
            (MAX_HEIGHT_SHIFT - TILE_HEIGHT_SHIFT),
    );

    seg.lo = layer_id <<
        (TILE_WIDTH_SHIFT + TILE_HEIGHT_SHIFT +
        DOUBLE_AREA_MULTIPLIER_BIT_SIZE + COVER_BIT_SIZE);

    seg.lo =  insertBits(
        seg.lo,
        local_x,
        TILE_HEIGHT_SHIFT + DOUBLE_AREA_MULTIPLIER_BIT_SIZE + COVER_BIT_SIZE,
        TILE_WIDTH_SHIFT,
    );

    seg.lo = insertBits(
        seg.lo,
        local_y,
        DOUBLE_AREA_MULTIPLIER_BIT_SIZE + COVER_BIT_SIZE,
        TILE_HEIGHT_SHIFT,
    );

    seg.lo = insertBits(
        seg.lo,
        double_area_multiplier,
        COVER_BIT_SIZE,
        DOUBLE_AREA_MULTIPLIER_BIT_SIZE,
    );

    seg.lo = insertBits(
        seg.lo,
        u32(cover),
        0u,
        COVER_BIT_SIZE,
    );

    return seg;
}

// This finds the ith term in the ordered union of two sequences:
//
// 1. a * t + c
// 2. b * t + d
//
// It works by estimating the amount of items that came from sequence 1 and
// sequence 2 such that the next item will be the ith. This results in two
// indices from each sequence. The final step is to simply pick the smaller one
// which naturally comes next.
fn find(i: i32, a_over_a_b: ff64, b_over_a_b: ff64, c_d_over_a_b: ff64, a: f32, b: f32, c: f32, d: f32) -> f32 {
    let i = f32(i);

    // Index estimation requires extra bits of information to work correctly for
    // cases where e.g. a + b would lose information.
    let ja = select(
        ff64Ceil(sub(mul(b_over_a_b, ff64F32(i)), c_d_over_a_b)),
        i,
        isInf(b),
    );
    let jb = select(
        ff64Ceil(add(mul(a_over_a_b, ff64F32(i)), c_d_over_a_b)),
        i,
        isInf(a),
    );

    let guess_a = a * ja + c;
    let guess_b = b * jb + d;

    return min(guess_a, guess_b);
}

fn computePixelSegment(li: u32, pi: u32) -> PixelSegment {
    let line_ = lines_in[li];
    let a = line_.a;
    let b = line_.b;
    let c = line_.c;
    let d = line_.d;

    let i: i32 = i32(pi) - i32(c != 0.0) - i32(d != 0.0);

    let i0 = i;
    let i1 = i + 1;

    let sum_recip = div(ff64F32(1.0), add(ff64F32(a), ff64F32(b)));
    let a_over_a_b = mul(ff64F32(a), sum_recip);
    let b_over_a_b = mul(ff64F32(b), sum_recip);
    let c_d_over_a_b = mul(sub(ff64F32(c), ff64F32(d)), sum_recip);

    let t0 = max(
        find(i0, a_over_a_b, b_over_a_b, c_d_over_a_b, a, b, c, d),
        0.0,
    );
    let t1 = min(
        find(i1, a_over_a_b, b_over_a_b, c_d_over_a_b, a, b, c, d),
        1.0,
    );

    let x0f = t0 * line_.dx + line_.x0;
    let y0f = t0 * line_.dy + line_.y0;
    let x1f = t1 * line_.dx + line_.x0;
    let y1f = t1 * line_.dy + line_.y0;

    let x0_sub: i32 = roundToI32(x0f);
    let x1_sub: i32 = roundToI32(x1f);
    let y0_sub: i32 = roundToI32(y0f);
    let y1_sub: i32 = roundToI32(y1f);

    let border_x: i32 = min(x0_sub, x1_sub) >> PIXEL_SHIFT;
    let border_y: i32 = min(y0_sub, y1_sub) >> PIXEL_SHIFT;

    let tile_x: i32 = (border_x >> TILE_WIDTH_SHIFT);
    let tile_y: i32 = (border_y >> TILE_HEIGHT_SHIFT);
    let local_x: u32 = u32(border_x & (TILE_WIDTH - 1));
    let local_y: u32 = u32(border_y & (TILE_HEIGHT - 1));

    let border = (border_x << PIXEL_SHIFT) + PIXEL_WIDTH;
    let height = y1_sub - y0_sub;

    let double_area_multiplier: u32 =
        u32(abs(x1_sub - x0_sub) + 2 * (border - max(x0_sub, x1_sub)));
    let cover: i32 = height;

    return packPixelSegment(
        line_.order,
        tile_x,
        tile_y,
        local_x,
        local_y,
        double_area_multiplier,
        cover,
    );
}

@compute @workgroup_size(256)
fn prepareLines(
    @builtin(global_invocation_id) global_id_vec: vec3<u32>
) {
    for (
        var line_index = global_id_vec.x;
        line_index < config.lines_len;
        line_index += WORKGROUP_SIZE * MAX_INVOCATION_COUNT
    ) {

        let p0 = points[line_index];
        let p1 = points[line_index + 1u];
        let order = orders[line_index];

        lines_out[line_index] = prepareLine(p0, p1, order);
    }
}

@compute @workgroup_size(256)
fn rasterize(
    @builtin(global_invocation_id) global_id_vec: vec3<u32>
) {
    for (
        var segment_index = global_id_vec.x;
        segment_index < config.segments_len;
        segment_index += WORKGROUP_SIZE * MAX_INVOCATION_COUNT
    ) {

        let li = findLineId(segment_index, config.lines_len);
        let pi = segment_index - select(
            0u,
            line_lens[max(0u, li - 1u)],
            li > 0u,
        );

        segments[segment_index] = computePixelSegment(li, pi);

        // Set segment beyond the last line with padding to u64 maximal value,
        // so that it stays at the end of the buffer after sort, and the painter
        // can ignore them based on the exact segment count.
        if segment_index >= config.segments_len {
            segments[segment_index] = PixelSegment(0xffffffffu, 0xffffffffu);
        }
    }
}
