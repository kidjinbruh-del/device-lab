// device-lab: проверка вёрстки страницы (для приложений на WebView).
// Возвращает JSON: элементы за краем экрана и обрезанный текст.
//
// Элементы внутри горизонтально прокручиваемых блоков (таблица журнала)
// пропускаются: там выход за край — законный, блок сам прокручивается.

(function () {
  var de = document.documentElement;
  var iw = window.innerWidth;
  var overflow = [];
  var clipped = [];

  function scrollableParent(e) {
    var p = e.parentElement;
    while (p && p !== document.body) {
      var s = getComputedStyle(p);
      if (s.overflowX === 'auto' || s.overflowX === 'scroll') return p;
      p = p.parentElement;
    }
    return null;
  }

  function name(e) {
    var s = e.tagName.toLowerCase();
    if (e.id) s += '#' + e.id;
    else if (e.className && typeof e.className === 'string') {
      s += '.' + e.className.trim().split(/\s+/)[0];
    }
    return s;
  }

  if (de.scrollWidth > iw + 2) {
    overflow.push('страница шире экрана: ' + de.scrollWidth + ' > ' + iw);
  }

  var all = document.querySelectorAll('body *');
  for (var i = 0; i < all.length; i++) {
    var e = all[i];
    var r = e.getBoundingClientRect();
    if (r.width <= 0 || r.height <= 0) continue;
    if (scrollableParent(e)) continue;
    if (r.right > iw + 2 || r.left < -2) {
      overflow.push(name(e) + ' выходит за край: ' + Math.round(r.left) + '..' + Math.round(r.right));
    }
    if (e.children.length === 0 && e.scrollWidth > e.clientWidth + 3) {
      var s2 = getComputedStyle(e);
      if (s2.overflowX === 'hidden' || s2.overflowX === 'clip') {
        clipped.push(
          name(e) + ' текст обрезан: ' + e.scrollWidth + ' > ' + e.clientWidth +
          ' — "' + (e.textContent || '').trim().slice(0, 30) + '"'
        );
      }
    }
  }

  function unique(list) {
    var seen = {};
    var out = [];
    list.forEach(function (x) {
      if (!seen[x]) { seen[x] = 1; out.push(x); }
    });
    return out;
  }

  return JSON.stringify({
    scrollW: de.scrollWidth,
    innerW: iw,
    overflow: unique(overflow).slice(0, 10),
    clipped: unique(clipped).slice(0, 10)
  });
})()