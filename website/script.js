// Appearance toggle: System → Light → Dark, remembered on this device.
;(function () {
  var root = document.documentElement
  var button = document.querySelector('.theme')
  var label = document.querySelector('.theme-label')
  var order = ['system', 'light', 'dark']
  var names = { system: 'System', light: 'Light', dark: 'Dark' }

  function apply(theme) {
    root.dataset.theme = theme
    if (label) label.textContent = names[theme]
    if (button) button.setAttribute('aria-label', 'Appearance: ' + names[theme])
  }

  apply(order.indexOf(root.dataset.theme) >= 0 ? root.dataset.theme : 'system')
  if (button) {
    button.addEventListener('click', function () {
      var next = order[(order.indexOf(root.dataset.theme) + 1) % order.length]
      apply(next)
      try { localStorage.setItem('tarn-theme', next) } catch (e) {}
    })
  }

  // Tarn only runs on Macs. On phones and PCs, say so instead of downloading a file that can't open.
  var ua = navigator.userAgent
  var isMac = /Macintosh|Mac OS X/.test(ua) && !/iPhone|iPad|iPod/.test(ua) && !('ontouchend' in document && navigator.maxTouchPoints > 1)
  if (!isMac) {
    document.querySelectorAll('[data-download]').forEach(function (a) {
      if (a.classList.contains('btn-small')) { a.style.display = 'none'; return }
      a.textContent = 'Tarn is for Mac'
      a.setAttribute('aria-disabled', 'true')
      a.removeAttribute('href')
    })
  }
})()
