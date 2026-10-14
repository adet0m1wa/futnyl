// Sound waves rippling out of the two speakers while music plays.
// Everything is in artboard units: the script passes the artboard size as
// `res` and the fragment works from uv * res, whatever the canvas resolution.

struct Uniforms {
    res: vec2f,      // artboard size
    time: f32,       // seconds
    amp: f32,        // 0 = silent, 1 = playing (eased by the script)
    left: vec2f,     // left speaker centre
    right: vec2f,    // right speaker centre
    body: vec4f,     // device body: centre.xy, half size.zw
    color: vec4f,    // wave colour, straight alpha
    params: vec4f,   // body corner radius, speaker radius, wavelength, falloff
};

@group(0) @binding(0) var<uniform> u: Uniforms;

struct VSOut {
    @builtin(position) position: vec4f,
    @location(0) uv: vec2f,
};

// One oversized triangle covers the whole canvas.
@vertex
fn vs_main(@builtin(vertex_index) i: u32) -> VSOut {
    var corners = array<vec2f, 3>(vec2f(-1.0, -1.0), vec2f(3.0, -1.0), vec2f(-1.0, 3.0));
    let p = corners[i];
    var out: VSOut;
    out.position = vec4f(p, 0.0, 1.0);
    out.uv = vec2f((p.x + 1.0) * 0.5, 1.0 - (p.y + 1.0) * 0.5);
    return out;
}

fn roundedBox(p: vec2f, half: vec2f, r: f32) -> f32 {
    let q = abs(p) - half + vec2f(r, r);
    return length(max(q, vec2f(0.0, 0.0))) + min(max(q.x, q.y), 0.0) - r;
}

// Rings travelling outward from a speaker, wobbling a little so they read as
// sound rather than a target.
fn speaker(p: vec2f, centre: vec2f, phase: f32) -> f32 {
    let speakerRadius = u.params.y;
    let wavelength = u.params.z;
    let falloff = u.params.w;
    let d = p - centre;
    let dist = length(d);
    let angle = atan2(d.y, d.x);
    let edge = dist - speakerRadius;
    let wobble = 1.3 * sin(angle * 5.0 + u.time * 1.9 + phase) * smoothstep(0.0, 18.0, edge);
    let x = (edge + wobble) / wavelength - u.time * 0.85 + phase;
    let ring = pow(0.5 + 0.5 * cos(6.2831853 * x), 6.0);
    let fade = exp(-max(edge, 0.0) / falloff);
    let start = smoothstep(-0.5, 3.0, edge);
    // After a reset the rings spread out from the speaker rather than
    // appearing everywhere at once.
    let front = smoothstep(0.0, 6.0, u.time * 0.85 * wavelength + 3.0 - edge);
    return ring * fade * start * front;
}

@fragment
fn fs_main(in: VSOut) -> @location(0) vec4f {
    let p = in.uv * u.res;
    let waves = speaker(p, u.left, 0.0) + speaker(p, u.right, 0.37);
    let inside = 1.0 - smoothstep(-1.0, 0.5, roundedBox(p - u.body.xy, u.body.zw, u.params.x));
    let alpha = clamp(waves, 0.0, 1.0) * u.amp * u.color.a * inside;
    return vec4f(u.color.rgb * alpha, alpha);
}
