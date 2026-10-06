// Molten material for the film: deterministic noise, a magma field, the
// flowing logo and the palette. Everything is a pure function of time.

export const PALETTE = {
  night0: '#0a0d14', night1: '#0e121b', term: '#111620', fg: '#e8ebf1',
  accent: '#ff9e61', selection: '#392b30',
  deep: '#b4461b', core: '#ec7a35', hi: '#f6a467', hot: '#ffd9a8',
  crust0: '#1c110d', crust1: '#2b1812', text0: '#f4f0f7', text2: '#b6b0c4',
}

export const clamp = (x, a = 0, b = 1) => Math.max(a, Math.min(b, x))
export const mix = (a, b, k) => a + (b - a) * k
export const smooth = (a, b, x) => { const k = clamp((x - a) / (b - a)); return k * k * (3 - 2 * k) }
export const easeOut = (x) => 1 - Math.pow(1 - clamp(x), 3)
export const easeIn = (x) => Math.pow(clamp(x), 3)
export const easeInOut = (x) => { x = clamp(x); return x < .5 ? 4 * x * x * x : 1 - Math.pow(-2 * x + 2, 3) / 2 }
// Heavy settle: fast start, long viscous tail (no overshoot).
export const viscous = (x) => 1 - Math.pow(1 - clamp(x), 4.2)

// --- noise -----------------------------------------------------------------
function hash(x, y, z) {
  let h = (x * 374761393 + y * 668265263 + z * 2147483647) | 0
  h = Math.imul(h ^ (h >>> 13), 1274126177)
  return ((h ^ (h >>> 16)) >>> 0) / 4294967295
}
const fade = (t) => t * t * (3 - 2 * t)
export function noise3(x, y, z) {
  const xi = Math.floor(x), yi = Math.floor(y), zi = Math.floor(z)
  const xf = fade(x - xi), yf = fade(y - yi), zf = fade(z - zi)
  const c = (dx, dy, dz) => hash(xi + dx, yi + dy, zi + dz)
  const x00 = mix(c(0, 0, 0), c(1, 0, 0), xf), x10 = mix(c(0, 1, 0), c(1, 1, 0), xf)
  const x01 = mix(c(0, 0, 1), c(1, 0, 1), xf), x11 = mix(c(0, 1, 1), c(1, 1, 1), xf)
  return mix(mix(x00, x10, yf), mix(x01, x11, yf), zf)
}
export function fbm(x, y, z, octaves = 4) {
  let sum = 0, amp = .5, norm = 0
  for (let i = 0; i < octaves; i++) {
    sum += amp * noise3(x, y, z)
    norm += amp
    x *= 2.03; y *= 2.03; z *= 1.7; amp *= .5
  }
  return sum / norm
}

// --- palette LUT ---------------------------------------------------------------
const hex = (h) => [1, 3, 5].map((i) => parseInt(h.slice(i, i + 2), 16))
function lut(stops) {
  const table = new Uint8ClampedArray(256 * 3)
  for (let i = 0; i < 256; i++) {
    const v = i / 255
    let k = 0
    while (k < stops.length - 2 && v > stops[k + 1][0]) k++
    const [a, ca] = stops[k], [b, cb] = stops[k + 1]
    const f = clamp((v - a) / (b - a))
    const A = hex(ca), B = hex(cb)
    for (let j = 0; j < 3; j++) table[i * 3 + j] = mix(A[j], B[j], f)
  }
  return table
}
export const MAGMA_LUT = lut([
  [0, '#0b0605'], [.30, '#1c0d09'], [.45, '#4a160b'], [.56, '#8c2a10'], [.66, '#b4461b'],
  [.76, '#ec7a35'], [.86, '#ff9e61'], [.94, '#ffd2a1'], [1, '#fff3e2'],
])

