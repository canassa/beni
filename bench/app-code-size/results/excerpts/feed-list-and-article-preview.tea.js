// oi (p250): 183 B raw
let oi = (a, b) => {
  let c = b[0], d = b[1], e = c;
  if (e !== a.g0_0) {
    a.g0_0 = e;
    a.w0.setAttribute("class", e);
  }
  let f = d;
  if (f !== a.g1_0) {
    a.g1_0 = f;
    let g = pi(d);
    if (g !== a.a1) {
      a.w0.setAttribute("src", Cb(g));
      a.a1 = g;
    }
  }
};
// qi (t250): 16 B raw
let qi = Ea("<img>", 0);
// ri (k250): 99 B raw
let ri = {
  m: a => {
    let c = qi(), d = {
      s: c,
      q: null,
      e: c,
      w0: c,
      a1: undefined,
      g0_0: NaN,
      g1_0: NaN
    };
    oi(d, a);
    return d;
  },
  p: oi
};
// si (p267): 210 B raw
let si = (a, b) => {
  let c = b[0];
  if (c !== a.l0_0) {
    a.l0_0 = c;
    let d = ti(c);
    a.d0 = d;
  }
  let e = a.d0, f = c;
  if (f !== a.g0_0) {
    a.g0_0 = f;
    let g = li({
      $: 7,
      a: e
    });
    if (g !== a.a0) {
      a.w0.setAttribute("href", Cb(g));
      a.a0 = g;
    }
    if (e !== a.a1) {
      a.a1 = e;
      a.w1.data = e;
    }
  }
};
// ui (t267): 28 B raw
let ui = Ea("<a class=author> ", 0);
// vi (k267): 141 B raw
let vi = {
  m: a => {
    let c = ui(), e = {
      s: c,
      q: null,
      e: c,
      w0: c,
      w1: c.firstChild,
      a0: undefined,
      a1: undefined,
      l0_0: NaN,
      d0: undefined,
      g0_0: NaN
    };
    si(e, a);
    return e;
  },
  p: si
};
// Ni (defaultAvatar): 62 B raw
let Ni = "https://static.productionready.io/images/smiley-cyrus.jpg";
// pi (avatarSrc): 32 B raw
let pi = a => a.$ === 0 ? a.a === "" ? Ni : a.a : Ni;
// Oi (avatar): 26 B raw
let Oi = (a, b) => ({
  t: ri,
  v: [ b, a ]
});
// Pi (link): 20 B raw
let Pi = a => ({
  t: vi,
  v: [ a ]
});
// Si (p507): 63 B raw
let Si = (a, b) => {
  let c = b[0], d = c;
  if (d !== a.g0_0) {
    a.g0_0 = d;
    a.w1.data = d;
  }
};
// Ti (t507): 29 B raw
let Ti = Ea("<span class=date> ", 0);
// Ui (k507): 88 B raw
let Ui = {
  m: a => {
    let c = Ti(), e = {
      s: c,
      q: null,
      e: c,
      w1: c.firstChild,
      g0_0: NaN
    };
    Si(e, a);
    return e;
  },
  p: Si
};
// Zi (t536): 59 B raw
let Zi = Ea('<li class="tag-default tag-pill tag-outline"> ', 0);
// $i (p538): 243 B raw
let $i = (a, b) => {
  let c = b[0], d = c;
  if (d !== a.g0_0) {
    a.g0_0 = d;
    let e = {
      m: () => {
        let d = Zi();
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
        if (b !== a.a0) {
          a.a0 = b;
          a.w1.data = b;
        }
      },
      w: true
    };
    ob(a.c0, c, e, null);
  } else Ka(a.c0);
  a.l = a.c0.w || a.c0.l;
};
// _i (t538): 30 B raw
let _i = Ea("<ul class=tag-list>", 0);
// aj (k538): 103 B raw
let aj = {
  m: (a, b) => {
    let c = _i(), d = Fa(c, null, b), e = {
      s: c,
      q: null,
      e: c,
      c0: d,
      g0_0: NaN
    };
    $i(e, a);
    return e;
  },
  p: $i,
  l: true
};
// bj (p565): 285 B raw
let bj = (a, b) => {
  let c = b[0], d = b[1], e = b[2], f = c;
  if (f !== a.g0_0) {
    a.g0_0 = f;
    let g = `btn btn-primary btn-sm ${c}`;
    if (g !== a.a0) {
      a.w0.setAttribute("class", g);
      a.a0 = g;
    }
  }
  let h = d;
  if (h !== a.g1_0) {
    a.g1_0 = h;
    a.w0.$$click = h;
  }
  let i = e.S;
  if (i !== a.g2_0) {
    a.g2_0 = i;
    let j = ` ${Kd(e.S)}`;
    if (j !== a.a2) {
      a.a2 = j;
      a.x2.data = j;
    }
  }
};
// cj (t565): 38 B raw
let cj = Ea("<button><i class=ion-heart>", 0);
// dj (k565): 168 B raw
let dj = {
  m: (a, b) => {
    let c = cj();
    if (b !== null) c.$$cx = b;
    let d = db(c, null), e = {
      s: c,
      q: null,
      e: c,
      w0: c,
      x2: d,
      a0: undefined,
      a2: undefined,
      g0_0: NaN,
      g1_0: NaN,
      g2_0: NaN
    };
    bj(e, a);
    return e;
  },
  p: bj
};
// ej (p579): 293 B raw
let ej = (a, b) => {
  let c = b[0], d = b[1], e = b[2], f = c;
  if (f !== a.g0_0) {
    a.g0_0 = f;
    let g = `btn btn-outline-primary btn-sm ${c}`;
    if (g !== a.a0) {
      a.w0.setAttribute("class", g);
      a.a0 = g;
    }
  }
  let h = d;
  if (h !== a.g1_0) {
    a.g1_0 = h;
    a.w0.$$click = h;
  }
  let i = e.S;
  if (i !== a.g2_0) {
    a.g2_0 = i;
    let j = ` ${Kd(e.S)}`;
    if (j !== a.a2) {
      a.a2 = j;
      a.x2.data = j;
    }
  }
};
// fj (t579): 38 B raw
let fj = Ea("<button><i class=ion-heart>", 0);
// gj (k579): 168 B raw
let gj = {
  m: (a, b) => {
    let c = fj();
    if (b !== null) c.$$cx = b;
    let d = db(c, null), e = {
      s: c,
      q: null,
      e: c,
      w0: c,
      x2: d,
      a0: undefined,
      a2: undefined,
      g0_0: NaN,
      g1_0: NaN,
      g2_0: NaN
    };
    ej(e, a);
    return e;
  },
  p: ej
};
// hj (p599): 202 B raw
let hj = (a, b) => {
  let c = b[0], d = b[1], e = c.A;
  if (e !== a.g0_0) {
    a.g0_0 = e;
    let f = li({
      $: 6,
      a: c.A
    });
    if (f !== a.a0) {
      a.w0.setAttribute("href", Cb(f));
      a.a0 = f;
    }
  }
  let g = d;
  if (g !== a.g1_0) {
    a.g1_0 = g;
    Qa(a.c1, d);
  } else Ka(a.c1);
  a.l = a.c1.l;
};
// ij (t599): 33 B raw
let ij = Ea("<a class=preview-link>", 0);
// jj (k599): 130 B raw
let jj = {
  m: (a, b) => {
    let c = ij(), d = Fa(c, null, b), e = {
      s: c,
      q: null,
      e: c,
      w0: c,
      c1: d,
      a0: undefined,
      g0_0: NaN,
      g1_0: NaN
    };
    hj(e, a);
    return e;
  },
  p: hj,
  l: true
};
// Ij (timestamp): 20 B raw
let Ij = a => ({
  t: Ui,
  v: [ a ]
});
// Kj (tagList): 20 B raw
let Kj = a => ({
  t: aj,
  v: [ a ]
});
// Lj (favoriteButton): 52 B raw
let Lj = (a, b, c, d) => a.da ? {
  t: dj,
  v: [ d, c, a ]
} : {
  t: gj,
  v: [ d, b, a ]
};
// Mj (link): 26 B raw
let Mj = (a, b) => ({
  t: jj,
  v: [ a, b ]
});
// Ok (p224): 236 B raw
let Ok = (a, b) => {
  let c = b[0], d = c.title;
  if (d !== a.g0_0) {
    a.g0_0 = d;
    a.w1.data = d;
  }
  let e = c.D;
  if (e !== a.g1_0) {
    a.g1_0 = e;
    a.w3.data = e;
  }
  let f = c.B;
  if (f !== a.g2_0) {
    a.g2_0 = f;
    let g = c.B;
    if (g !== a.a2_0) {
      a.a2_0 = g;
      Qa(a.c2, Kj(g));
    } else Ka(a.c2);
  } else Ka(a.c2);
  a.l = a.c2.l;
};
// Pk (t224): 57 B raw
let Pk = Ea("<h1> </h1><p> </p><span>Read more...</span><!>", 4);
// Qk (k224): 235 B raw
let Qk = {
  m: (a, b) => {
    let c = Pk(), d = c.firstChild, e = d.firstChild, f = d.nextSibling, g = f.firstChild, h = f.nextSibling.nextSibling, i = Fa(null, h, b), j = {
      s: d,
      q: null,
      e: h,
      w1: e,
      w3: g,
      c2: i,
      a2_0: undefined,
      g0_0: NaN,
      g1_0: NaN,
      g2_0: NaN
    };
    Ok(j, a);
    return j;
  },
  p: Ok,
  l: true
};
// Rk (t265): 14 B raw
let Rk = Ea("<!>", 0);
// Sk (k265): 55 B raw
let Sk = {
  m: () => {
    let c = Rk();
    return {
      s: c,
      q: null,
      e: c
    };
  },
  p: () => {}
};
// Tk (b265): 16 B raw
let Tk = {
  t: Sk,
  v: null
};
// Uk (p272): 982 B raw
let Uk = (a, b) => {
  let c = b[0], d = b[1];
  if (c.j !== a.l0_0) {
    a.l0_0 = c.j;
    let e = Ji(c.j);
    a.d0 = e;
  }
  let f = a.d0;
  if (c.title !== a.l1_0 || c.D !== a.l1_1 || c.B !== a.l1_2) {
    a.l1_0 = c.title;
    a.l1_1 = c.D;
    a.l1_2 = c.B;
    let g = {
      t: Qk,
      v: [ c ]
    };
    a.d1 = g;
  }
  let h = a.d1, i = c.j;
  if (i !== a.g0_0) {
    a.g0_0 = i;
    let j = li({
      $: 7,
      a: f.username
    }), k = f.E, l = c.j;
    if (j !== a.a0) {
      a.w2.setAttribute("href", Cb(j));
      a.a0 = j;
    }
    if (k !== a.a1_0) {
      a.a1_0 = k;
      Qa(a.c1, Oi(k, ""));
    } else Ka(a.c1);
    if (l !== a.a2_0) {
      a.a2_0 = l;
      Qa(a.c2, Pi(l));
    } else Ka(a.c2);
  } else {
    Ka(a.c1);
    Ka(a.c2);
  }
  let m = c.N;
  if (m !== a.g1_0) {
    a.g1_0 = m;
    let n = c.N;
    if (n !== a.a3_0) {
      a.a3_0 = n;
      Qa(a.c3, Ij(n));
    } else Ka(a.c3);
  } else Ka(a.c3);
  if (d !== a.g2_0 || c !== a.g2_1) {
    a.g2_0 = d;
    a.g2_1 = c;
    let o;
    if (d.$ === 0) {
      let p = d.a;
      o = Lj(c, {
        $: 1,
        a: p,
        b: c.A
      }, {
        $: 2,
        a: p,
        b: c.A
      }, "pull-xs-right");
    } else o = Tk;
    Qa(a.c4, o);
  } else Ka(a.c4);
  if (c.title !== a.g3_0 || c.D !== a.g3_1 || c.B !== a.g3_2 || c !== a.g3_3) {
    a.g3_0 = c.title;
    a.g3_1 = c.D;
    a.g3_2 = c.B;
    a.g3_3 = c;
    if (c !== a.a5_0 || h !== a.a5_1) {
      a.a5_0 = c;
      a.a5_1 = h;
      Qa(a.c5, Mj(c, h));
    } else Ka(a.c5);
  } else Ka(a.c5);
  a.l = a.c1.l || a.c2.l || a.c3.l || a.c4.l || a.c5.l;
};
// Vk (t272): 91 B raw
let Vk = Ea("<div class=article-preview><div class=article-meta><a></a><div class=info><!><!>", 0);
// Wk (k272): 472 B raw
let Wk = {
  m: (a, b) => {
    let c = Vk(), d = c.firstChild, e = d.firstChild, f = e.nextSibling, g = f.firstChild, h = g.nextSibling, i = Fa(e, null, b), j = Fa(f, g, b), k = Fa(f, h, b), l = Fa(d, null, b), m = Fa(c, null, b), n = {
      s: c,
      q: null,
      e: c,
      w2: e,
      c1: i,
      c2: j,
      c3: k,
      c4: l,
      c5: m,
      a0: undefined,
      a1_0: undefined,
      a2_0: undefined,
      a3_0: undefined,
      a5_0: undefined,
      a5_1: undefined,
      l0_0: NaN,
      d0: undefined,
      l1_0: NaN,
      l1_1: NaN,
      l1_2: NaN,
      d1: undefined,
      g0_0: NaN,
      g1_0: NaN,
      g2_0: NaN,
      g2_1: NaN,
      g3_0: NaN,
      g3_1: NaN,
      g3_2: NaN,
      g3_3: NaN
    };
    Uk(n, a);
    return n;
  },
  p: Uk,
  l: true
};
// Xk (t177): 66 B raw
let Xk = Ea("<div class=article-preview>No articles are here... yet.", 0);
// Yk (k177): 55 B raw
let Yk = {
  m: () => {
    let c = Xk();
    return {
      s: c,
      q: null,
      e: c
    };
  },
  p: () => {}
};
// Zk (b177): 16 B raw
let Zk = {
  t: Yk,
  v: null
};
// $k (p196): 171 B raw
let $k = (a, b) => {
  let c = b[0];
  if (c.O !== a.g0_0 || c.g !== a.g0_1) {
    a.g0_0 = c.O;
    a.g0_1 = c.g;
    let d = c.O, e = a => a.A, f = {
      b: a => _k(Qb(c.g), a)
    };
    nb(a.c0, d, e, f, [ c.g ]);
  } else Ka(a.c0);
  a.l = a.c0.w || a.c0.l;
};
// al (t196): 35 B raw
let al = Ea("<div class=article-list>", 0);
// bl (k196): 112 B raw
let bl = {
  m: (a, b) => {
    let c = al(), d = Fa(c, null, b), e = {
      s: c,
      q: null,
      e: c,
      c0: d,
      g0_0: NaN,
      g0_1: NaN
    };
    $k(e, a);
    return e;
  },
  p: $k,
  l: true
};
// cl (p199): 259 B raw
let cl = (a, b) => {
  let c = b[0], d = c.C;
  if (d !== a.g0_0) {
    a.g0_0 = d;
    let e = c.C;
    if (e !== a.a0_1) {
      a.a0_1 = e;
      Qa(a.c0, Hk(Nk, e));
    } else Ka(a.c0);
  } else Ka(a.c0);
  if (c.O !== a.g1_0 || c.g !== a.g1_1) {
    a.g1_0 = c.O;
    a.g1_1 = c.g;
    let f = Wc(c.O) ? Zk : {
      t: bl,
      v: [ c ]
    };
    Qa(a.c1, f);
  } else Ka(a.c1);
  a.l = a.c0.l || a.c1.l;
};
// dl (t199): 17 B raw
let dl = Ea("<!><!>", 4);
// el (k199): 187 B raw
let el = {
  m: (a, b) => {
    let c = dl(), d = c.firstChild, e = d.nextSibling, f = Fa(null, d, b), g = Fa(null, e, b), h = {
      s: null,
      q: f,
      e: e,
      c0: f,
      c1: g,
      a0_1: undefined,
      g0_0: NaN,
      g1_0: NaN,
      g1_1: NaN
    };
    cl(h, a);
    return h;
  },
  p: cl,
  l: true
};
// fl (t337): 56 B raw
let fl = Ea("<li class=page-item><a class=page-link href> ", 0);
// gl (p339): 733 B raw
let gl = (a, b) => {
  let c = b[0], d = b[1], e = b[2];
  if (c !== a.g0_0 || e !== a.g0_1 || d.ja !== a.g0_2) {
    a.g0_0 = c;
    a.g0_1 = e;
    a.g0_2 = d.ja;
    let f = Hc(c), g = {
      m: (a, b, c) => {
        let f = a === d.ja, g = `page-${Kd(a)}`, i = h => {
          Mk(h);
          return e(a);
        }, j = Kd(a), k = fl(), l = k.firstChild, m = l.firstChild;
        if (f) k.classList.toggle("active", true);
        l.setAttribute("id", g);
        l.$$click = i;
        l.$$clickX = Fb;
        if (c !== null) l.$$cx = c;
        m.data = j;
        return {
          s: k,
          q: null,
          e: k,
          w0: k,
          w1: l,
          w2: m,
          a0: f,
          a1: g,
          a2: i,
          a3: j
        };
      },
      p: (a, b) => {
        let f = b === d.ja, g = h => {
          Mk(h);
          return e(b);
        };
        if (f !== a.a0) {
          a.a0 = f;
          a.w0.classList.toggle("active", f);
        }
        if (g !== a.a2) {
          a.a2 = g;
          a.w1.$$click = g;
        }
        if (b !== a.x) {
          let i = `page-${Kd(b)}`, j = Kd(b);
          if (i !== a.a1) {
            a.w1.setAttribute("id", i);
            a.a1 = i;
          }
          if (j !== a.a3) {
            a.a3 = j;
            a.w2.data = j;
          }
        }
      }
    };
    ob(a.c0, f, g, [ d.ja, e ]);
  } else Ka(a.c0);
  a.l = a.c0.w || a.c0.l;
};
// hl (t339): 32 B raw
let hl = Ea("<ul class=pagination>", 0);
// il (k339): 121 B raw
let il = {
  m: (a, b) => {
    let c = hl(), d = Fa(c, null, b), e = {
      s: c,
      q: null,
      e: c,
      c0: d,
      g0_0: NaN,
      g0_1: NaN,
      g0_2: NaN
    };
    gl(e, a);
    return e;
  },
  p: gl,
  l: true
};
// jl (t343): 14 B raw
let jl = Ea("<!>", 0);
// kl (k343): 55 B raw
let kl = {
  m: () => {
    let c = jl();
    return {
      s: c,
      q: null,
      e: c
    };
  },
  p: () => {}
};
// ll (b343): 16 B raw
let ll = {
  t: kl,
  v: null
};
// _k (viewPreview): 26 B raw
let _k = (a, b) => ({
  t: Wk,
  v: [ b, a ]
});
// sl (viewArticles): 20 B raw
let sl = a => ({
  t: el,
  v: [ a ]
});
// tl (viewPagination): 61 B raw
let tl = (b, c) => {
  let e = a(c.ya + 10 - 1);
  return e > 1 ? {
    t: il,
    v: [ e, c, b ]
  } : ll;
};