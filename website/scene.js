/* Tarn's wallpaper: a pixel-art tarn (the mark's two peaks over still water) lit by the visitor's
   own clock: a pastel dawn, a clear day, a Miami sunset, and a rainy night with neon on the water.
   render() fills a small RGBA grid that the page scales up with crisp pixels. The app's mountains
   and the demo video's end card are drawn from this same file (scripts/make_scene_sprites.mjs,
   video/make_card.mjs), so they always match the site. */
;(function (root) {
  'use strict'

  // Ordered (Bayer 4x4) dithering: the Game Boy Advance way to blend two colours.
  var BAYER = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5]
  function on(x, y, f) { return f > (BAYER[(y & 3) * 4 + (x & 3)] + 0.5) / 16 }
  function hash(x, y) {
    var h = (Math.imul(x | 0, 374761393) + Math.imul(y | 0, 668265263)) | 0
    h = Math.imul(h ^ (h >>> 13), 1274126177)
    return ((h ^ (h >>> 16)) >>> 0) / 4294967296
  }
  function rgb(hex) { var n = parseInt(hex.slice(1), 16); return [n >> 16 & 255, n >> 8 & 255, n & 255] }
  function mix(a, b, t) { return [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t] }
  function clamp(v, a, b) { return v < a ? a : v > b ? b : v }

  var PALETTES = {
    dawn: {
      sky: ['#8e9fd0', '#b1a8d6', '#d6afcf', '#eebcb8', '#f7cfb2', '#fbe2c2'],
      sun: '#fff6df', glow: '#ffdcb0',
      far: '#b29cc4', farTop: '#c6b2d5',
      rock: '#7a6898', lit: '#a48dbd', shade: '#625380',
      snow: '#faf0f4', snowShade: '#d6c4dd',
      tree: '#463c60', treeLit: '#5a4e77', shore: '#3b3354',
      water: ['#dfc0d3', '#c5b0d6', '#a493c4'], glint: '#fff3e4'
    },
    day: {
      sky: ['#5a9ad5', '#73ade0', '#8fc0e8', '#acd3ef', '#c9e3f4', '#e0eff6'],
      sun: '#fffbe6', glow: '#fff1bd', cloud: '#ffffff', cloudShade: '#d3e4f0',
      far: '#97b5c8', farTop: '#afc9d7',
      rock: '#5a7a84', lit: '#82a1a8', shade: '#47636c',
      snow: '#ffffff', snowShade: '#c6d9e3',
      tree: '#29554a', treeLit: '#3a6a5a', shore: '#204238',
      water: ['#8cc1cd', '#4c95a3', '#2b7482'], glint: '#effafc'
    },
    dusk: {
      sky: ['#271f52', '#47286a', '#813276', '#c9446d', '#ee715c', '#f9ae67'],
      sun: ['#ffe089', '#ff9a5d', '#ff4f8a'], glow: '#ff8a76',
      far: '#552a67', farTop: '#7a3a77',
      rock: '#2a1c45', lit: '#e2587c', shade: '#1f1532',
      snow: '#f0a2b8', snowShade: '#764689',
      tree: '#18102e', treeLit: '#27183d', shore: '#100a20',
      water: ['#c04878', '#692c6c', '#2b1d4b'], glint: '#ffd28a'
    },
    night: {
      sky: ['#05091a', '#0a112b', '#10183b', '#162049', '#1d2855', '#253162'],
      moon: '#f3efd6', star: '#ffffff', starDim: '#8a9fdd',
      far: '#121a3a', farTop: '#1c2650',
      rock: '#0c122c', lit: '#2c3a74', shade: '#080d20',
      snow: '#a6b3e5', snowShade: '#5866a4',
      tree: '#060a1a', treeLit: '#0d132e', shore: '#040716',
      water: ['#18234d', '#0d1433', '#070b20'], glint: '#6d81c7',
      neon: ['#ff4fa3', '#47e4f1', '#ffb25d'], rain: '#8ea6e6'
    }
  }

  // On a dark page the sky deepens so the hero doesn't glare. Dawn and day get their own
  // hand-picked "blue hour" palettes (dimming them toward navy made them muddy); dusk and night
  // are already dark and only dim a little. Light sources keep most of their glow.
  var DARK = {
    dawn: {
      sky: ['#272a4d', '#35335e', '#4f3b69', '#6d446f', '#8a526f', '#a26572'],
      sun: '#ffe4c6', glow: '#a86d78',
      far: '#463c61', farTop: '#564a72',
      rock: '#372f55', lit: '#544777', shade: '#2a2343',
      snow: '#d6c8df', snowShade: '#8a7ba3',
      tree: '#211b34', treeLit: '#2b2443', shore: '#1a152a',
      water: ['#71557a', '#52436d', '#372f55'], glint: '#ffdcc4'
    },
    day: {
      sky: ['#19375f', '#1f4475', '#285389', '#33639a', '#4174a9', '#5284b4'],
      sun: '#fff3cb', glow: '#5f81ad', cloud: '#c3d3e4', cloudShade: '#8aa2bf',
      far: '#365673', farTop: '#456785',
      rock: '#2a4350', lit: '#43636f', shade: '#20353e',
      snow: '#d3e0e9', snowShade: '#8aa1b1',
      tree: '#143127', treeLit: '#1d4134', shore: '#0f241d',
      water: ['#3d7284', '#285869', '#1a404e'], glint: '#cde5ee'
    }
  }
  var DIM = { dawn: 0, day: 0, dusk: 0.16, night: 0.06 }
  // Without a sky (the app's version), the dusk and night peaks would vanish against a dark window,
  // so they're lit a little more, as if by the last light and a bright moon.
  var NO_SKY = {
    dusk: { rock: '#4d3270', shade: '#3e2860', snowShade: '#8e5aa0', far: '#6a3a7c', farTop: '#874a8a',
            tree: '#2e1d48', treeLit: '#3d2758', shore: '#22143a', water: ['#c04878', '#7a3478', '#4a2a6a'] },
    night: { rock: '#2f3c7a', lit: '#5868ae', shade: '#26306a', snow: '#c3cdf2', snowShade: '#8794cc', far: '#28336a',
             farTop: '#34417e', tree: '#1c2452', treeLit: '#26306a', shore: '#141a3c', water: ['#2c3a74', '#1f2a5c', '#16204a'] }
  }
  var BRIGHT = { sun: 1, glow: 1, moon: 1, star: 1, neon: 1, glint: 1 }
  var NAVY = [12, 16, 30]
  function palette(phase, dark, noSky) {
    var src = dark && DARK[phase] ? DARK[phase] : PALETTES[phase], out = {}
    if (noSky && NO_SKY[phase]) { var merged = {}; for (var mk in src) merged[mk] = src[mk]; for (var nk2 in NO_SKY[phase]) merged[nk2] = NO_SKY[phase][nk2]; src = merged }
    for (var key in src) {
      var k = dark ? (BRIGHT[key] ? DIM[phase] * 0.3 : DIM[phase]) : 0
      var conv = function (hex) { return mix(rgb(hex), NAVY, k) }
      out[key] = Array.isArray(src[key]) ? src[key].map(conv) : conv(src[key])
    }
    out.hill = mix(out.far, out.tree, 0.55)
    return out
  }

  function phaseAt(date) {
    var h = date.getHours()
    return h >= 5 && h < 8 ? 'dawn' : h >= 8 && h < 17 ? 'day' : h >= 17 && h < 20 ? 'dusk' : 'night'
  }

  /* o: { w, h, phase, dark, t (seconds, animates water, stars and rain), horizon (row where the
     lake starts), peakTop (row of the highest summit), fade (rows dissolving into o.bg at the
     bottom), bg ([r,g,b]), clear ({x0, y0, x1, y1}: where the page's text sits; clouds and
     gulls stay out of it and stars and rain thin out behind it), calm (a still picture: no rain or
     rings), dry (the lake drained to its stony bed, for the app's "filling while it downloads"),
     alpha ({ sides, top, bottom }: columns and rows that dissolve into transparency), bare (just the
     peaks and the lake: no far range, hills or trees, for the app's small version) } */
  function render(o) {
    var w = o.w, h = o.h, t = o.t || 0, phase = o.phase, noSky = !!o.noSky
    var P = palette(phase, o.dark && !noSky, noSky)
    var buf = new Uint8ClampedArray(w * h * 4)
    function put(x, y, c) {
      if (x < 0 || y < 0 || x >= w || y >= h) return
      var i = (y * w + x) * 4
      buf[i] = c[0]; buf[i + 1] = c[1]; buf[i + 2] = c[2]; buf[i + 3] = 255
    }
    function get(x, y) {
      var i = (clamp(y, 0, h - 1) * w + clamp(x, 0, w - 1)) * 4
      return [buf[i], buf[i + 1], buf[i + 2]]
    }
    function blend(x, y, c, a) { if (x >= 0 && y >= 0 && x < w && y < h) put(x, y, mix(get(x, y), c, a)) }
    function opaque(x, y) { return x >= 0 && y >= 0 && x < w && y < h && buf[(y * w + x) * 4 + 3] > 0 }
    function disc(cx, cy, r, fn) {
      for (var y = Math.floor(cy - r); y <= Math.ceil(cy + r); y++)
        for (var x = Math.floor(cx - r); x <= Math.ceil(cx + r); x++) {
          var d = Math.sqrt((x - cx) * (x - cx) + (y - cy) * (y - cy))
          if (d <= r + 0.15) fn(x, y, d)
        }
    }

    var clear = o.clear || { x0: 0, y0: 0, x1: -1, y1: -1 }
    function behindText(x, y) { return x >= clear.x0 && x <= clear.x1 && y >= clear.y0 && y <= clear.y1 }
    var horizon = o.horizon != null ? o.horizon : Math.round(h * 0.72)
    var top = clamp(o.peakTop != null ? o.peakTop : Math.round(horizon * 0.3), 1, horizon - 6)
    var rise = horizon - top

    // The massif, in the mark's proportions (assets/mark.svg): a taller left summit, a deep saddle,
    // a slightly lower right summit, steep outer flanks.
    var xs = Math.round(w / 2 - rise * 0.045)
    var xl = xs - Math.round(rise * 0.43), xr = xs + Math.round(rise * 0.38)
    var yl = top, ys = horizon - Math.round(rise * 0.48), yr = horizon - Math.round(rise * 0.9)
    var bl = xl - Math.round(rise * 0.76), br = xr + Math.round((horizon - yr) * 1.0)
    var ridge = [[bl, horizon], [xl, yl], [xs, ys], [xr, yr], [br, horizon]]
    function ridgeY(x) {
      for (var k = 0; k < 4; k++) {
        var a = ridge[k], b = ridge[k + 1]
        if (x >= a[0] && x <= b[0]) return a[1] + (b[1] - a[1]) * (x - a[0]) / Math.max(1, b[0] - a[0])
      }
      return horizon
    }
    var sunX = xs, sunY = 0, sunR = 0

    // Sky: flat bands with a narrow dithered seam; more bands crowd toward the horizon.
    var sky = P.sky, n = sky.length - 1
    for (var y = 0; y < (noSky ? 0 : horizon); y++) {
      var s = Math.pow(y / Math.max(1, horizon - 1), 1.9) * n
      var i = Math.min(n - 1, Math.floor(s)), g = clamp((s - i - 0.35) / 0.3, 0, 1)
      for (var x = 0; x < w; x++) put(x, y, on(x, y, g) ? sky[i + 1] : sky[i])
    }

    // Sun, moon, stars, clouds and birds.
    function cloud(cx, cy, cw) {
      // Puffs on a flat base, shaded along the bottom.
      var puffs = [[-0.28, 0.12, 0.2], [-0.1, 0.02, 0.24], [0.1, -0.06, 0.28], [0.3, 0.1, 0.19]]
      var base = cy + Math.round(cw * 0.14), shade = Math.max(1, Math.round(cw * 0.05))
      for (var y = cy - Math.round(cw * 0.36); y <= base; y++)
        for (var x = cx - Math.round(cw * 0.55); x <= cx + Math.round(cw * 0.55); x++) {
          for (var q = 0; q < puffs.length; q++) {
            var qx = cx + puffs[q][0] * cw, qy = cy + puffs[q][1] * cw, qr = puffs[q][2] * cw
            if ((x - qx) * (x - qx) + (y - qy) * (y - qy) <= qr * qr) { put(x, y, y > base - shade ? P.cloudShade : P.cloud); break }
          }
        }
    }
    if (phase === 'dawn') {
      sunR = Math.max(2, Math.round(rise * 0.17)); sunY = ys + sunR * 0.15
      if (!noSky) disc(sunX, sunY, sunR * 2.3, function (x, y, d) { if (on(x, y, 0.5 * (1 - d / (sunR * 2.3)))) put(x, y, P.glow) })
      disc(sunX, sunY, sunR, function (x, y) { put(x, y, P.sun) })
    } else if (phase === 'day') {
      sunR = Math.max(2.2, rise * 0.08); sunX = Math.round(w * 0.8); sunY = Math.round(horizon * 0.2)
      if (!noSky) disc(sunX, sunY, sunR * 2.4, function (x, y, d) { if (on(x, y, 0.45 * (1 - d / (sunR * 2.4)))) put(x, y, P.glow) })
      disc(sunX, sunY, sunR, function (x, y) { put(x, y, P.sun) })
      if (!noSky) {
        ;[[0.05, 0.3, 1], [0.95, 0.5, 0.8], [0.13, 0.62, 0.55]].forEach(function (c, ci) {
          var cw = Math.max(8, Math.round(rise * 0.75 * c[2]))
          var cx = Math.round(c[0] * w + Math.sin(t * 0.05 + ci * 2) * 4), cy = Math.round(horizon * c[1])
          if (behindText(cx - cw / 2, cy) || behindText(cx + cw / 2, cy)) return
          cloud(cx, cy, cw)
        })
        for (var bi = 0; bi < 3; bi++) {        // a few gulls, circling near the sun
          var bx = Math.round(sunX - 10 + Math.sin(t * 0.25 + bi * 2.1) * 9 + bi * 5)
          var by = Math.round(sunY + 9 + bi * 3 + Math.sin(t * 0.8 + bi) * 1.5)
          if (behindText(bx, by)) continue
          var up = Math.floor(t * 3 + bi) % 2 === 0, bc = P.tree
          put(bx - 1, by, bc); put(bx, by, bc); put(bx + 1, by, bc)
          put(bx - 2, by + (up ? -1 : 1), bc); put(bx + 2, by + (up ? -1 : 1), bc)
        }
      }
    } else if (phase === 'dusk') {
      // A synthwave sun sinking into the saddle, cut by bands that thicken toward the horizon.
      sunR = Math.max(3, Math.round(rise * 0.4)); sunY = ys - Math.round(sunR * 0.15)
      if (!noSky) disc(sunX, sunY, sunR * 1.7, function (x, y, d) { if (on(x, y, 0.4 * (1 - d / (sunR * 1.7)))) put(x, y, P.glow) })
      var period = Math.max(3, Math.round(sunR * 0.3))
      disc(sunX, sunY, sunR, function (x, y) {
        var v = (y - (sunY - sunR)) / (2 * sunR), below = y - sunY
        if (below > 0 && (Math.round(below) % period) < 1 + Math.floor(below / sunR * 2)) return
        put(x, y, v < 0.5 ? (on(x, y, v * 2) ? P.sun[1] : P.sun[0]) : (on(x, y, (v - 0.5) * 2) ? P.sun[2] : P.sun[1]))
      })
    } else {
      var mr = Math.max(3, Math.round(rise * 0.12)), mx = Math.round(w * 0.79), my = Math.round(horizon * 0.2)
      var count = noSky ? 0 : Math.round(w * horizon / 650)
      for (var si = 0; si < count; si++) {
        var sx = Math.floor(hash(si, 1) * w), sy = Math.floor(hash(si, 2) * horizon * 0.8)
        if (Math.abs(sx - mx) <= mr + 2 && Math.abs(sy - my) <= mr + 2) continue
        if (behindText(sx, sy) && hash(si, 5) < 0.75) continue
        if (hash(si, 3) < 0.35 && Math.sin(t * 2.3 + si * 1.7) < -0.3) continue   // twinkle
        put(sx, sy, hash(si, 4) < 0.3 ? P.star : P.starDim)
      }
      disc(mx, my, mr, function (x, y) {
        var cx = mx + mr * 0.5, cy = my - mr * 0.28
        if (Math.sqrt((x - cx) * (x - cx) + (y - cy) * (y - cy)) > mr * 0.9) put(x, y, P.moon)
      })
      sunX = mx; sunR = mr
    }

    // The far range: hazy, peaky, higher at the edges so it frames the massif.
    function tri(x, period) { var q = x / period; return Math.abs(q - Math.floor(q) - 0.5) * 2 }
    for (var fx = 0; fx < (o.bare ? 0 : w); fx++) {
      var e = Math.abs(fx / w - 0.5) * 2
      var farA = rise * (0.24 + 0.36 * Math.pow(e, 1.5)) + rise * 0.12 * (tri(fx + 7, w * 0.19 + 9) - 0.5) + rise * 0.05 * (tri(fx, 23) - 0.5)
      var top1 = horizon - Math.max(1, Math.round(farA))
      for (var fy = top1; fy < horizon; fy++) put(fx, fy, fy === top1 ? P.farTop : P.far)
    }

    // The massif. Spines run down from each summit and split light from shadow; creases cut a few
    // facets. Light comes from the saddle at dawn, from the right by day and under the moon, and
    // from behind at dusk (a rim on the ridge only). Snow follows the summits and runs down gullies.
    function spineX(pk, y) { return pk === 0 ? xl + (y - yl) * -0.32 : xr + (y - yr) * -0.26 }
    function isLit(x, y) {
      var pk = x < xs ? 0 : 1, sx = spineX(pk, y)
      if (phase === 'dusk') return false
      if (phase === 'dawn') return pk === 0 ? x >= sx : x <= sx
      return x >= sx
    }
    var creases = [[0, xl - rise * 0.62, -0.7], [0, xl - rise * 0.36, -0.5], [0, xl + rise * 0.24, 0.18], [1, xr - rise * 0.18, -0.08], [1, xr + rise * 0.3, 0.36], [1, xr + rise * 0.58, 0.55]]
    creases.forEach(function (cr) { cr.push(Math.round(ridgeY(Math.round(cr[1])))) })
    var massif = new Uint8Array(w * h)
    for (var px = Math.max(0, bl); px <= Math.min(w - 1, br); px++) {
      var ry = Math.round(ridgeY(px)) + (hash(px >> 1, 11) < 0.22 ? 1 : 0)
      var pk = px < xs ? 0 : 1, apex = pk === 0 ? xl : xr
      var snowDepth = Math.max(0, rise * 0.3 - Math.abs(px - apex) * 0.3) + Math.round((hash(px >> 1, 21) - 0.5) * 3)
      for (var py = ry; py < horizon; py++) {
        var L = isLit(px, py), depth = (py - ry) / Math.max(1, horizon - ry)
        var nearSpine = Math.abs(px - spineX(pk, py)) < 0.75 && py < top + rise * 0.62
        var onCrease = false
        for (var ci = 0; ci < creases.length; ci++) {
          var cr = creases[ci]
          if (cr[0] !== pk || py < cr[3] || py > cr[3] + rise * 0.5) continue
          var cx = cr[1] + (py - cr[3]) * cr[2] + (hash(Math.floor(py / 3), ci + 71) < 0.3 ? 1 : 0)
          if (Math.abs(px - cx) < 0.6) { onCrease = true; break }
        }
        var snowy = (py - ry) < snowDepth || ((nearSpine || onCrease) && py < top + rise * 0.5 && hash(px, py) < 0.8)
        var c
        if (phase === 'dusk') {
          c = depth > 0.45 && on(px, py, (depth - 0.45) * 1.4) ? P.shade : P.rock
          if (snowy) c = (py - ry) < 2 && px >= xl && px <= xr ? P.snow : P.snowShade
          else if (onCrease || nearSpine) c = P.shade
        } else if (snowy) {
          c = L ? P.snow : P.snowShade
        } else {
          c = L ? P.lit : P.rock
          if (!L && depth > 0.5 && on(px, py, (depth - 0.5) * 1.5)) c = P.shade
          if (onCrease) c = L ? P.rock : mix(P.rock, P.lit, 0.4)
        }
        put(px, py, c)
        if (py >= 0 && py < h) massif[py * w + px] = 1
      }
      if (phase === 'dusk' && px >= xl - 1 && px <= xr + 1) put(px, ry, P.lit)   // backlit rim toward the sun
    }
    // With no sky behind it, a one-pixel outline keeps the massif's silhouette crisp on any window.
    if (noSky) {
      var edge = []
      for (var oy = 0; oy < horizon; oy++)
        for (var ox2 = 0; ox2 < w; ox2++) {
          if (opaque(ox2, oy)) continue
          var i2 = oy * w + ox2
          if ((ox2 > 0 && massif[i2 - 1]) || (ox2 < w - 1 && massif[i2 + 1]) || (oy < h - 1 && massif[i2 + w])) edge.push(ox2, oy)
        }
      for (var ei = 0; ei < edge.length; ei += 2) put(edge[ei], edge[ei + 1], P.shade)
    }

    // Nearer hills, low in the middle, with a fringe of treetops.
    for (var hx = 0; hx < (o.bare ? 0 : w); hx++) {
      var he = Math.abs(hx / w - 0.5) * 2
      var hh = rise * (0.06 + 0.16 * Math.pow(he, 1.3)) + rise * 0.025 * Math.sin(hx * 0.09 + 2)
      var fringe = (hash(hx, 61) < 0.45 ? 1 : 0) + (hx % 3 === 0 ? 1 : 0)
      for (var hy = horizon - Math.max(1, Math.round(hh)) - fringe; hy < horizon; hy++) put(hx, hy, P.hill)
    }

    // Shoreline and conifers, thickest at the edges so they frame the water.
    for (var tx = 0; tx < w; tx++) if (!o.bare || opaque(tx, horizon - 1)) put(tx, horizon - 1, P.shore)
    var treeMax = Math.max(2, Math.round(rise * 0.2))
    for (var tx2 = 0; tx2 < (o.bare ? 0 : w); tx2++) {
      var te = Math.abs(tx2 / w - 0.5) * 2
      if (hash(tx2, 31) > 0.03 + 0.5 * Math.pow(te, 2.4)) continue
      var th = 2 + Math.round(hash(tx2, 37) * (treeMax - 2) * (0.4 + te * 0.75))
      for (var r = 0; r < th; r++) {
        var half = Math.floor((r + 1) * 0.42), row = horizon - th + r
        for (var dx = -half; dx <= half; dx++) put(tx2 + dx, row, dx > 0 === (phase !== 'dawn') ? P.treeLit : P.tree)
      }
    }

    // Night: cabins and two neon signs on the far shore.
    var lights = []
    if (phase === 'night') {
      var spots = [[0.09, 0], [0.17, 2], [0.83, 1], [0.92, 2]]
      spots.forEach(function (sp) {
        var lx = Math.round(sp[0] * w), ly = horizon - 2
        put(lx, ly, P.neon[sp[1]])
        if (sp[1] < 2) put(lx + 1, ly, P.neon[sp[1]])
        lights.push([lx, P.neon[sp[1]]])
      })
    }

    var lakeH = h - horizon, wn = P.water.length - 1
    if (o.dry) {
      for (var dk = 0; dk < lakeH; dk++) {
        var dd2 = dk / Math.max(1, lakeH - 1)
        for (var dx2 = 0; dx2 < w; dx2++) {
          var bed = on(dx2, horizon + dk, 0.3 + dd2 * 0.5) ? P.shade : P.rock
          if (dk === 0) bed = P.shore
          else if (hash(dx2, horizon + dk + 7) < 0.05) bed = P.lit
          put(dx2, horizon + dk, bed)
        }
      }
      lakeH = 0
    }

    // The lake: the scene above mirrored, with short ripple lines drifting across it.
    for (var k = 0; k < lakeH; k++) {
      var wy = horizon + k, d = k / Math.max(1, lakeH - 1)
      var wi = Math.min(wn - 1, Math.floor(d * wn)), wf = clamp((d * wn - wi - 0.35) / 0.3, 0, 1)
      var src = horizon - 1 - k
      var ox = Math.round(Math.sin(k * 0.9 + t * 1.7) * Math.min(1.5, 0.3 + k * 0.05))
      var calmDown = 1 - clamp((d - 0.6) / 0.4, 0, 1)
      var keep = (0.55 - d * 0.25) * (o.deepBelow ? calmDown : 1)
      for (var lx2 = 0; lx2 < w; lx2++) {
        var base = on(lx2, wy, wf) ? P.water[wi + 1] : P.water[wi]
        put(lx2, wy, src >= 0 && opaque(lx2 + ox, src) ? mix(mix(get(lx2 + ox, src), base, 1 - keep), [0, 0, 0], 0.06) : base)
      }
      if (k > 0) {
        var dashes = Math.round(w / 24) + 1
        for (var di2 = 0; di2 < dashes; di2++) {
          var len = 2 + Math.floor(hash(di2, k * 7 + 101) * 8)
          var speed = (hash(k, 103) - 0.5) * 6
          var x0 = Math.floor((hash(di2, k + 107) * w + t * speed) % w + w) % w
          var light = hash(di2, k + 109) < 0.55
          var fadeA = o.deepBelow ? calmDown : 1
          if (fadeA <= 0) continue
          for (var dj = 0; dj < len; dj++) blend((x0 + dj) % w, wy, light ? P.glint : P.water[wn], (light ? 0.24 : 0.4) * fadeA)
        }
      }
    }

    // Glints on the water, gathered under the sun or moon.
    for (var gk = 1; gk < lakeH; gk++) {
      var gy = horizon + gk
      for (var gx = 0; gx < w; gx++) {
        var near = phase !== 'day' && Math.abs(gx - sunX) <= sunR * (phase === 'night' ? 1.5 : 1.1)
        if (o.deepBelow && gk > lakeH * 0.75) break
        if (hash(gx + Math.floor(t * 3) * 7, gy) < (near ? 0.12 : 0.004)) blend(gx, gy, P.glint, near ? 0.75 : 0.5)
      }
    }

    // Night: neon reflections stretch across the water, like light on a wet street.
    lights.forEach(function (lt, li) {
      var reach = Math.min(lakeH, Math.round(rise * 0.9))
      for (var nk = 1; nk < reach; nk++) {
        if (hash(nk + Math.floor(t * 4) * 13, lt[0] + li) > 0.75 - 0.7 * nk / reach) continue
        var len = 1 + Math.floor(hash(nk, lt[0] * 3) * 3)
        var wob = Math.round(Math.sin(nk * 0.8 + t * 2))
        for (var j = 0; j < len; j++) blend(lt[0] + wob + j - (len >> 1), horizon + nk, lt[1], 0.5 * (1 - nk / reach * 0.7))
      }
    })

    // Night: light rain, and rings where it lands.
    if (phase === 'night' && !o.calm && !noSky) {
      var rings = Math.max(2, Math.round(w / 45))
      for (var ri = 0; ri < rings; ri++) {
        var cyc = t * 0.7 + hash(ri, 41), age = cyc - Math.floor(cyc), id = Math.floor(cyc)
        var rx0 = Math.floor(hash(ri, id + 43) * w), rk = 2 + Math.floor(hash(ri, id + 47) * Math.max(1, lakeH - 6))
        var rr = 1 + age * 4
        for (var rdx = -Math.ceil(rr); rdx <= Math.ceil(rr); rdx++) {
          var qq = 1 - (rdx / rr) * (rdx / rr)
          if (qq < 0) continue
          var rdy = Math.round(Math.sqrt(qq) * rr * 0.35)
          blend(rx0 + rdx, horizon + rk - rdy, P.glint, 0.6 * (1 - age))
          if (rdy) blend(rx0 + rdx, horizon + rk + rdy, P.glint, 0.6 * (1 - age))
        }
      }
      var drops = Math.round(w * h / 420)
      for (var dr = 0; dr < drops; dr++) {
        var v = 55 + hash(dr, 51) * 35
        var dy0 = (hash(dr, 53) * (h + 8) + t * v) % (h + 8) - 4
        var dx0 = hash(dr, 57) * (w + h * 0.25) - dy0 * 0.25
        if (behindText(Math.round(dx0), Math.round(dy0)) && hash(dr, 59) < 0.8) continue
        for (var dd = 0; dd < 3; dd++) blend(Math.round(dx0 + dd * 0.25), Math.round(dy0 - dd), P.rain, 0.42 - dd * 0.1)
      }
    }

    // Dissolve the bottom rows into the page.
    var fade = o.fade || 0
    if (fade && o.bg) {
      for (var by = h - fade; by < h; by++) {
        var bf = (by - (h - fade) + 1) / fade
        for (var bx = 0; bx < w; bx++) if (on(bx, by, bf)) put(bx, by, o.bg)
      }
    }

    if (o.alpha) {
      var sides = o.alpha.sides || 0, bottom = o.alpha.bottom || 0, topRows = o.alpha.top || 0
      for (var ay = 0; ay < h; ay++)
        for (var ax = 0; ax < w; ax++) {
          var fade2 = 0
          if (ax < sides) fade2 = Math.max(fade2, 1 - (ax + 0.5) / sides)
          if (ax >= w - sides) fade2 = Math.max(fade2, 1 - (w - ax - 0.5) / sides)
          if (ay >= h - bottom) fade2 = Math.max(fade2, 1 - (h - ay - 0.5) / bottom)
          if (ay < topRows) fade2 = Math.max(fade2, 1 - (ay + 0.5) / topRows)
          if (fade2 > 0 && on(ax, ay, fade2)) buf[(ay * w + ax) * 4 + 3] = 0
        }
    }

    return buf
  }

  // Below the lake's surface: deeper water for the rest of the page, darker the further down it goes,
  // dark enough everywhere for light text. The first colour is the lake's own, so the seam vanishes.
  var DEEP = {
    light: {
      dawn: ['#8d7cb6', '#6f619c', '#554a82', '#41386a'],
      day: ['#22697a', '#1a5565', '#134350', '#0d323d'],
      dusk: ['#251a43', '#1e1538', '#17102c', '#100b21'],
      night: ['#060a1c', '#050817', '#040612', '#03040d']
    },
    dark: {
      dawn: ['#302949', '#28223e', '#211c34', '#1a162a'],
      day: ['#16394a', '#11303e', '#0d2733', '#0a1f28'],
      dusk: ['#22183f', '#1b1334', '#150f29', '#0f0a1f'],
      night: ['#050918', '#040713', '#03050f', '#02030b']
    }
  }
  var deepCache = {}
  function renderDeep(o) {
    var w = o.w, h = o.h, t = o.t || 0, P = palette(o.phase, o.dark)
    var key = [w, h, o.phase, o.dark].join(':')
    var base = deepCache[key]
    if (!base) {
      var bands = [P.water[P.water.length - 1]].concat((o.dark ? DEEP.dark : DEEP.light)[o.phase].map(rgb))
      var n = bands.length - 1
      base = new Uint8ClampedArray(w * h * 4)
      for (var y = 0; y < h; y++) {
        var s = Math.pow(y / Math.max(1, h - 1), 0.75) * n
        var i = Math.min(n - 1, Math.floor(s)), g = clamp((s - i - 0.3) / 0.4, 0, 1)
        for (var x = 0; x < w; x++) {
          var c = on(x, y, g) ? bands[i + 1] : bands[i], k = (y * w + x) * 4
          base[k] = c[0]; base[k + 1] = c[1]; base[k + 2] = c[2]; base[k + 3] = 255
        }
      }
      // The lakebed under the footer: rounded stones and a few weeds, in silhouette.
      var floorTop = h - Math.min(18, Math.round(h * 0.06))
      for (var bx = 0; bx < w; bx++) {
        var mound = Math.round(Math.abs(Math.sin(bx * 0.09 + 1.7)) * 4 + Math.abs(Math.sin(bx * 0.031)) * 5)
        for (var by = floorTop + 9 - mound; by < h; by++) {
          var kk = (by * w + bx) * 4, cc = mix([base[kk], base[kk + 1], base[kk + 2]], [0, 0, 0], 0.38)
          base[kk] = cc[0]; base[kk + 1] = cc[1]; base[kk + 2] = cc[2]
        }
      }
      deepCache = {}; deepCache[key] = base
    }
    var buf = new Uint8ClampedArray(base)
    function blend(x, y, c, a) {
      if (x < 0 || y < 0 || x >= w || y >= h) return
      var k = (y * w + x) * 4
      buf[k] += (c[0] - buf[k]) * a; buf[k + 1] += (c[1] - buf[k + 1]) * a; buf[k + 2] += (c[2] - buf[k + 2]) * a
    }
    // Light shafts slanting down from the surface on bright days.
    if (o.phase === 'day' || o.phase === 'dawn') {
      var reachDown = Math.round(h * 0.3)
      for (var sy = 0; sy < reachDown; sy++)
        for (var sx = 0; sx < w; sx++) {
          var ray = Math.sin((sx + sy * 0.55) * 0.06 + t * 0.15) + Math.sin((sx + sy * 0.55) * 0.023 - t * 0.07)
          if (ray > 1.2 && on(sx, sy, (ray - 1.2) * 1.2 * (1 - sy / reachDown))) blend(sx, sy, P.glint, 0.14)
        }
    }
    // Weeds swaying on the lakebed.
    for (var wi = 0; wi < w; wi += 1) {
      if (hash(wi, 81) > 0.07) continue
      var tall = 4 + Math.round(hash(wi, 83) * 9)
      for (var wj = 0; wj < tall; wj++) {
        var sway = Math.round(Math.sin(t * 0.9 + wi * 0.7 + wj * 0.35) * wj / tall * 1.6)
        blend(wi + sway, h - 4 - wj, mix(P.tree, [0, 0, 0], 0.2), 0.55)
      }
    }
    // A few bubbles drifting up.
    var bubbles = Math.round(w * h / 2600)
    for (var bi = 0; bi < bubbles; bi++) {
      var speed = 3 + hash(bi, 91) * 6
      var bby = Math.round(h - ((t * speed + hash(bi, 93) * h * 1.3) % (h * 1.3)))
      var bbx = Math.round(hash(bi, 95) * w + Math.sin(t * 1.3 + bi) * 1.2)
      blend(bbx, bby, P.glint, 0.4)
    }
    // Two tiny fish, in silhouette, minding their own business.
    ;[[0.22, 5, 1], [0.48, 3.5, -1], [0.71, 4.5, 1]].forEach(function (f, fi) {
      var fy = Math.round(h * f[0]), span = w + 16
      var fx = Math.round(((t * f[1] + fi * 97) % span + span) % span) - 8
      if (f[2] < 0) fx = w - fx
      var body = [[0, 0], [0, 2], [1, 1], [2, 0], [2, 1], [2, 2], [3, 0], [3, 1], [3, 2], [4, 1]]
      var shade = mix(P.water[P.water.length - 1], [0, 0, 0], 0.45)
      body.forEach(function (q) { blend(fx + q[0] * f[2], fy + q[1], shade, 0.7) })
    })
    return buf
  }

  var api = { render: render, renderDeep: renderDeep, phaseAt: phaseAt, phases: ['dawn', 'day', 'dusk', 'night'] }
  if (typeof module === 'object' && module.exports) module.exports = api
  else root.TarnScene = api
})(this)
