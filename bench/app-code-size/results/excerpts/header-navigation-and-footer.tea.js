// Zj (p149): 308 B raw
let Zj = (a, b) => {
  let c = b[0], d = b[1], e = b[2], f = b[3];
  if (c !== a.g0_0 || d !== a.g0_1) {
    a.g0_0 = c;
    a.g0_1 = d;
    let g = $j(c, d) && d.$ !== 0;
    if (g !== a.a0) {
      a.a0 = g;
      a.w0.classList.toggle("active", g);
    }
  }
  let h = e;
  if (h !== a.g1_0) {
    a.g1_0 = h;
    let i = li(e);
    if (i !== a.a1) {
      a.w1.setAttribute("href", Cb(i));
      a.a1 = i;
    }
  }
  let j = f;
  if (j !== a.g2_0) {
    a.g2_0 = j;
    a.w2.data = j;
  }
};
// _j (t149): 49 B raw
let _j = Ea("<li class=nav-item><a class=nav-link> ", 0);
// ak (k149): 162 B raw
let ak = {
  m: a => {
    let c = _j(), d = c.firstChild, f = {
      s: c,
      q: null,
      e: c,
      w0: c,
      w1: d,
      w2: d.firstChild,
      a0: false,
      a1: undefined,
      g0_0: NaN,
      g0_1: NaN,
      g1_0: NaN,
      g2_0: NaN
    };
    Zj(f, a);
    return f;
  },
  p: Zj
};
// bk (p98): 705 B raw
let bk = (a, b) => {
  let c = b[0], d = b[1], e = b[2], f = c;
  if (f !== a.g0_0) {
    a.g0_0 = f;
    if (c !== a.a0_0) {
      a.a0_0 = c;
      Qa(a.c0, ck(c, Pj, Vj, "New Article"));
    } else Ka(a.c0);
    if (c !== a.a1_0) {
      a.a1_0 = c;
      Qa(a.c1, ck(c, Yj, Xj, "Settings"));
    } else Ka(a.c1);
    if (c !== a.a6_0) {
      a.a6_0 = c;
      Qa(a.c6, ck(c, Qj, Uj, "Sign out"));
    } else Ka(a.c6);
  } else {
    Ka(a.c0);
    Ka(a.c1);
    Ka(a.c6);
  }
  if (c !== a.g1_0 || d !== a.g1_1) {
    a.g1_0 = c;
    a.g1_1 = d;
    let g = c.$ === 5 && c.a === d;
    if (g !== a.a2) {
      a.a2 = g;
      a.w1.classList.toggle("active", g);
    }
  }
  let h = d;
  if (h !== a.g2_0) {
    a.g2_0 = h;
    let i = li({
      $: 7,
      a: d
    });
    if (i !== a.a3) {
      a.w2.setAttribute("href", Cb(i));
      a.a3 = i;
    }
    a.x5.data = h;
  }
  let j = e.E;
  if (j !== a.g3_0) {
    a.g3_0 = j;
    let k = e.E;
    if (k !== a.a4_0) {
      a.a4_0 = k;
      Qa(a.c4, Oi(k, "user-pic"));
    } else Ka(a.c4);
  } else Ka(a.c4);
  a.l = a.c0.l || a.c1.l || a.c4.l || a.c6.l;
};
// dk (t98): 69 B raw
let dk = Ea("<!><li class=nav-item><a class=nav-link><!><!></a></li><!>", 4);
// ek (k98): 396 B raw
let ek = {
  m: (a, b) => {
    let c = dk(), d = c.firstChild, e = d.nextSibling, f = e.firstChild, g = f.firstChild, h = g.nextSibling, i = e.nextSibling, j = Fa(null, d, b), k = Fa(null, e, b), l = Fa(f, g, b), m = Fa(null, i, b), n = db(f, h), o = {
      s: null,
      q: j,
      e: i,
      w1: e,
      w2: f,
      c0: j,
      c1: k,
      c4: l,
      x5: n,
      c6: m,
      a0_0: undefined,
      a1_0: undefined,
      a2: false,
      a3: undefined,
      a4_0: undefined,
      a6_0: undefined,
      g0_0: NaN,
      g1_0: NaN,
      g1_1: NaN,
      g2_0: NaN,
      g3_0: NaN
    };
    bk(o, a);
    return o;
  },
  p: bk,
  l: true
};
// fk (p115): 230 B raw
let fk = (a, b) => {
  let c = b[0], d = c;
  if (d !== a.g0_0) {
    a.g0_0 = d;
    if (c !== a.a0_0) {
      a.a0_0 = c;
      Qa(a.c0, ck(c, Oj, Tj, "Sign in"));
    } else Ka(a.c0);
    if (c !== a.a1_0) {
      a.a1_0 = c;
      Qa(a.c1, ck(c, Rj, Wj, "Sign up"));
    } else Ka(a.c1);
  } else {
    Ka(a.c0);
    Ka(a.c1);
  }
  a.l = a.c0.l || a.c1.l;
};
// gk (t115): 17 B raw
let gk = Ea("<!><!>", 4);
// hk (k115): 184 B raw
let hk = {
  m: (a, b) => {
    let c = gk(), d = c.firstChild, e = d.nextSibling, f = Fa(null, d, b), g = Fa(null, e, b), h = {
      s: null,
      q: f,
      e: e,
      c0: f,
      c1: g,
      a0_0: undefined,
      a1_0: undefined,
      g0_0: NaN
    };
    fk(h, a);
    return h;
  },
  p: fk,
  l: true
};
// ik (p118): 406 B raw
let ik = (a, b) => {
  let c = b[0], d = b[1];
  if (a.g0 === undefined) {
    a.g0 = true;
    let e = li(Sj);
    if (e !== a.a0) {
      a.w2.setAttribute("href", Cb(e));
      a.a0 = e;
    }
  }
  let f = c;
  if (f !== a.g1_0) {
    a.g1_0 = f;
    if (c !== a.a1_0) {
      a.a1_0 = c;
      Qa(a.c1, ck(c, Nj, Sj, "Home"));
    } else Ka(a.c1);
  } else Ka(a.c1);
  if (c !== a.g2_0 || d !== a.g2_1) {
    a.g2_0 = c;
    a.g2_1 = d;
    let g;
    if (d.$ === 0) {
      let h = d.a;
      g = {
        t: ek,
        v: [ c, h.aa.username, h ]
      };
    } else g = {
      t: hk,
      v: [ c ]
    };
    Qa(a.c2, g);
  } else Ka(a.c2);
  a.l = a.c1.l || a.c2.l;
};
// jk (t118): 149 B raw
let jk = Ea('<nav class="navbar navbar-light"><div class=container><a class=navbar-brand>conduit</a><ul class="nav navbar-nav pull-xs-right"><!><!>', 0);
// kk (k118): 254 B raw
let kk = {
  m: (a, b) => {
    let c = jk(), e = c.firstChild.firstChild, f = e.nextSibling, g = f.firstChild, h = g.nextSibling, i = Fa(f, g, b), j = Fa(f, h, b), k = {
      s: c,
      q: null,
      e: c,
      w2: e,
      c1: i,
      c2: j,
      a0: undefined,
      a1_0: undefined,
      g0: undefined,
      g1_0: NaN,
      g2_0: NaN,
      g2_1: NaN
    };
    ik(k, a);
    return k;
  },
  p: ik,
  l: true
};
// lk (p156): 105 B raw
let lk = a => {
  if (a.g0 === undefined) {
    a.g0 = true;
    let c = li(Sj);
    if (c !== a.a0) {
      a.w2.setAttribute("href", Cb(c));
      a.a0 = c;
    }
  }
};
// mk (t156): 179 B raw
let mk = Ea("<footer><div class=container><a class=logo-font>conduit</a><span class=attribution>An interactive learning project from Thinkster. Code &amp; design licensed under MIT.", 0);
// nk (k156): 116 B raw
let nk = {
  m: a => {
    let c = mk(), f = {
      s: c,
      q: null,
      e: c,
      w2: c.firstChild.firstChild,
      a0: undefined,
      g0: undefined
    };
    lk(f, a);
    return f;
  },
  p: lk
};
// ok (b156): 16 B raw
let ok = {
  t: nk,
  v: null
};
// pk (p29): 335 B raw
let pk = (a, b) => {
  let c = b[0], d = b[1], e = b[2];
  if (c !== a.g0_0 || d !== a.g0_1) {
    a.g0_0 = c;
    a.g0_1 = d;
    if (c !== a.a0_0 || d !== a.a0_1) {
      a.a0_0 = c;
      a.a0_1 = d;
      Qa(a.c0, {
        t: kk,
        v: [ d, c ]
      });
    } else Ka(a.c0);
  } else Ka(a.c0);
  let f = e.content;
  if (f !== a.g1_0) {
    a.g1_0 = f;
    Qa(a.c1, e.content);
  } else Ka(a.c1);
  if (a.g2 === undefined) {
    a.g2 = true;
    Qa(a.c2, qk);
  } else Ka(a.c2);
  a.l = a.c0.l || a.c1.l || a.c2.l;
};
// rk (t29): 35 B raw
let rk = Ea("<div class=app><!><!><!>", 0);
// sk (k29): 242 B raw
let sk = {
  m: (a, b) => {
    let c = rk(), d = c.firstChild, e = d.nextSibling, f = e.nextSibling, g = Fa(c, d, b), h = Fa(c, e, b), i = Fa(c, f, b), j = {
      s: c,
      q: null,
      e: c,
      c0: g,
      c1: h,
      c2: i,
      a0_0: undefined,
      a0_1: undefined,
      g0_0: NaN,
      g0_1: NaN,
      g1_0: NaN,
      g2: undefined
    };
    pk(j, a);
    return j;
  },
  p: pk,
  l: true
};
// ck (navbarLink): 34 B raw
let ck = (a, b, c, d) => ({
  t: ak,
  v: [ a, b, c, d ]
});
// qk (footer): 5 B raw
let qk = ok;
// Gk (frame): 66 B raw
let Gk = (a, b, c) => ({
  body: {
    t: sk,
    v: [ a, b, c ]
  },
  title: c.title + " — Conduit"
});