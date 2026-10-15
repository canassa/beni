// Oo (t782): 16 B raw
let Oo = Ea("<li> ", 0);
// Po (p804): 1020 B raw
let Po = (a, b) => {
  let c = b[0], d = b[1], e = b[2], f = b[3], g = b[4], h = c;
  if (h !== a.g0_0) {
    a.g0_0 = h;
    let i = {
      m: () => {
        let d = Oo();
        return {
          s: d,
          q: null,
          e: d,
          w1: d.firstChild,
          a0: undefined,
          x: undefined
        };
      },
      p: (a, b) => {
        let d;
        if (b.$ === 0) d = b.b; else d = b.a;
        if (d !== a.a0) {
          a.a0 = d;
          a.w1.data = d;
        }
      },
      w: true
    };
    ob(a.c0, c, i, null);
  } else Ka(a.c0);
  let j = d;
  if (j !== a.g1_0) {
    a.g1_0 = j;
    let k = () => ({
      $: 0,
      a: d,
      b: null
    });
    if (k !== a.a1) {
      a.a1 = k;
      a.w1.$$submit = k;
    }
  }
  let l = e;
  if (l !== a.g2_0) {
    a.g2_0 = l;
    Ab(a.w2, "disabled", l ? "" : null);
  }
  let m = f.title;
  if (m !== a.g3_0) {
    a.g3_0 = m;
    zb(a.w4, "value", f.title);
  }
  if (a.g4 === undefined) {
    a.g4 = true;
    let o = a => ({
      $: 4,
      a: a,
      b: null
    }), p = a => ({
      $: 2,
      a: a,
      b: null
    }), q = a => ({
      $: 1,
      a: a,
      b: null
    }), r = a => ({
      $: 3,
      a: a,
      b: null
    });
    if (o !== a.a4) {
      a.a4 = o;
      a.w4.$$input = o;
    }
    if (p !== a.a6) {
      a.a6 = p;
      a.w6.$$input = p;
    }
    if (q !== a.a8) {
      a.a8 = q;
      a.w8.$$input = q;
    }
    if (r !== a.a10) {
      a.a10 = r;
      a.w10.$$input = r;
    }
  }
  let s = f.D;
  if (s !== a.g5_0) {
    a.g5_0 = s;
    zb(a.w6, "value", f.D);
  }
  let u = f.body;
  if (u !== a.g6_0) {
    a.g6_0 = u;
    zb(a.w8, "value", f.body);
  }
  let w = f.B;
  if (w !== a.g7_0) {
    a.g7_0 = w;
    zb(a.w10, "value", f.B);
  }
  let y = g;
  if (y !== a.g8_0) {
    a.g8_0 = y;
    a.w12.data = y;
  }
  a.l = a.c0.w || a.c0.l;
};
// Qo (t804): 613 B raw
let Qo = Ea('<ul class=error-messages></ul><form id=editor-form><fieldset><fieldset class=form-group><input id=title class="form-control form-control-lg"placeholder="Article Title"></fieldset><fieldset class=form-group><input id=description class=form-control placeholder="What\'s this article about?"></fieldset><fieldset class=form-group><textarea id=body class=form-control rows=8 placeholder="Write your article (in markdown)"></textarea></fieldset><fieldset class=form-group><input id=tags class=form-control placeholder="Enter tags"></fieldset><button class="btn btn-lg pull-xs-right btn-primary"> ', 4);
// Ro (k804): 672 B raw
let Ro = {
  m: (a, b) => {
    let c = Qo(), d = c.firstChild, e = d.nextSibling, f = e.firstChild, g = f.firstChild, h = g.firstChild, i = g.nextSibling, j = i.firstChild, k = i.nextSibling, l = k.firstChild, m = k.nextSibling, n = m.firstChild, p = m.nextSibling.firstChild, q = Fa(d, null, b);
    e.$$submitX = Fb;
    e.$$submitF = 1;
    if (b !== null) e.$$cx = b;
    h.$$inputX = Lk;
    if (b !== null) h.$$cx = b;
    j.$$inputX = Lk;
    if (b !== null) j.$$cx = b;
    l.$$inputX = Lk;
    if (b !== null) l.$$cx = b;
    n.$$inputX = Lk;
    if (b !== null) n.$$cx = b;
    let r = {
      s: d,
      q: null,
      e: e,
      w1: e,
      w2: f,
      w4: h,
      w6: j,
      w8: l,
      w10: n,
      w12: p,
      c0: q,
      a1: undefined,
      a4: undefined,
      a6: undefined,
      a8: undefined,
      a10: undefined,
      g0_0: NaN,
      g1_0: NaN,
      g2_0: NaN,
      g3_0: NaN,
      g4: undefined,
      g5_0: NaN,
      g6_0: NaN,
      g7_0: NaN,
      g8_0: NaN
    };
    Po(r, a);
    return r;
  },
  p: Po,
  l: true
};
// So (t688): 14 B raw
let So = Ea("<!>", 0);
// To (k688): 55 B raw
let To = {
  m: () => {
    let c = So();
    return {
      s: c,
      q: null,
      e: c
    };
  },
  p: () => {}
};
// Uo (b688): 16 B raw
let Uo = {
  t: To,
  v: null
};
// Vo (t698): 37 B raw
let Vo = Ea("<p>Article failed to load.", 0);
// Wo (k698): 55 B raw
let Wo = {
  m: () => {
    let c = Vo();
    return {
      s: c,
      q: null,
      e: c
    };
  },
  p: () => {}
};
// Xo (b698): 16 B raw
let Xo = {
  t: Wo,
  v: null
};
// Yo (p749): 440 B raw
let Yo = (a, b) => {
  let c = b[0], d = b[1];
  if (c.status !== a.g0_0 || d !== a.g0_1) {
    a.g0_0 = c.status;
    a.g0_1 = d;
    let e = c.status, f;
    g: {
      switch (e.$) {
       case 0:
        {
          f = Uo;
          break g;
        }

       case 1:
        {
          f = Ik;
          break g;
        }

       case 2:
        {
          f = Xo;
          break g;
        }

       case 3:
        {
          f = Zo(d, [], e.b, true, "Update Article");
          break g;
        }

       case 4:
        {
          f = Zo(d, e.b, e.c, false, "Update Article");
          break g;
        }

       case 5:
        {
          f = Zo(d, e.a, e.b, false, "Publish Article");
          break g;
        }

       default:
        {
          f = Zo(d, [], e.a, true, "Publish Article");
          break g;
        }
      }
    }
    Qa(a.c0, f);
  } else Ka(a.c0);
  a.l = a.c0.l;
};
// $o (t749): 126 B raw
let $o = Ea('<div class=editor-page><div class="container page"><div class=row><div class="col-md-10 offset-md-1 col-xs-12">', 0);
// _o (k749): 145 B raw
let _o = {
  m: (a, b) => {
    let c = $o(), g = Fa(c.firstChild.firstChild.firstChild, null, b), h = {
      s: c,
      q: null,
      e: c,
      c0: g,
      g0_0: NaN,
      g0_1: NaN
    };
    Yo(h, a);
    return h;
  },
  p: Yo,
  l: true
};
// ap (t671): 43 B raw
let ap = Ea("<p>Sign in to edit this article.", 0);
// bp (k671): 55 B raw
let bp = {
  m: () => {
    let c = ap();
    return {
      s: c,
      q: null,
      e: c
    };
  },
  p: () => {}
};
// cp (b671): 16 B raw
let cp = {
  t: bp,
  v: null
};
// Zo (viewForm): 38 B raw
let Zo = (a, b, c, d, e) => ({
  t: Ro,
  v: [ b, a, d, c, e ]
});
// kp (view): 217 B raw
let kp = a => {
  let b;
  c: {
    switch (a.status.$) {
     case 5:
      {
        b = "New Article";
        break c;
      }

     case 6:
      {
        b = "New Article";
        break c;
      }

     default:
      {
        b = "Edit Article";
        break c;
      }
    }
  }
  let d = Qb(a.g), e;
  if (d.$ === 0) e = {
    t: _o,
    v: [ a, d.a ]
  }; else e = cp;
  return {
    content: e,
    title: b
  };
};