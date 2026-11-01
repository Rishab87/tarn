;(function () {
  var root = document.documentElement

  // Appearance: system → light → dark, remembered on this device.
  var order = ['system', 'light', 'dark']
  var button = document.querySelector('.theme')
  var redraw = function () {}
  function apply(theme) {
    root.dataset.theme = theme
    if (button) button.setAttribute('aria-label', 'appearance: ' + theme)
    if (button) button.title = 'appearance: ' + theme
    redraw()
  }
  apply(order.indexOf(root.dataset.theme) >= 0 ? root.dataset.theme : 'system')
  if (button) {
    button.addEventListener('click', function () {
      var next = order[(order.indexOf(root.dataset.theme) + 1) % order.length]
      apply(next)
      try { localStorage.setItem('tarn-theme', next) } catch (e) {}
    })
  }

  // Menu-bar clock, like the one on your Mac.
  var clock = document.querySelector('.clock')
  function tick() {
    if (!clock) return
    var d = new Date()
    var h = d.getHours(), m = d.getMinutes()
    clock.textContent = ((h % 12) || 12) + ':' + (m < 10 ? '0' : '') + m + (h < 12 ? ' am' : ' pm')
  }
  tick()
  setInterval(tick, 15000)

  // Tarn only runs on Macs. On phones and PCs, say so instead of downloading a file that can't open.
  var ua = navigator.userAgent
  var isMac = /Macintosh|Mac OS X/.test(ua) && !/iPhone|iPad|iPod/.test(ua) && !('ontouchend' in document && navigator.maxTouchPoints > 1)
  if (!isMac) {
    document.querySelectorAll('[data-download]').forEach(function (a) {
      if (!a.classList.contains('btn')) { a.style.display = 'none'; return }
      a.textContent = 'tarn is for mac'
      a.setAttribute('aria-disabled', 'true')
      a.removeAttribute('href')
    })
  }

  // The wallpaper: a pixel tarn lit by the visitor's own clock (scene.js), drawn on small canvases
  // and scaled up by whole pixels. The hero holds the sky, the peaks and the lake's surface; the
  // deep water below runs to the bottom of the page. ?scene=dawn|day|dusk|night previews the others.
  var hero = document.querySelector('.hero')
  var canvas = document.querySelector('.scene')
  var deep = document.querySelector('.deep')
  var main = document.querySelector('.win.main')
  var foot = document.querySelector('.foot')
  var Scene = window.TarnScene
  if (hero && canvas && deep && main && foot && Scene && canvas.getContext) {
    root.setAttribute('data-lake', '')
    var ctx = canvas.getContext('2d'), deepCtx = deep.getContext('2d')
    var pinned = new URLSearchParams(location.search).get('scene')
    var darkScheme = window.matchMedia('(prefers-color-scheme: dark)')
    var calm = window.matchMedia('(prefers-reduced-motion: reduce)').matches
    var started = performance.now(), last = 0, lastDeep = 0, onScreen = true, deepOnScreen = false
    var layout = null, image = null, deepImage = null
    var isDark = function () { var t = root.dataset.theme; return t === 'dark' || (t !== 'light' && darkScheme.matches) }
    var phase = function () { return Scene.phases.indexOf(pinned) >= 0 ? pinned : Scene.phaseAt(new Date()) }
    var clock = function () { return calm ? 0 : (performance.now() - started) / 1000 }
    var measure = function () {
      var scale = window.innerWidth >= 900 ? 4 : 3
      var h = hero.getBoundingClientRect(), m = main.getBoundingClientRect()
      var req = hero.querySelector('.req').getBoundingClientRect()
      var h1 = hero.querySelector('h1').getBoundingClientRect()
      var top = h.top - 36                                   // under the menu bar
      var w = Math.ceil(document.documentElement.clientWidth / scale)
      var ht = Math.ceil((m.bottom + 70 - top) / scale)      // down past the app window
      canvas.width = w; canvas.height = ht
      canvas.style.width = w * scale + 'px'; canvas.style.height = ht * scale + 'px'
      canvas.style.left = -h.left + 'px'
      var horizon = Math.round((m.top - (scale === 4 ? 90 : 60) - top) / scale)
      layout = {
        w: w, h: ht, scale: scale, horizon: horizon,
        peakTop: Math.min(Math.round((req.bottom + 34 - top) / scale), horizon - 12),
        clear: { x0: Math.floor((h1.left - 16) / scale), x1: Math.ceil((h1.right + 16) / scale),
                 y0: Math.floor((h1.top - 16 - top) / scale), y1: Math.ceil((req.bottom + 12 - top) / scale) }
      }
      image = ctx.createImageData(w, ht)
      // Deep water from the bottom of the hero's lake to the bottom of the page.
      var surface = top + window.scrollY + ht * scale
      var dh = Math.max(1, Math.ceil((foot.getBoundingClientRect().bottom + window.scrollY - surface) / scale))
      deep.width = w; deep.height = dh
      deep.style.top = surface + 'px'; deep.style.width = w * scale + 'px'; deep.style.height = dh * scale + 'px'
      layout.deepH = dh
      deepImage = deepCtx.createImageData(w, dh)
    }
    var drawLake = function () {
      if (!layout) measure()
      var p = phase(), d = isDark()
      hero.dataset.phase = p
      if (d) hero.setAttribute('data-dark', ''); else hero.removeAttribute('data-dark')
      image.data.set(Scene.render({
        w: layout.w, h: layout.h, phase: p, dark: d, t: clock(), horizon: layout.horizon,
        peakTop: layout.peakTop, clear: layout.clear, deepBelow: true
      }))
      ctx.putImageData(image, 0, 0)
    }
    var drawDeep = function () {
      if (!layout) measure()
      deepImage.data.set(Scene.renderDeep({ w: layout.w, h: layout.deepH, phase: phase(), dark: isDark(), t: clock() }))
      deepCtx.putImageData(deepImage, 0, 0)
    }
    redraw = function () { drawLake(); drawDeep() }
    redraw()
    // About 12 frames a second up top, 8 in the deep: it moves like an old handheld game.
    if (!calm) {
      var tick = function (now) {
        if (!document.hidden) {
          if (onScreen && now - last > 80) { last = now; drawLake() }
          if (deepOnScreen && now - lastDeep > 125) { lastDeep = now; drawDeep() }
        }
        window.requestAnimationFrame(tick)
      }
      window.requestAnimationFrame(tick)
    }
    var resizing = 0
    var relayout = function () { clearTimeout(resizing); resizing = setTimeout(function () { measure(); redraw() }, 120) }
    window.addEventListener('resize', relayout)
    window.addEventListener('load', relayout)                 // late images can change the page's height
    darkScheme.addEventListener('change', function () { redraw() })
    if ('IntersectionObserver' in window) {
      new IntersectionObserver(function (e) { onScreen = e[0].isIntersecting }).observe(canvas)
      new IntersectionObserver(function (e) { deepOnScreen = e[0].isIntersecting }).observe(deep)
    } else {
      deepOnScreen = true
    }
  }

  // Clips play only while they're on screen, and not at all when the reader prefers less motion.
  var still = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches
  var videos = document.querySelectorAll('.clip-video')
  if (still) {
    videos.forEach(function (v) { v.removeAttribute('autoplay'); v.pause() })
    return
  }
  if (!('IntersectionObserver' in window)) {
    videos.forEach(function (v) { v.play().catch(function () {}) })
    return
  }
  var seen = new IntersectionObserver(function (entries) {
    entries.forEach(function (e) {
      if (e.isIntersecting) e.target.play().catch(function () {})
      else e.target.pause()
    })
  }, { threshold: 0.35 })
  videos.forEach(function (v) { seen.observe(v) })
})()