// A flowing magma field. heat shifts the whole field hotter (1) or cooler (0).
export class MagmaField {
  constructor(width, height) {
    this.canvas = document.createElement('canvas')
    this.canvas.width = width; this.canvas.height = height
    this.ctx = this.canvas.getContext('2d')
    this.image = this.ctx.createImageData(width, height)
  }
  draw(t, { scale = 3.2, speed = .08, heat = .6, seed = 0, aspect = 1 } = {}) {
    const { width: w, height: h } = this.canvas, data = this.image.data
    const z = t * speed + seed * 17.3
    for (let y = 0; y < h; y++) {
      for (let x = 0; x < w; x++) {
        const u = x / w * scale * aspect, v = y / h * scale
        // Domain warp: two slow fields bend the coordinates, so the crust flows.
        const wx = fbm(u + 1.7, v + 9.2, z, 3), wy = fbm(u + 8.3, v + 2.8, z + 3.1, 3)
        let n = fbm(u + 2.2 * wx + .3 * t * speed, v + 2.2 * wy, z * .7, 4)
        n = clamp((n - .5) * 1.9 + .5 + (heat - .5) * .9)
        const c = (n * 255) | 0, i = (y * w + x) * 4
        data[i] = MAGMA_LUT[c * 3]; data[i + 1] = MAGMA_LUT[c * 3 + 1]; data[i + 2] = MAGMA_LUT[c * 3 + 2]; data[i + 3] = 255
      }
    }
    this.ctx.putImageData(this.image, 0, 0)
    return this.canvas
  }
}

// --- the approved logo, with its magma gently flowing ---------------------------
// The envelope stays exactly as approved; only the interior of the orange blob
// is displaced by a slow noise field, so the silhouette and shading read the same.
export class LogoFlow {
  constructor(image, size = 520) {
    this.size = size
    const src = document.createElement('canvas')
    src.width = src.height = size
    const sctx = src.getContext('2d', { willReadFrequently: true })
    sctx.imageSmoothingQuality = 'high'
    sctx.drawImage(image, 0, 0, size, size)
    const pixels = sctx.getImageData(0, 0, size, size)
    const d = pixels.data, n = size * size
    const blob = new Float32Array(n)
    for (let i = 0; i < n; i++) {
      const r = d[i * 4] / 255, g = d[i * 4 + 1] / 255, b = d[i * 4 + 2] / 255, a = d[i * 4 + 3] / 255
      const max = Math.max(r, g, b), min = Math.min(r, g, b)
      const sat = max ? (max - min) / max : 0
      blob[i] = a > .05 && sat > .38 && r >= g && g >= b * .8 ? 1 : 0
    }
    // Interior weight: a blurred blob mask, so the edge barely moves.
    const weight = boxBlur(boxBlur(blob, size, 7), size, 7)
    this.weight = weight.map((v) => smooth(.55, 1, v))
    this.blobMask = boxBlur(blob, size, 1)
    this.src = pixels
    this.out = sctx.createImageData(size, size)
    this.canvas = document.createElement('canvas')
    this.canvas.width = this.canvas.height = size
    this.ctx = this.canvas.getContext('2d')
    // Envelope-only layer, for the bar icon at small sizes and for staging.
    this.still = src
  }
  draw(t, { amount = 1, flow = .16, glow = 0 } = {}) {
    const s = this.size, src = this.src.data, out = this.out.data, w = this.weight
    const amp = s * .022 * amount
    for (let y = 0; y < s; y++) {
      for (let x = 0; x < s; x++) {
        const i = y * s + x, k = w[i]
        let sx = x, sy = y
        if (k > 0 && amp > 0) {
          const u = x / s * 3.1, v = y / s * 3.1, z = t * flow
          sx = x + (fbm(u + 3.1, v + 1.3, z, 3) - .5) * 2 * amp * k
          sy = y + (fbm(u + 7.7, v + 5.9, z + 2.4, 3) - .5) * 2 * amp * k + Math.sin(t * .9 + u * 2) * amp * .25 * k
        }
        const xi = clamp(Math.round(sx), 0, s - 1), yi = clamp(Math.round(sy), 0, s - 1)
        const j = (yi * s + xi) * 4, o = i * 4
        // Sample displaced colour only inside the blob; outside, keep the original pixel.
        const from = k > 0 && this.blobMask[yi * s + xi] > .5 ? j : o
        let r = src[from], g = src[from + 1], b = src[from + 2]
        if (glow > 0 && this.blobMask[i] > .2) {
          const lift = glow * this.blobMask[i] * (.55 + .45 * fbm(x / s * 6, y / s * 6, t * .5, 2))
          r = r + (255 - r) * lift * .35; g = g + (230 - g) * lift * .28; b = b + (180 - b) * lift * .12
        }
        out[o] = r; out[o + 1] = g; out[o + 2] = b; out[o + 3] = src[o + 3]
      }
    }
    this.ctx.putImageData(this.out, 0, 0)
    return this.canvas
  }
}

