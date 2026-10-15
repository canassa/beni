// jt: 48 B raw
let jt = ge('<img class="comment-author-img" alt="">');
// Ut: 158 B raw
let Ut = ge('<div class="card"><div class="card-block"><p class="card-text"></p></div><div class="card-footer">&nbsp;<span class="date-posted"></span></div></div>');
// Dt: 69 B raw
let Dt = ge('<span class="mod-options"><i class="ion-trash-a"></i></span>');
// Lt: 306 B raw
let Lt = ge('<form class="card comment-form"><div class="card-block"><textarea class="form-control" placeholder="Write a comment..." rows="3"></textarea></div><div class="card-footer"><img class="comment-author-img" alt=""><button class="btn btn-sm btn-primary" type="submit">Post Comment</button></div></form>');
// Et: 59 B raw
let Et = ge('<div class="col-xs-12 col-md-8 offset-md-2"></div>');
// Tt: 71 B raw
let Tt = ge("<p>&nbsp;or&nbsp;<!>&nbsp;to add comments on this article.</p>");
// Ft (Comment): 636 B raw
let Ft = ({comment: e, currentUser: t, onDelete: n}) => {
  const r = t && t.username === e.author.username, {id: o, body: i, author: {username: l, image: s}, createdAt: a} = e;
  return (() => {
    const e = Ut.cloneNode(!0), t = e.firstChild, c = t.firstChild, u = t.nextSibling, d = u.firstChild, f = d.nextSibling;
    return c.textContent = i, me(u, Z(Re, {
      href: `@${l}`,
      route: "profile",
      class: "comment-author",
      get children() {
        const e = jt.cloneNode(!0);
        return he(e, "src", s), e;
      }
    }), d), me(u, Z(Re, {
      href: `@${l}`,
      route: "profile",
      class: "comment-author",
      children: l
    }), f), me(f, () => new Date(a).toDateString()), me(u, r && (() => {
      const e = Dt.cloneNode(!0), t = e.firstChild;
      return t.$$click = n, t.$$clickData = o, e;
    })(), null), e;
  })();
};
// Vt (CommentInput): 695 B raw
let Vt = ({slug: e, createComment: t, loadComments: n, currentUser: r}) => {
  const [o, i] = Le({
    body: ""
  }), l = e => i({
    body: e.target.value
  }), s = r => {
    r.preventDefault(), i({
      isCreatingComment: !0
    }), t({
      body: o.body
    }).then(() => {
      i({
        body: ""
      }), n(e, !0);
    }).catch(e => i({
      errors: e
    })).finally(() => i({
      isCreatingComment: !1
    }));
  };
  return [ Z(Ot, {
    get errors() {
      return o.errors;
    }
  }), (() => {
    const e = Lt.cloneNode(!0), t = e.firstChild, n = t.firstChild, i = t.nextSibling.firstChild;
    return e.addEventListener("submit", s), n.addEventListener("change", l), $(e => {
      const t = o.body, l = o.isCreatingComment, s = r.image;
      return t !== e._v$ && (n.value = e._v$ = t), l !== e._v$2 && (n.disabled = e._v$2 = l), 
      s !== e._v$3 && he(i, "src", e._v$3 = s), e;
    }, {
      _v$: void 0,
      _v$2: void 0,
      _v$3: void 0
    }), e;
  })() ];
};
// qt: 589 B raw
let qt = () => {
  const [e, {createComment: t, deleteComment: n, loadComments: r}] = ze(), {currentUser: o, articleSlug: i} = e, l = e => n(e);
  return (() => {
    const n = Et.cloneNode(!0);
    return me(n, o ? Z(Vt, {
      slug: i,
      currentUser: o,
      createComment: t,
      loadComments: r
    }) : (() => {
      const e = Tt.cloneNode(!0), t = e.firstChild, n = t.nextSibling;
      return n.nextSibling, me(e, Z(Re, {
        route: "login",
        children: "Sign in"
      }), t), me(e, Z(Re, {
        route: "register",
        children: "sign up"
      }), n), e;
    })(), null), me(n, Z(ue, {
      fallback: "Loading comments",
      get children() {
        return Z(ie, {
          get each() {
            return e.comments;
          },
          children: e => Z(Ft, {
            comment: e,
            currentUser: o,
            onDelete: l
          })
        });
      }
    }), null), n;
  })();
};
// Bt: 21 B raw
let Bt = ge('<img alt="">');
// zt: 33 B raw
let zt = ge('<i class="ion-edit"></i>');
// It: 119 B raw
let It = ge('<span><button class="btn btn-outline-danger btn-sm"><i class="ion-trash-a"></i> Delete Article</button></span>');
// Mt: 91 B raw
let Mt = ge('<div class="article-meta"><div class="info"><span class="date"></span></div></div>');
// Rt: 22 B raw
let Rt = ge("<span></span>");
// Ht: 306 B raw
let Ht = ge('<div class="article-page"><div class="banner"><div class="container"><h1></h1></div></div><div class="container page"><div class="row article-content"><div class="col-xs-12"><div></div><ul class="tag-list"></ul></div></div><hr><div class="article-actions"></div><div class="row"></div></div></div>');
// Gt: 16 B raw
let Gt = ge("<p></p>");
// Kt: 59 B raw
let Kt = ge('<li class="tag-default tag-pill tag-outline"></li>');
// Wt (ArticleMeta): 1023 B raw
let Wt = e => (() => {
  const t = Mt.cloneNode(!0), n = t.firstChild, r = n.firstChild;
  return me(t, Z(Re, {
    get href() {
      var t;
      return `@${null === (t = e.article) || void 0 === t ? void 0 : t.author.username}`;
    },
    route: "profile",
    get children() {
      const t = Bt.cloneNode(!0);
      return $(() => {
        var n;
        return he(t, "src", null === (n = e.article) || void 0 === n ? void 0 : n.author.image);
      }), t;
    }
  }), n), me(n, Z(Re, {
    get href() {
      var t;
      return `@${null === (t = e.article) || void 0 === t ? void 0 : t.author.username}`;
    },
    route: "profile",
    class: "author",
    get children() {
      var t;
      return null === (t = e.article) || void 0 === t ? void 0 : t.author.username;
    }
  }), r), me(r, () => {
    var t;
    return new Date(null === (t = e.article) || void 0 === t ? void 0 : t.createdAt).toDateString();
  }), me(t, Z(le, {
    get when() {
      return e.canModify;
    },
    get fallback() {
      return Rt.cloneNode(!0);
    },
    get children() {
      const t = It.cloneNode(!0), n = t.firstChild;
      return me(t, Z(Re, {
        get href() {
          return `editor/${e.article.slug}`;
        },
        route: "editor",
        class: "btn btn-outline-secondary btn-sm",
        get children() {
          return [ zt.cloneNode(!0), " Edit Article" ];
        }
      }), n), pe(n, "click", e.onDelete, !0), t;
    }
  }), null), t;
})();
// Yt: 893 B raw
let Yt = Object.freeze({
  __proto__: null,
  default: ({slug: e}) => {
    const [t, {deleteArticle: n}] = ze(), r = () => t.articles[e], o = () => n(e).then(() => location.hash = "/");
    return (() => {
      const e = Ht.cloneNode(!0), n = e.firstChild, i = n.firstChild, l = i.firstChild, s = n.nextSibling.firstChild, a = s.firstChild.firstChild, c = a.nextSibling, u = s.nextSibling.nextSibling.nextSibling;
      return me(l, () => {
        var e;
        return null === (e = r()) || void 0 === e ? void 0 : e.title;
      }), me(i, Z(Wt, {
        get article() {
          return r();
        },
        get canModify() {
          return t.currentUser && t.currentUser.username === (null === (e = r()) || void 0 === e ? void 0 : e.author.username);
          var e;
        },
        onDelete: o
      }), null), me(a, (() => {
        const e = de(() => !!r(), !0);
        return () => e() && r().body.split("\n\n").map(e => (() => {
          const t = Gt.cloneNode(!0);
          return me(t, e), t;
        })());
      })()), me(c, () => {
        var e;
        return null === (e = r()) || void 0 === e ? void 0 : e.tagList.map(e => (() => {
          const t = Kt.cloneNode(!0);
          return me(t, e), t;
        })());
      }), me(u, Z(qt, {})), e;
    })();
  }
});
// Qt: 91 B raw
let Qt = ge('<button class="btn btn-sm action-btn"><i class="ion-plus-round"></i> <!> </button>');