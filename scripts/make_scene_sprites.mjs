// Draws the app's pixel mountains with the website's own wallpaper code (website/scene.js), so the
// peaks and lake match the site exactly, minus the sky: four times of day, as images in the asset
// catalog. Greet* (52x32, shown at 1.5 points a pixel) sits beside the greeting; Lake* and
// Lake*Dry (140x77, shown at 3) are onboarding's lake, full and drained, so the app can show the
// water rising while the AI downloads.
//
//   node scripts/make_scene_sprites.mjs
import { createRequire } from 'node:module'
import { mkdirSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import zlib from 'node:zlib'

const root = join(dirname(fileURLToPath(import.meta.url)), '..')
const scene = createRequire(import.meta.url)(join(root, 'website/scene.js'))

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

function imageSet(name, w, h, pixels) {
  const dir = join(root, 'Tarn/Resources/Assets.xcassets', `${name}.imageset`)
  mkdirSync(dir, { recursive: true })
  writeFileSync(join(dir, `${name}.png`), png(w, h, pixels))
  writeFileSync(join(dir, 'Contents.json'), JSON.stringify({
    images: [{ filename: `${name}.png`, idiom: 'universal' }],
    info: { author: 'xcode', version: 1 },
  }, null, 2) + '\n')
}

for (const phase of scene.phases) {
  const cap = phase[0].toUpperCase() + phase.slice(1)
  const common = { phase, dark: false, noSky: true, calm: true }
  imageSet(`Greet${cap}`, 52, 32, scene.render({ ...common, bare: true, w: 52, h: 32, horizon: 21, peakTop: 3, alpha: { sides: 7, bottom: 4 } }))
  for (const dry of [false, true]) {
    imageSet(`Lake${cap}${dry ? 'Dry' : ''}`, 140, 77, scene.render({ ...common, dry, w: 140, h: 77, horizon: 50, peakTop: 11, alpha: { sides: 16, bottom: 9 } }))
  }
  console.log(`${cap}: Greet${cap} 52x32, Lake${cap} and Lake${cap}Dry 140x77`)
}