function boxBlur(values, size, radius) {
  const tmp = new Float32Array(values.length), out = new Float32Array(values.length)
  for (let y = 0; y < size; y++) {
    let acc = 0
    for (let x = -radius; x <= radius; x++) acc += values[y * size + clamp(x, 0, size - 1)]
    for (let x = 0; x < size; x++) {
      tmp[y * size + x] = acc / (2 * radius + 1)
      acc += values[y * size + clamp(x + radius + 1, 0, size - 1)] - values[y * size + clamp(x - radius, 0, size - 1)]
    }
  }
  for (let x = 0; x < size; x++) {
    let acc = 0
    for (let y = -radius; y <= radius; y++) acc += tmp[clamp(y, 0, size - 1) * size + x]
    for (let y = 0; y < size; y++) {
      out[y * size + x] = acc / (2 * radius + 1)
      acc += tmp[clamp(y + radius + 1, 0, size - 1) * size + x] - tmp[clamp(y - radius, 0, size - 1) * size + x]
    }
  }
  return out
}

// --- seams ------------------------------------------------------------------------
// A molten seam: crust, glow and a white-hot core along a slightly wandering line.
// progress draws it on from `from`, heat cools it (1 = white hot, 0 = cold crust).
export function seam(ctx, x0, y0, x1, y1, { progress = 1, heat = 1, t = 0, width = 3, wander = 4, seed = 0, alpha = 1 } = {}) {
  if (progress <= 0 || alpha <= 0) return
  const length = Math.hypot(x1 - x0, y1 - y0), steps = Math.max(8, Math.ceil(length / 14))
  const nx = -(y1 - y0) / length, ny = (x1 - x0) / length
  const points = []
  for (let i = 0; i <= steps * progress; i++) {
    const k = i / steps, off = (fbm(k * 9 + seed, seed * 3.3, t * .15, 3) - .5) * 2 * wander
    points.push([x0 + (x1 - x0) * k + nx * off, y0 + (y1 - y0) * k + ny * off])
  }
  const path = () => { ctx.beginPath(); points.forEach(([x, y], i) => (i ? ctx.lineTo(x, y) : ctx.moveTo(x, y))) }
  ctx.save()
  ctx.globalAlpha = alpha
  ctx.lineCap = 'round'; ctx.lineJoin = 'round'
  path(); ctx.strokeStyle = 'rgba(20, 9, 6, .85)'; ctx.lineWidth = width * 3.2; ctx.stroke()
  ctx.shadowColor = `rgba(255, ${Math.round(mix(70, 140, heat))}, 40, ${mix(.25, .9, heat)})`
  ctx.shadowBlur = width * mix(3, 9, heat)
  path(); ctx.strokeStyle = heat > .02 ? `rgb(${mix(140, 255, heat)}, ${mix(40, 150, heat)}, ${mix(20, 70, heat)})` : '#3a1a10'
  ctx.lineWidth = width * 1.5; ctx.stroke()
  ctx.shadowBlur = 0
  if (heat > .15) {
    path(); ctx.strokeStyle = `rgba(255, ${Math.round(mix(190, 245, heat))}, ${Math.round(mix(140, 215, heat))}, ${smooth(.15, .6, heat)})`
    ctx.lineWidth = width * .55; ctx.stroke()
  }
  // The leading edge of a seam that is still drawing glows brightest.
  if (progress < 1 && points.length) {
    const [hx, hy] = points[points.length - 1]
    const g = ctx.createRadialGradient(hx, hy, 0, hx, hy, width * 9)
    g.addColorStop(0, 'rgba(255, 236, 200, .95)'); g.addColorStop(.3, 'rgba(255, 150, 70, .5)'); g.addColorStop(1, 'rgba(255, 120, 40, 0)')
    ctx.fillStyle = g; ctx.fillRect(hx - width * 9, hy - width * 9, width * 18, width * 18)
  }
  ctx.restore()
}

// Seeded film grain tile, generated once.
export function grainTile(size = 256, seed = 7) {
  const canvas = document.createElement('canvas')
  canvas.width = canvas.height = size
  const ctx = canvas.getContext('2d'), image = ctx.createImageData(size, size)
  for (let i = 0; i < size * size; i++) {
    const v = hash(i % size, Math.floor(i / size), seed) * 255
    image.data[i * 4] = image.data[i * 4 + 1] = image.data[i * 4 + 2] = v
    image.data[i * 4 + 3] = 255
  }
  ctx.putImageData(image, 0, 0)
  return canvas.toDataURL()
}
export const frameHash = (i) => hash(i, 91, 3)
