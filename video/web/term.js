// Paints real captured TUI screens. A tape (video/capture/tape.py) is the
// sequence of PTY states the published executable drew; this module only
// draws those cells: text runs as DOM, box-drawing characters as vectors so
// borders stay continuous and sharp at any camera zoom. Nothing is invented.

const SVG = 'http://www.w3.org/2000/svg'
const BOLD = 1, ITALIC = 2, UNDERLINE = 4, STRIKE = 8

export class Tape {
  constructor(json) {
    Object.assign(this, { name: json.tape, columns: json.columns, rows: json.rows, styles: json.styles,
      defaults: json.defaults, marks: json.marks, binary: json.binary })
    let rows = null
    this.frames = json.frames.map((frame) => {
      rows = rows ? frame.rows.map((row, y) => row ?? rows[y]) : frame.rows.map((row) => row ?? [])
      return { t: frame.t, rows, cursor: frame.cursor }
    })
    this.byName = new Map()
    for (const mark of this.marks) if (!this.byName.has(mark.name)) this.byName.set(mark.name, mark)
  }
  mark(name) {
    const mark = this.byName.get(name)
    if (!mark) throw new Error(`tape ${this.name}: no mark ${name}`)
    return mark
  }
  // Last frame whose capture time is <= tapeTime.
  frameAt(tapeTime) {
    let lo = 0, hi = this.frames.length - 1
    if (tapeTime <= this.frames[0].t) return 0
    while (lo < hi) {
      const mid = (lo + hi + 1) >> 1
      if (this.frames[mid].t <= tapeTime) lo = mid
      else hi = mid - 1
    }
    return lo
  }
  // A character/colour grid for layout queries (pane detection, text lookup).
  grid(index) {
    const frame = this.frames[index]
    if (frame.grid) return frame.grid
    const grid = Array.from({ length: this.rows }, () => Array.from({ length: this.columns }, () => [' ', null]))
    frame.rows.forEach((runs, y) => {
      for (const [x, text, style, cells] of runs) {
        if (cells === text.length) for (let i = 0; i < text.length; i++) grid[y][x + i] = [text[i], this.styles[style]]
        else grid[y][x] = [text, this.styles[style]]
      }
    })
    frame.grid = grid
    return grid
  }
  text(index, y) { return this.grid(index)[y].map((c) => c[0]).join('') }
  find(index, literal) {
    for (let y = 0; y < this.rows; y++) {
      const x = this.text(index, y).indexOf(literal)
      if (x >= 0) return { x, y }
    }
    return null
  }
  // Rectangular panes drawn with rounded or square box corners.
  panes(index) {
    const frame = this.frames[index]
    if (frame.panes) return frame.panes
    const g = this.grid(index), panes = []
    for (let y = 0; y < this.rows; y++) {
      for (let x = 0; x < this.columns; x++) {
        if (!'╭┌'.includes(g[y][x][0])) continue
        let x1 = x + 1
        while (x1 < this.columns && !'╮┐'.includes(g[y][x1][0])) x1++
        let y1 = y + 1
        while (y1 < this.rows && !'╰└'.includes(g[y1][x][0])) y1++
        if (x1 >= this.columns || y1 >= this.rows || !'╯┘'.includes(g[y1][x1][0])) continue
        const title = g[y].slice(x + 1, x1).map((c) => c[0]).join('').replace(/[─━═]/g, ' ').trim()
        panes.push({ x0: x, y0: y, x1, y1, title, color: g[y][x][1]?.[0] || this.defaults.fg })
      }
    }
    frame.panes = panes
    return panes
  }
  pane(index, query) {
    const panes = this.panes(index)
    if (query === 'focused') return panes.find((p) => p.color.toLowerCase() === '#ff9e61') || null
    return panes.find((p) => p.title.startsWith(query)) || panes.find((p) => p.title.includes(query)) || null
  }
}

// Box drawing: which cell edges each glyph connects, and whether it is rounded.
const BOX = {
  '─': 'lr', '━': 'lr', '│': 'ud', '┃': 'ud', '┌': 'rd', '┐': 'ld', '└': 'ru', '┘': 'lu',
  '├': 'udr', '┤': 'udl', '┬': 'lrd', '┴': 'lru', '┼': 'lrud', '╭': 'rd~', '╮': 'ld~', '╯': 'lu~', '╰': 'ru~',
  '╴': 'l', '╶': 'r', '╵': 'u', '╷': 'd', '═': 'lr=', '║': 'ud=', '╔': 'rd=', '╗': 'ld=', '╚': 'ru=', '╝': 'lu=',
}
const isBox = (ch) => ch in BOX

