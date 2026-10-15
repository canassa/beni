// wi (t283): 14 B raw
let wi = Ea("<!>", 0);
// xi (k283): 55 B raw
let xi = {
  m: () => {
    let c = wi();
    return {
      s: c,
      q: null,
      e: c
    };
  },
  p: () => {}
};
// yi (b283): 16 B raw
let yi = {
  t: xi,
  v: null
};
// zi (p293): 179 B raw
let zi = (a, b) => {
  let c = b[0], d = b[1], e = c;
  if (e !== a.g0_0) {
    a.g0_0 = e;
    a.w0.$$click = e;
  }
  let f = d.username;
  if (f !== a.g1_0) {
    a.g1_0 = f;
    let g = ` Unfollow ${d.username}`;
    if (g !== a.a1) {
      a.a1 = g;
      a.x1.data = g;
    }
  }
};
// Ai (t293): 89 B raw
let Ai = Ea('<button class="btn btn-sm action-btn btn-secondary"><i class=ion-plus-round>', 0);
// Bi (k293): 146 B raw
let Bi = {
  m: (a, b) => {
    let c = Ai();
    if (b !== null) c.$$cx = b;
    let d = db(c, null), e = {
      s: c,
      q: null,
      e: c,
      w0: c,
      x1: d,
      a1: undefined,
      g0_0: NaN,
      g1_0: NaN
    };
    zi(e, a);
    return e;
  },
  p: zi
};
// Ci (p303): 177 B raw
let Ci = (a, b) => {
  let c = b[0], d = b[1], e = c;
  if (e !== a.g0_0) {
    a.g0_0 = e;
    a.w0.$$click = e;
  }
  let f = d.username;
  if (f !== a.g1_0) {
    a.g1_0 = f;
    let g = ` Follow ${d.username}`;
    if (g !== a.a1) {
      a.a1 = g;
      a.x1.data = g;
    }
  }
};
// Di (t303): 97 B raw
let Di = Ea('<button class="btn btn-sm action-btn btn-outline-secondary"><i class=ion-plus-round>', 0);
// Ei (k303): 146 B raw
let Ei = {
  m: (a, b) => {
    let c = Di();
    if (b !== null) c.$$cx = b;
    let d = db(c, null), e = {
      s: c,
      q: null,
      e: c,
      w0: c,
      x1: d,
      a1: undefined,
      g0_0: NaN,
      g1_0: NaN
    };
    Ci(e, a);
    return e;
  },
  p: Ci
};
// Qi (followButton): 108 B raw
let Qi = (a, b, c) => {
  switch (c.$) {
   case 0:
    {
      return yi;
    }

   case 1:
    {
      return {
        t: Bi,
        v: [ b, c.a ]
      };
    }

   default:
    {
      return {
        t: Ei,
        v: [ a, c.a ]
      };
    }
  }
};
// Vi (t521): 15 B raw
let Vi = Ea("<p> ", 0);
// Wi (p523): 258 B raw
let Wi = (a, b) => {
  let c = b[0], d = c;
  if (d !== a.g0_0) {
    a.g0_0 = d;
    let e = Id(c, "\n\n"), f = {
      m: () => {
        let d = Vi();
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
    ob(a.c0, e, f, null);
  } else Ka(a.c0);
  a.l = a.c0.w || a.c0.l;
};
// Xi (t523): 38 B raw
let Xi = Ea("<div class=article-content>", 0);
// Yi (k523): 103 B raw
let Yi = {
  m: (a, b) => {
    let c = Xi(), d = Fa(c, null, b), e = {
      s: c,
      q: null,
      e: c,
      c0: d,
      g0_0: NaN
    };
    Wi(e, a);
    return e;
  },
  p: Wi,
  l: true
};
// Jj (body): 20 B raw
let Jj = a => ({
  t: Yi,
  v: [ a ]
});
// Tn (p807): 474 B raw
let Tn = (a, b) => {
  let c = b[0], d = b[1], e = c.A;
  if (e !== a.g0_0) {
    a.g0_0 = e;
    let f = li({
      $: 10,
      a: c.A
    });
    if (f !== a.a0) {
      a.w1.setAttribute("href", Cb(f));
      a.a0 = f;
    }
  }
  if (a.g1 === undefined) {
    a.g1 = true;
    if (" Edit Article" !== a.a1) {
      a.a1 = " Edit Article";
      a.x1.data = " Edit Article";
    }
    if (" " !== a.a2) {
      a.a2 = " ";
      a.x2.data = " ";
    }
    if (" Delete Article" !== a.a4) {
      a.a4 = " Delete Article";
      a.x4.data = " Delete Article";
    }
  }
  if (c.A !== a.g2_0 || d !== a.g2_1) {
    a.g2_0 = c.A;
    a.g2_1 = d;
    let g = {
      $: 0,
      a: d,
      b: c.A,
      c: null
    };
    if (g !== a.a3) {
      a.a3 = g;
      a.w3.$$click = g;
    }
  }
};
// Un (t807): 158 B raw
let Un = Ea('<span><a class="btn btn-outline-secondary btn-sm"><i class=ion-edit></i></a><button class="btn btn-outline-danger btn-sm"><i class=ion-trash-a>', 0);
// Vn (k807): 289 B raw
let Vn = {
  m: (a, b) => {
    let c = Un(), d = c.firstChild, e = d.nextSibling, f = db(d, null), g = db(c, e);
    if (b !== null) e.$$cx = b;
    let h = db(e, null), i = {
      s: c,
      q: null,
      e: c,
      w1: d,
      w3: e,
      x1: f,
      x2: g,
      x4: h,
      a0: undefined,
      a1: undefined,
      a2: undefined,
      a3: undefined,
      a4: undefined,
      g0_0: NaN,
      g1: undefined,
      g2_0: NaN,
      g2_1: NaN
    };
    Tn(i, a);
    return i;
  },
  p: Tn
};
// Wn (p837): 636 B raw
let Wn = (a, b) => {
  let c = b[0], d = b[1];
  if (c.j !== a.l0_0) {
    a.l0_0 = c.j;
    let e = ti(c.j);
    a.d0 = e;
  }
  let f = a.d0;
  if (c.j !== a.g0_0 || d !== a.g0_1) {
    a.g0_0 = c.j;
    a.g0_1 = d;
    let g = {
      $: 5,
      a: d,
      b: f,
      c: null
    }, h = {
      $: 6,
      a: d,
      b: f,
      c: null
    }, i = c.j;
    if (g !== a.a0_0 || h !== a.a0_1 || i !== a.a0_2) {
      a.a0_0 = g;
      a.a0_1 = h;
      a.a0_2 = i;
      Qa(a.c0, Qi(g, h, i));
    } else Ka(a.c0);
  } else Ka(a.c0);
  if (a.g1 === undefined) {
    a.g1 = true;
    if (" " !== a.a1) {
      a.a1 = " ";
      a.x1.data = " ";
    }
  }
  if (d !== a.g2_0 || c !== a.g2_1 || c.A !== a.g2_2) {
    a.g2_0 = d;
    a.g2_1 = c;
    a.g2_2 = c.A;
    let j = {
      $: 3,
      a: d,
      b: c.A,
      c: null
    }, k = {
      $: 4,
      a: d,
      b: c.A,
      c: null
    };
    if (c !== a.a2_0 || j !== a.a2_1 || k !== a.a2_2) {
      a.a2_0 = c;
      a.a2_1 = j;
      a.a2_2 = k;
      Qa(a.c2, Lj(c, j, k, ""));
    } else Ka(a.c2);
  } else Ka(a.c2);
  a.l = a.c0.l || a.c2.l;
};
// Xn (t837): 26 B raw
let Xn = Ea("<span><!><!><!>", 0);
// Yn (k837): 353 B raw
let Yn = {
  m: (a, b) => {
    let c = Xn(), d = c.firstChild, e = d.nextSibling, f = e.nextSibling, g = Fa(c, d, b), h = Fa(c, f, b), i = db(c, e), j = {
      s: c,
      q: null,
      e: c,
      c0: g,
      x1: i,
      c2: h,
      a0_0: undefined,
      a0_1: undefined,
      a0_2: undefined,
      a1: undefined,
      a2_0: undefined,
      a2_1: undefined,
      a2_2: undefined,
      l0_0: NaN,
      d0: undefined,
      g0_0: NaN,
      g0_1: NaN,
      g1: undefined,
      g2_0: NaN,
      g2_1: NaN,
      g2_2: NaN
    };
    Wn(j, a);
    return j;
  },
  p: Wn,
  l: true
};
// Zn (t770): 14 B raw
let Zn = Ea("<!>", 0);
// $n (k770): 55 B raw
let $n = {
  m: () => {
    let c = Zn();
    return {
      s: c,
      q: null,
      e: c
    };
  },
  p: () => {}
};
// _n (b770): 16 B raw
let _n = {
  t: $n,
  v: null
};
// ao (p773): 700 B raw
let ao = (a, b) => {
  let c = b[0], d = b[1];
  if (c.j !== a.l0_0) {
    a.l0_0 = c.j;
    let e = Ji(c.j);
    a.d0 = e;
  }
  let f = a.d0;
  if (c.j !== a.l1_0) {
    a.l1_0 = c.j;
    a.d1 = f.username;
  }
  let h = a.d1, i = c.j;
  if (i !== a.g0_0) {
    a.g0_0 = i;
    let j = li({
      $: 7,
      a: h
    }), k = f.E, l = c.j;
    if (j !== a.a0) {
      a.w1.setAttribute("href", Cb(j));
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
  if (d.g !== a.g2_0 || c !== a.g2_1) {
    a.g2_0 = d.g;
    a.g2_1 = c;
    let o = Qb(d.g), p;
    if (o.$ === 0) {
      let q = o.a;
      p = c.j.$ === 0 ? {
        t: Vn,
        v: [ c, q ]
      } : {
        t: Yn,
        v: [ c, q ]
      };
    } else p = _n;
    Qa(a.c4, p);
  } else Ka(a.c4);
  a.l = a.c1.l || a.c2.l || a.c3.l || a.c4.l;
};
// bo (t773): 64 B raw
let bo = Ea("<div class=article-meta><a></a><div class=info><!><!>", 0);
// co (k773): 353 B raw
let co = {
  m: (a, b) => {
    let c = bo(), d = c.firstChild, e = d.nextSibling, f = e.firstChild, g = f.nextSibling, h = Fa(d, null, b), i = Fa(e, f, b), j = Fa(e, g, b), k = Fa(c, null, b), l = {
      s: c,
      q: null,
      e: c,
      w1: d,
      c1: h,
      c2: i,
      c3: j,
      c4: k,
      a0: undefined,
      a1_0: undefined,
      a2_0: undefined,
      a3_0: undefined,
      l0_0: NaN,
      d0: undefined,
      l1_0: NaN,
      d1: undefined,
      g0_0: NaN,
      g1_0: NaN,
      g2_0: NaN,
      g2_1: NaN
    };
    ao(l, a);
    return l;
  },
  p: ao,
  l: true
};
// eo (p947): 555 B raw
let eo = (a, b) => {
  let c = b[0], d = b[1], e = b[2], f = b[3];
  if (c.aa !== a.g0_0 || d !== a.g0_1) {
    a.g0_0 = c.aa;
    a.g0_1 = d;
    let g = () => ({
      $: 7,
      a: c.aa,
      b: d,
      c: null
    });
    if (g !== a.a0) {
      a.a0 = g;
      a.w0.$$submit = g;
    }
  }
  let h = e;
  if (h !== a.g1_0) {
    a.g1_0 = h;
    zb(a.w2, "value", e);
  }
  let i = f;
  if (i !== a.g2_0) {
    a.g2_0 = i;
    Ab(a.w2, "disabled", i ? "" : null);
    Ab(a.w4, "disabled", i ? "" : null);
  }
  if (a.g3 === undefined) {
    a.g3 = true;
    let j = a => ({
      $: 8,
      a: a,
      b: null,
      c: null
    });
    if (j !== a.a3) {
      a.a3 = j;
      a.w2.$$input = j;
    }
  }
  let k = c.E;
  if (k !== a.g4_0) {
    a.g4_0 = k;
    let l = c.E;
    if (l !== a.a4_0) {
      a.a4_0 = l;
      Qa(a.c4, Oi(l, "comment-author-img"));
    } else Ka(a.c4);
  } else Ka(a.c4);
  a.l = a.c4.l;
};
// fo (t947): 257 B raw
let fo = Ea('<form id=comment-form class="card comment-form"><div class=card-block><textarea id=comment class=form-control placeholder="Write a comment..."rows=3></textarea></div><div class=card-footer><button class="btn btn-sm btn-primary">Post Comment', 0);
// go (k947): 355 B raw
let go = {
  m: (a, b) => {
    let c = fo(), d = c.firstChild, e = d.firstChild, f = d.nextSibling, g = f.firstChild, h = Fa(f, g, b);
    c.$$submitX = Fb;
    c.$$submitF = 1;
    if (b !== null) c.$$cx = b;
    e.$$inputX = Lk;
    if (b !== null) e.$$cx = b;
    let i = {
      s: c,
      q: null,
      e: c,
      w0: c,
      w2: e,
      w4: g,
      c4: h,
      a0: undefined,
      a3: undefined,
      a4_0: undefined,
      g0_0: NaN,
      g0_1: NaN,
      g1_0: NaN,
      g2_0: NaN,
      g3: undefined,
      g4_0: NaN
    };
    eo(i, a);
    return i;
  },
  p: eo,
  l: true
};
// ho (p960): 347 B raw
let ho = a => {
  if (a.g0 === undefined) {
    a.g0 = true;
    let c = li(Rn), d = li(Sn);
    if (c !== a.a0) {
      a.w1.setAttribute("href", Cb(c));
      a.a0 = c;
    }
    if (" or " !== a.a1) {
      a.a1 = " or ";
      a.x1.data = " or ";
    }
    if (d !== a.a2) {
      a.w3.setAttribute("href", Cb(d));
      a.a2 = d;
    }
    if (" to add comments on this article." !== a.a3) {
      a.a3 = " to add comments on this article.";
      a.x3.data = " to add comments on this article.";
    }
  }
};
// io (t960): 45 B raw
let io = Ea("<p><a>Sign in</a><a>sign up</a><!>", 0);
// jo (k960): 215 B raw
let jo = {
  m: a => {
    let c = io(), d = c.firstChild, e = d.nextSibling, f = e.nextSibling, g = db(c, e), h = db(c, f), i = {
      s: c,
      q: null,
      e: c,
      w1: d,
      w3: e,
      x1: g,
      x3: h,
      a0: undefined,
      a1: undefined,
      a2: undefined,
      a3: undefined,
      g0: undefined
    };
    ho(i, a);
    return i;
  },
  p: ho
};
// ko (b960): 16 B raw
let ko = {
  t: jo,
  v: null
};
// lo (p1023): 169 B raw
let lo = (a, b) => {
  let c = b[0], d = b[1], e = b[2];
  if (c !== a.g0_0 || d !== a.g0_1 || e.T !== a.g0_2) {
    a.g0_0 = c;
    a.g0_1 = d;
    a.g0_2 = e.T;
    let f = {
      $: 1,
      a: c,
      b: d,
      c: e.T
    };
    if (f !== a.a0) {
      a.a0 = f;
      a.w1.$$click = f;
    }
  }
};
// mo (t1023): 56 B raw
let mo = Ea("<span class=mod-options><i class=ion-trash-a>", 0);
// no (k1023): 152 B raw
let no = {
  m: (a, b) => {
    let c = mo(), d = c.firstChild;
    if (b !== null) d.$$cx = b;
    let e = {
      s: c,
      q: null,
      e: c,
      w1: d,
      a0: undefined,
      g0_0: NaN,
      g0_1: NaN,
      g0_2: NaN
    };
    lo(e, a);
    return e;
  },
  p: lo
};
// oo (t1026): 14 B raw
let oo = Ea("<!>", 0);
// po (k1026): 55 B raw
let po = {
  m: () => {
    let c = oo();
    return {
      s: c,
      q: null,
      e: c
    };
  },
  p: () => {}
};
// qo (b1026): 16 B raw
let qo = {
  t: po,
  v: null
};
// ro (p1029): 897 B raw
let ro = (a, b) => {
  let c = b[0], d = b[1], e = b[2];
  if (c.j !== a.l0_0) {
    a.l0_0 = c.j;
    let f = Ji(c.j);
    a.d0 = f;
  }
  let g = a.d0, h = c.body;
  if (h !== a.g0_0) {
    a.g0_0 = h;
    a.w3.data = h;
  }
  let i = c.j;
  if (i !== a.g1_0) {
    a.g1_0 = i;
    let j = li({
      $: 7,
      a: g.username
    }), k = g.E, l = li({
      $: 7,
      a: g.username
    }), m = g.username;
    if (j !== a.a1) {
      a.w5.setAttribute("href", Cb(j));
      a.a1 = j;
    }
    if (k !== a.a2_0) {
      a.a2_0 = k;
      Qa(a.c2, Oi(k, "comment-author-img"));
    } else Ka(a.c2);
    if (l !== a.a4) {
      a.w6.setAttribute("href", Cb(l));
      a.a4 = l;
    }
    if (m !== a.a5) {
      a.a5 = m;
      a.w7.data = m;
    }
  } else Ka(a.c2);
  if (a.g2 === undefined) {
    a.g2 = true;
    if (" " !== a.a3) {
      a.a3 = " ";
      a.x3.data = " ";
    }
  }
  let n = c.N;
  if (n !== a.g3_0) {
    a.g3_0 = n;
    let o = c.N;
    if (o !== a.a6_0) {
      a.a6_0 = o;
      Qa(a.c6, Ij(o));
    } else Ka(a.c6);
  } else Ka(a.c6);
  if (c.j !== a.g4_0 || d !== a.g4_1 || e !== a.g4_2 || c.T !== a.g4_3) {
    a.g4_0 = c.j;
    a.g4_1 = d;
    a.g4_2 = e;
    a.g4_3 = c.T;
    let p = c.j, q;
    r: {
      a: {
        if (p.$ === 0) if (d.$ === 0) {
          q = {
            t: no,
            v: [ d.a, e, c ]
          };
          break r;
        } else break a;
        break a;
      }
      q = qo;
    }
    Qa(a.c7, q);
  } else Ka(a.c7);
  a.l = a.c2.l || a.c6.l || a.c7.l;
};
// so (t1029): 165 B raw
let so = Ea("<div class=card><div class=card-block><p class=card-text> </p></div><div class=card-footer><a class=comment-author></a><a class=comment-author> </a><!><!>", 0);
// to (k1029): 478 B raw
let to = {
  m: (a, b) => {
    let c = so(), d = c.firstChild, f = d.firstChild.firstChild, g = d.nextSibling, h = g.firstChild, i = h.nextSibling, j = i.firstChild, k = i.nextSibling, l = k.nextSibling, m = Fa(h, null, b), n = Fa(g, k, b), o = Fa(g, l, b), p = db(g, i), q = {
      s: c,
      q: null,
      e: c,
      w3: f,
      w5: h,
      w6: i,
      w7: j,
      c2: m,
      x3: p,
      c6: n,
      c7: o,
      a1: undefined,
      a2_0: undefined,
      a3: undefined,
      a4: undefined,
      a5: undefined,
      a6_0: undefined,
      l0_0: NaN,
      d0: undefined,
      g0_0: NaN,
      g1_0: NaN,
      g2: undefined,
      g3_0: NaN,
      g4_0: NaN,
      g4_1: NaN,
      g4_2: NaN,
      g4_3: NaN
    };
    ro(q, a);
    return q;
  },
  p: ro,
  l: true
};
// uo (t881): 14 B raw
let uo = Ea("<!>", 0);
// vo (k881): 55 B raw
let vo = {
  m: () => {
    let c = uo();
    return {
      s: c,
      q: null,
      e: c
    };
  },
  p: () => {}
};
// wo (b881): 16 B raw
let wo = {
  t: vo,
  v: null
};
// xo (p877): 408 B raw
let xo = (a, b) => {
  let c = b[0], d = b[1], e = b[2], f = b[3];
  if (c.g !== a.g0_0 || d !== a.g0_1 || e !== a.g0_2) {
    a.g0_0 = c.g;
    a.g0_1 = d;
    a.g0_2 = e;
    let g = c.g;
    if (g !== a.a0_0 || d !== a.a0_1 || e !== a.a0_2) {
      a.a0_0 = g;
      a.a0_1 = d;
      a.a0_2 = e;
      Qa(a.c0, yo(g, d, e));
    } else Ka(a.c0);
  } else Ka(a.c0);
  if (c.g !== a.g1_0 || d !== a.g1_1 || f !== a.g1_2) {
    a.g1_0 = c.g;
    a.g1_1 = d;
    a.g1_2 = f;
    let h = a => a.T, i = {
      b: a => zo(Qb(c.g), d, a)
    };
    nb(a.c1, f, h, i, [ c.g, d ]);
  } else Ka(a.c1);
  a.l = a.c0.l || a.c1.w || a.c1.l;
};
// Ao (t877): 17 B raw
let Ao = Ea("<!><!>", 4);
// Bo (k877): 244 B raw
let Bo = {
  m: (a, b) => {
    let c = Ao(), d = c.firstChild, e = d.nextSibling, f = Fa(null, d, b), g = Fa(null, e, b), h = {
      s: null,
      q: f,
      e: e,
      c0: f,
      c1: g,
      a0_0: undefined,
      a0_1: undefined,
      a0_2: undefined,
      g0_0: NaN,
      g0_1: NaN,
      g0_2: NaN,
      g1_0: NaN,
      g1_1: NaN,
      g1_2: NaN
    };
    xo(h, a);
    return h;
  },
  p: xo,
  l: true
};
// Co (t704): 14 B raw
let Co = Ea("<!>", 0);
// Do (k704): 55 B raw
let Do = {
  m: () => {
    let c = Co();
    return {
      s: c,
      q: null,
      e: c
    };
  },
  p: () => {}
};
// Eo (b704): 16 B raw
let Eo = {
  t: Do,
  v: null
};
// Fo (p698): 837 B raw
let Fo = (a, b) => {
  let c = b[0], d = b[1], e = c.title;
  if (e !== a.g0_0) {
    a.g0_0 = e;
    a.w4.data = e;
  }
  if (d !== a.g1_0 || c !== a.g1_1) {
    a.g1_0 = d;
    a.g1_1 = c;
    if (d !== a.a1_0 || c !== a.a1_1) {
      a.a1_0 = d;
      a.a1_1 = c;
      Qa(a.c1, Go(d, c));
    } else Ka(a.c1);
    if (d !== a.a5_0 || c !== a.a5_1) {
      a.a5_0 = d;
      a.a5_1 = c;
      Qa(a.c5, Go(d, c));
    } else Ka(a.c5);
  } else {
    Ka(a.c1);
    Ka(a.c5);
  }
  let f = d.C;
  if (f !== a.g2_0) {
    a.g2_0 = f;
    let g = d.C;
    if (g !== a.a2_1) {
      a.a2_1 = g;
      Qa(a.c2, Hk(Ln, g));
    } else Ka(a.c2);
  } else Ka(a.c2);
  let h = c.body;
  if (h !== a.g3_0) {
    a.g3_0 = h;
    let i = c.body;
    if (i !== a.a3_0) {
      a.a3_0 = i;
      Qa(a.c3, Jj(i));
    } else Ka(a.c3);
  } else Ka(a.c3);
  let j = c.B;
  if (j !== a.g4_0) {
    a.g4_0 = j;
    let k = c.B;
    if (k !== a.a4_0) {
      a.a4_0 = k;
      Qa(a.c4, Kj(k));
    } else Ka(a.c4);
  } else Ka(a.c4);
  if (d !== a.g5_0 || c.A !== a.g5_1) {
    a.g5_0 = d;
    a.g5_1 = c.A;
    let l = c.A;
    if (d !== a.a6_0 || l !== a.a6_1) {
      a.a6_0 = d;
      a.a6_1 = l;
      Qa(a.c6, Ho(d, l));
    } else Ka(a.c6);
  } else Ka(a.c6);
  a.l = a.c1.l || a.c2.l || a.c3.l || a.c4.l || a.c5.l || a.c6.l;
};
// Io (t698): 304 B raw
let Io = Ea('<div class=article-page><div class=banner><div class=container><h1> </h1><!><!></div></div><div class="container page"><div class="row article-content"><div class=col-md-12><!><!></div></div><hr><div class=article-actions></div><div class=row><div class="col-xs-12 col-md-8 offset-md-2">', 0);
// Jo (k698): 614 B raw
let Jo = {
  m: (a, b) => {
    let c = Io(), d = c.firstChild, e = d.firstChild, f = e.firstChild, g = f.firstChild, h = f.nextSibling, i = h.nextSibling, k = d.nextSibling.firstChild, l = k.firstChild, m = l.firstChild, n = m.nextSibling, o = k.nextSibling.nextSibling, q = o.nextSibling.firstChild, r = Fa(e, h, b), s = Fa(e, i, b), t = Fa(l, m, b), u = Fa(l, n, b), v = Fa(o, null, b), w = Fa(q, null, b), x = {
      s: c,
      q: null,
      e: c,
      w4: g,
      c1: r,
      c2: s,
      c3: t,
      c4: u,
      c5: v,
      c6: w,
      a1_0: undefined,
      a1_1: undefined,
      a2_1: undefined,
      a3_0: undefined,
      a4_0: undefined,
      a5_0: undefined,
      a5_1: undefined,
      a6_0: undefined,
      a6_1: undefined,
      g0_0: NaN,
      g1_0: NaN,
      g1_1: NaN,
      g2_0: NaN,
      g3_0: NaN,
      g4_0: NaN,
      g5_0: NaN,
      g5_1: NaN
    };
    Fo(x, a);
    return x;
  },
  p: Fo,
  l: true
};
// Go (viewMeta): 26 B raw
let Go = (a, b) => ({
  t: co,
  v: [ b, a ]
});
// yo (viewAddComment): 233 B raw
let yo = (a, b, c) => {
  if (a.$ === 0) {
    let e = a.b, f;
    if (c.$ === 0) f = {
      a: c.a,
      b: false
    }; else f = {
      a: c.a,
      b: true
    };
    return {
      t: go,
      v: [ e, b, f.a, f.b ]
    };
  }
  if (Nb.$ === 0) {
    let j = Nb.a, k;
    if (c.$ === 0) k = {
      a: c.a,
      b: false
    }; else k = {
      a: c.a,
      b: true
    };
    return {
      t: go,
      v: [ j, b, k.a, k.b ]
    };
  }
  return ko;
};
// zo (viewComment): 30 B raw
let zo = (a, b, c) => ({
  t: to,
  v: [ c, a, b ]
});
// Ho (viewComments): 143 B raw
let Ho = (a, b) => {
  let c = a.K;
  switch (c.$) {
   case 0:
    {
      return wo;
    }

   case 1:
    {
      return Ik;
    }

   case 2:
    {
      return {
        t: Bo,
        v: [ a, b, c.a.a, c.a.b ]
      };
    }

   default:
    {
      return Jk("comments");
    }
  }
};
// Mo (view): 235 B raw
let Mo = a => {
  let b = a.M;
  switch (b.$) {
   case 0:
    {
      return {
        content: Eo,
        title: "Article"
      };
    }

   case 1:
    {
      return {
        content: Ik,
        title: "Article"
      };
    }

   case 2:
    {
      let c = b.a;
      return {
        content: {
          t: Jo,
          v: [ c, a ]
        },
        title: c.title
      };
    }

   default:
    {
      return {
        content: Jk("article"),
        title: "Article"
      };
    }
  }
};