// 站点交互：目录开关 + 客户端全文搜索。没有依赖，没有网络请求之外的东西。
(function () {
  "use strict";

  // ── mobile sidebar ────────────────────────────────────────────────────
  var button = document.querySelector(".menu-button");
  var sidebar = document.querySelector(".sidebar");
  if (button && sidebar) {
    button.addEventListener("click", function () {
      var open = sidebar.classList.toggle("open");
      button.setAttribute("aria-expanded", open ? "true" : "false");
    });
  }

  // ── search ────────────────────────────────────────────────────────────
  var input = document.getElementById("search-input");
  var box = document.getElementById("search-results");
  if (!input || !box) return;

  var index = null;
  var loading = false;

  function load() {
    if (index || loading) return;
    loading = true;
    fetch("search-index.json")
      .then(function (r) { return r.json(); })
      .then(function (data) { index = data; loading = false; if (input.value.trim()) run(); })
      .catch(function () { loading = false; });
  }

  function snippet(text, at, length) {
    var start = Math.max(0, at - 30);
    var piece = text.slice(start, start + length);
    return (start > 0 ? "…" : "") + piece + (start + length < text.length ? "…" : "");
  }

  function run() {
    var query = input.value.trim().toLowerCase();
    if (!query) { box.hidden = true; box.innerHTML = ""; return; }
    if (!index) { load(); return; }

    var hits = [];
    index.forEach(function (page) {
      var text = page.text || "";
      var at = text.toLowerCase().indexOf(query);
      var titleAt = page.title.toLowerCase().indexOf(query);
      if (at < 0 && titleAt < 0) return;
      hits.push({
        page: page,
        score: titleAt >= 0 ? 0 : 1,
        snippet: at >= 0 ? snippet(text, at, 110) : ""
      });
    });

    hits.sort(function (a, b) { return a.score - b.score; });
    hits = hits.slice(0, 8);
    box.innerHTML = "";

    if (!hits.length) {
      var empty = document.createElement("p");
      empty.className = "empty";
      empty.textContent = "没有匹配。试试「对比」「线性」「蒙版」。";
      box.appendChild(empty);
    } else {
      hits.forEach(function (hit) {
        var link = document.createElement("a");
        link.href = hit.page.slug + ".html";
        link.textContent = hit.page.title;
        if (hit.snippet) {
          var span = document.createElement("span");
          span.className = "snippet";
          span.textContent = hit.snippet;
          link.appendChild(span);
        }
        box.appendChild(link);
      });
    }
    box.hidden = false;
  }

  input.addEventListener("focus", load);
  input.addEventListener("input", run);
  input.addEventListener("keydown", function (event) {
    if (event.key === "Escape") { input.value = ""; run(); input.blur(); }
    if (event.key === "Enter") {
      var first = box.querySelector("a");
      if (first) window.location.href = first.href;
    }
  });

  document.addEventListener("keydown", function (event) {
    if (event.key === "/" && document.activeElement !== input &&
        !/^(INPUT|TEXTAREA)$/.test(document.activeElement.tagName)) {
      event.preventDefault();
      input.focus();
    }
  });

  document.addEventListener("click", function (event) {
    if (!box.contains(event.target) && event.target !== input) box.hidden = true;
  });
})();
