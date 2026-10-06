// Musical time for the film: beats, bars and cue expressions resolved against
// a cut map's measured (or, for drafts, nominal) beat grid. Shared by the page
// and by video/tools/check.mjs.
const clamp = (x, a = 0, b = 1) => Math.max(a, Math.min(b, x))
const mix = (a, b, k) => a + (b - a) * k

export class Music {
  constructor(cut) {
    let { beats, downbeats } = cut
    if (!beats && cut.grid) {
      const { bpm, first = 0, bars, beatsPerBar = 4 } = cut.grid, beat = 60 / bpm
      beats = Array.from({ length: bars * beatsPerBar + 1 }, (_, i) => +(first + i * beat).toFixed(4))
      downbeats = beats.filter((_, i) => i % beatsPerBar === 0)
    }
    if (!beats?.length || !downbeats?.length) throw new Error('cut map needs beats/downbeats or a grid')
    this.beats = beats; this.downbeats = downbeats
    const gaps = beats.slice(1).map((b, i) => b - beats[i]).sort((a, b) => a - b)
    this.beat = gaps[gaps.length >> 1]
    this.duration = cut.duration
    this.landmarks = cut.landmarks || {}
    this.energy = cut.energy || null
  }
  pos(time) {
    const b = this.beats, n = b.length
    if (time <= b[0]) return (time - b[0]) / this.beat
    if (time >= b[n - 1]) return n - 1 + (time - b[n - 1]) / this.beat
    let lo = 0, hi = n - 1
    while (hi - lo > 1) { const mid = (lo + hi) >> 1; if (b[mid] <= time) lo = mid; else hi = mid }
    return lo + (time - b[lo]) / (b[lo + 1] - b[lo])
  }
  at(pos) {
    const b = this.beats, n = b.length
    if (pos <= 0) return b[0] + pos * this.beat
    if (pos >= n - 1) return b[n - 1] + (pos - n + 1) * this.beat
    const i = Math.floor(pos)
    return b[i] + (pos - i) * (b[i + 1] - b[i])
  }
  bar(n) {
    const d = this.downbeats, i = Math.floor(n)
    const base = i < 0 ? d[0] + i * 4 * this.beat : i < d.length ? d[i] : d[d.length - 1] + (i - d.length + 1) * 4 * this.beat
    return n === i ? base : this.at(this.pos(base) + (n - i) * 4)
  }
  T(expr) {
    if (typeof expr === 'number') return expr
    const text = String(expr).replace(/\s+/g, '')
    const m = text.match(/^(D-?\d+(?:\.\d+)?|B\d+(?:\.\d+)?|@\w+|-?\d+(?:\.\d+)?s?)((?:[+-]\d+(?:\.\d+)?(?:b|s|bar)?)*)$/)
    if (!m) throw new Error(`bad cue expression ${JSON.stringify(expr)}`)
    const base = m[1]
    let t = base[0] === 'D' ? this.bar(+base.slice(1)) : base[0] === 'B' ? this.at(+base.slice(1))
      : base[0] === '@' ? this.landmark(base.slice(1)) : parseFloat(base)
    for (const [, sign, value, unit] of m[2].matchAll(/([+-])(\d+(?:\.\d+)?)(b|s|bar)?/g)) {
      const v = (sign === '-' ? -1 : 1) * +value
      t = unit === 's' ? t + v : this.at(this.pos(t) + v * (unit === 'b' ? 1 : 4))
    }
    return t
  }
  landmark(name) {
    if (name === 'end') return this.duration
    if (name === 'start') return 0
    if (!(name in this.landmarks)) throw new Error(`unknown landmark @${name}`)
    return this.T(this.landmarks[name])
  }
  dur(expr, fallback = .5) {
    if (expr === undefined) return fallback
    if (typeof expr === 'number') return expr
    const m = String(expr).match(/^(\d+(?:\.\d+)?)(b|s|bar)$/)
    if (!m) throw new Error(`bad duration ${expr}`)
    return +m[1] * (m[2] === 's' ? 1 : m[2] === 'b' ? this.beat : 4 * this.beat)
  }
  // 0..1 musical energy: measured low-band envelope if present, else a beat pulse.
  level(t) {
    if (this.energy) {
      const v = this.energy.values, i = clamp(t * this.energy.fps, 0, v.length - 1)
      const a = v[Math.floor(i)], b = v[Math.min(v.length - 1, Math.ceil(i))]
      return mix(a, b, i - Math.floor(i))
    }
    const p = this.pos(t) + 1e-4, sinceBeat = (p - Math.floor(p)) * this.beat
    const sinceBar = ((p % 4 + 4) % 4) * this.beat
    return p < 0 ? 0 : .25 * Math.exp(-sinceBeat * 6) + .45 * Math.exp(-sinceBar * 2.5)
  }
}
