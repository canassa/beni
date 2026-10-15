// at: 21 B raw
let at = ge('<img alt="">');
// ct: 18 B raw
let ct = ge("<h1></h1>");
// ut: 16 B raw
let ut = ge("<p></p>");
// dt: 34 B raw
let dt = ge("<span>Read more...</span>");
// ft: 35 B raw
let ft = ge('<ul class="tag-list"></ul>');
// gt: 126 B raw
let gt = ge('<div class="article-preview"><div class="article-meta"><div class="info"><span class="date"></span></div></div></div>');
// vt: 85 B raw
let vt = ge('<div class="pull-xs-right"><button><i class="ion-heart"></i> </button></div>');
// ht: 59 B raw
let ht = ge('<li class="tag-default tag-pill tag-outline"></li>');
// pt: 1043 B raw
let pt = ({article: e, token: t, onClickFavorite: n}) => {
  const {title: r, description: o, slug: i, createdAt: l, tagList: s, author: {username: a, image: c}} = e;
  return (() => {
    const u = gt.cloneNode(!0), d = u.firstChild, f = d.firstChild, g = f.firstChild;
    return me(d, Z(Re, {
      href: `@${a}`,
      route: "profile",
      get children() {
        const e = at.cloneNode(!0);
        return he(e, "src", c), e;
      }
    }), f), me(f, Z(Re, {
      class: "author",
      href: `@${a}`,
      route: "profile",
      children: a
    }), g), g.textContent = new Date(l).toDateString(), me(d, t && (() => {
      const t = vt.cloneNode(!0), r = t.firstChild;
      return r.firstChild.nextSibling, r.$$click = n, r.$$clickData = e, me(r, () => e.favoritesCount, null), 
      $(() => r.className = e.favorited ? "btn btn-sm btn-primary" : "btn btn-sm btn-outline-primary"), 
      t;
    })(), null), me(u, Z(Re, {
      href: `article/${i}`,
      route: "article",
      class: "preview-link",
      get children() {
        return [ (() => {
          const e = ct.cloneNode(!0);
          return me(e, r), e;
        })(), (() => {
          const e = ut.cloneNode(!0);
          return me(e, o), e;
        })(), dt.cloneNode(!0), (() => {
          const e = ft.cloneNode(!0);
          return me(e, s.map(e => (() => {
            const t = ht.cloneNode(!0);
            return t.textContent = e, t;
          })())), e;
        })() ];
      }
    }), null), u;
  })();
};
// mt: 48 B raw
let mt = ge('<nav><ul class="pagination"></ul></nav>');
// bt: 63 B raw
let bt = ge('<div class="article-preview">Loading articles...</div>');
// yt: 72 B raw
let yt = ge('<div class="article-preview">No articles are here... yet.</div>');
// wt: 69 B raw
let wt = ge('<li class="page-item"><a class="page-link" href=""></a></li>');
// $t (props): 776 B raw
let $t = e => {
  const [{token: t}, {unmakeFavorite: n, makeFavorite: r}] = ze(), o = (e, t) => {
    t.preventDefault(), e.favorited ? n(e.slug) : r(e.slug);
  }, i = (t, n) => {
    n.preventDefault(), e.onSetPage(t), setTimeout(() => window.scrollTo(0, 0), 200);
  };
  return Z(ue, {
    get fallback() {
      return bt.cloneNode(!0);
    },
    get children() {
      return [ Z(ie, {
        get each() {
          return e.articles;
        },
        get fallback() {
          return yt.cloneNode(!0);
        },
        children: e => Z(pt, {
          article: e,
          token: t,
          onClickFavorite: o
        })
      }), Z(le, {
        get when() {
          return e.totalPagesCount > 1;
        },
        get children() {
          const t = mt.cloneNode(!0);
          return me(t.firstChild, Z(ie, {
            get each() {
              return [ ...Array(e.totalPagesCount).keys() ];
            },
            children: t => (() => {
              const n = wt.cloneNode(!0), r = n.firstChild;
              return n.$$click = i, n.$$clickData = t, r.textContent = t + 1, $(() => n.classList.toggle("active", e.currentPage === t)), 
              n;
            })()
          })), t;
        }
      }) ];
    }
  });
};