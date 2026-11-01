;(function () {
  var root = document.documentElement

  // Appearance: system → light → dark, remembered on this device.
  var order = ['system', 'light', 'dark']
  var button = document.querySelector('.theme')
  function apply(theme) {
    root.dataset.theme = theme
    if (button) button.setAttribute('aria-label', 'appearance: ' + theme)
    if (button) button.title = 'appearance: ' + theme
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