export class TermView {
  // cell: { w, h } in CSS px at zoom 1; font size follows the mono advance (0.6 em).
  constructor(host, { cellW = 12, cellH = 26, columns = 132, rows = 36 } = {}) {
    this.cellW = cellW; this.cellH = cellH; this.font = cellW / .6
    this.host = host
    this.el = document.createElement('div')
    this.el.className = 'term-grid'
    this.resize(columns, rows)
    this.text = document.createElement('div'); this.text.className = 'term-text'
    this.lines = document.createElementNS(SVG, 'svg'); this.lines.setAttribute('class', 'term-lines')
    this.cursor = document.createElement('div'); this.cursor.className = 'term-cursor'
    this.el.append(this.text, this.lines, this.cursor)
    host.append(this.el)
    this.key = null
  }
  resize(columns, rows) {
    this.columns = columns; this.rows = rows
    this.width = columns * this.cellW; this.height = rows * this.cellH
    Object.assign(this.el.style, { width: `${this.width}px`, height: `${this.height}px`, fontSize: `${this.font}px`,
      lineHeight: `${this.cellH}px` })
  }
  cell(x, y) { return { x: x * this.cellW, y: y * this.cellH, w: this.cellW, h: this.cellH } }
  rect(pane) {
    return { x: pane.x0 * this.cellW, y: pane.y0 * this.cellH,
      w: (pane.x1 - pane.x0 + 1) * this.cellW, h: (pane.y1 - pane.y0 + 1) * this.cellH }
  }
  show(tape, index, { blink = true } = {}) {
    const key = `${tape.name}:${index}`
    if (tape.columns !== this.columns || tape.rows !== this.rows) this.resize(tape.columns, tape.rows)
    if (key !== this.key) {
      this.key = key
      this.paint(tape, tape.frames[index])
    }
    const cursor = tape.frames[index].cursor
    this.cursor.style.display = cursor && blink ? 'block' : 'none'
    if (cursor) {
      const [x, y, shape] = cursor
      const beam = shape === 5 || shape === 6, under = shape === 3 || shape === 4
      Object.assign(this.cursor.style, { left: `${x * this.cellW}px`, top: `${y * this.cellH + (under ? this.cellH - 3 : 0)}px`,
        width: `${beam ? 2.5 : this.cellW}px`, height: `${under ? 3 : this.cellH}px` })
    }
  }
  paint(tape, frame) {
    const { cellW: cw, cellH: ch } = this
    const parts = [], segments = new Map()
    const add = (color, d) => { if (!segments.has(color)) segments.set(color, []); segments.get(color).push(d) }
    frame.rows.forEach((runs, y) => {
      for (const [x, text, styleIndex, cells] of runs) {
        const [fg, bg, flags] = tape.styles[styleIndex]
        let shown = text
        if (cells === text.length) {
          let replaced = ''
          for (let i = 0; i < text.length; i++) {
            const c = text[i]
            if (isBox(c)) { boxPath(add, fg, c, (x + i) * cw, y * ch, cw, ch); replaced += ' ' } else replaced += c
          }
          shown = replaced
        }
        // Blank cells still paint a background or an underline/strike decoration.
        if (!shown.trim() && !bg && !(flags & (UNDERLINE | STRIKE))) continue
        const style = [`left:${x * cw}px`, `top:${y * ch}px`, `width:${cells * cw}px`, `color:${fg}`]
        if (bg) style.push(`background:${bg}`)
        if (flags & BOLD) style.push('font-weight:700')
        if (flags & ITALIC) style.push('font-style:italic')
        const deco = [flags & UNDERLINE ? 'underline' : '', flags & STRIKE ? 'line-through' : ''].filter(Boolean).join(' ')
        if (deco) style.push(`text-decoration:${deco}`)
        const cls = cells !== text.length ? 'run wide' : 'run'
        parts.push(`<span class="${cls}" style="${style.join(';')}">${escapeHtml(shown)}</span>`)
      }
    })
    this.text.innerHTML = parts.join('')
    const width = Math.max(1.3, ch * .055).toFixed(2)
    this.lines.setAttribute('viewBox', `0 0 ${this.width} ${this.height}`)
    this.lines.setAttribute('width', this.width); this.lines.setAttribute('height', this.height)
    this.lines.innerHTML = [...segments].map(([color, ds]) =>
      `<path d="${ds.join('')}" stroke="${color}" stroke-width="${width}" fill="none" stroke-linecap="square"/>`).join('')
  }
}

function boxPath(add, color, ch, x, y, w, h) {
  const spec = BOX[ch], cx = x + w / 2, cy = y + h / 2
  if (spec.includes('~')) {
    // Rounded corner: straight to within r of the centre, then a quarter curve.
    const r = Math.min(w, h) * .5
    const horiz = spec.includes('l') ? [x, cy, cx - r] : [x + w, cy, cx + r]
    const vert = spec.includes('u') ? [cx, y, cy - r] : [cx, y + h, cy + r]
    add(color, `M${horiz[0]} ${cy}L${horiz[2]} ${cy}Q${cx} ${cy} ${cx} ${vert[2]}L${cx} ${vert[1]}`)
    return
  }
  const double = spec.includes('=') ? 1.6 : 0
  const draw = (o) => {
    if (spec.includes('l')) add(color, `M${x} ${cy + o}L${cx} ${cy + o}`)
    if (spec.includes('r')) add(color, `M${cx} ${cy + o}L${x + w} ${cy + o}`)
    if (spec.includes('u')) add(color, `M${cx + o} ${y}L${cx + o} ${cy}`)
    if (spec.includes('d')) add(color, `M${cx + o} ${cy}L${cx + o} ${y + h}`)
  }
  if (double) { draw(-double); draw(double) } else draw(0)
}

function escapeHtml(text) {
  return text.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c])
}

// The closed outline of a pane in grid pixels, clockwise from the top-left corner,
// for the border pulse. Returns an SVG path string and its length.
export function paneOutline(view, pane) {
  const r = Math.min(view.cellW, view.cellH) * .5
  const x0 = (pane.x0 + .5) * view.cellW, y0 = (pane.y0 + .5) * view.cellH
  const x1 = (pane.x1 + .5) * view.cellW, y1 = (pane.y1 + .5) * view.cellH
  const d = `M${x0 + r} ${y0}L${x1 - r} ${y0}Q${x1} ${y0} ${x1} ${y0 + r}L${x1} ${y1 - r}Q${x1} ${y1} ${x1 - r} ${y1}` +
    `L${x0 + r} ${y1}Q${x0} ${y1} ${x0} ${y1 - r}L${x0} ${y0 + r}Q${x0} ${y0} ${x0 + r} ${y0}Z`
  const length = 2 * (x1 - x0 + y1 - y0) - (8 - 2 * Math.PI) * r
  return { d, length }
}
