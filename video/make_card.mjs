// The demo video's end card: the website's pixel tarn at dusk (website/scene.js), 24 frames of
// moving water at 12 fps, sized so render.swift can lay the title over the sky.
//   node video/make_card.mjs
import { createRequire } from 'node:module'
import { mkdirSync, writeFileSync, rmSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import zlib from 'node:zlib'

const here = dirname(fileURLToPath(import.meta.url))
const scene = createRequire(import.meta.url)(join(here, '../website/scene.js'))
const W = 462, H = 300   // 4x = 1848x1200, the video's size

function png(w, h, rgba) {
  const raw = Buffer.alloc((w * 4 + 1) * h)
  for (let y = 0; y < h; y++) Buffer.from(rgba.buffer, y * w * 4, w * 4).copy(raw, y * (w * 4 + 1) + 1)
  const chunk = (type, data) => {
    const len = Buffer.alloc(4); len.writeUInt32BE(data.length)
    const body = Buffer.concat([Buffer.from(type), data])
    const crc = Buffer.alloc(4); crc.writeUInt32BE(zlib.crc32(body))
    return Buffer.concat([len, body, crc])
  }
  const ihdr = Buffer.alloc(13); ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4); ihdr[8] = 8; ihdr[9] = 6
  return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk('IHDR', ihdr), chunk('IDAT', zlib.deflateSync(raw)), chunk('IEND', Buffer.alloc(0))])
}

const out = join(here, 'card')
rmSync(out, { recursive: true, force: true })
mkdirSync(out, { recursive: true })
for (let f = 0; f < 24; f++) {
  const pixels = scene.render({ w: W, h: H, phase: 'dusk', dark: false, t: f / 12, horizon: 236, peakTop: 168,
    clear: { x0: 90, y0: 60, x1: 372, y1: 150 } })
  writeFileSync(join(out, `frame-${String(f).padStart(2, '0')}.png`), png(W, H, pixels))
}
console.log(`video/card: 24 frames, ${W}x${H}`)
