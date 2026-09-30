// Features reel: the section's shots stack in one sticky frame. Scrolling
// far enough picks the next shot; it then rises over the previous one by
// itself (see .reel-frame in style.css), and the caption beside them
// scrambles letter by letter into the new shot's caption.
(() => {
  const section = document.getElementById("features");
  const shots = [...section.querySelectorAll(".shot")];
  if (shots.length < 2) return;

  const reel = document.createElement("div");
  reel.className = "reel";
  const stage = document.createElement("div");
  stage.className = "reel-stage";
  const text = document.createElement("div");
  const caption = document.createElement("p");
  caption.className = "reel-caption";
  caption.setAttribute("aria-hidden", "true");
  const frame = document.createElement("div");
  frame.className = "reel-frame";
  shots[0].before(reel);
  reel.append(stage);
  text.append(section.querySelector("h2"), caption);
  stage.append(text, frame);
  frame.append(...shots);
  shots.forEach((s, i) => { s.style.zIndex = i; s.querySelector("img").loading = "eager"; });

  const texts = shots.map((s) => s.querySelector("figcaption").textContent.trim());
  const steps = texts.length;
  reel.style.setProperty("--count", steps);
  caption.textContent = texts[0];

  const reduced = matchMedia("(prefers-reduced-motion: reduce)").matches;
  const glyphs = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789#%&*+=<>/";
  const pick = () => glyphs[(Math.random() * glyphs.length) | 0];
  let scrambleFrame = 0;

  // Each letter waits a random moment, cycles through random glyphs for a
  // short while, then lands on its new character. Spaces stay spaces.
  function scramble(to) {
    cancelAnimationFrame(scrambleFrame);
    if (reduced) { caption.textContent = to; return; }
    const from = caption.textContent;
    const n = Math.max(from.length, to.length);
    const letters = Array.from({ length: n }, (_, i) => {
      const start = Math.random() * 260;
      return { from: from[i] ?? "", to: to[i] ?? "", start, end: start + 90 + Math.random() * 180, glyph: pick(), next: 0 };
    });
    const t0 = performance.now();
    const tick = (now) => {
      const t = now - t0;
      let done = true;
      caption.textContent = letters.map((l) => {
        if (t >= l.end) return l.to;
        done = false;
        if (t < l.start) return l.from;
        if (l.to === " " || l.to === "") return l.to;
        if (t >= l.next) { l.glyph = pick(); l.next = t + 40; }
        return l.glyph;
      }).join("");
      if (!done) scrambleFrame = requestAnimationFrame(tick);
    };
    scrambleFrame = requestAnimationFrame(tick);
  }

  const clamp = (x) => Math.min(1, Math.max(0, x));
  let active = -1;
  let queued = false;

  function show(n) {
    shots.forEach((s, i) => {
      s.classList.toggle("is-current", i === n);
      s.classList.toggle("is-previous", i === n - 1);
      s.classList.toggle("is-past", i < n - 1);
    });
  }

  function update() {
    queued = false;
    const travel = reel.offsetHeight - innerHeight;
    const pos = clamp(-reel.getBoundingClientRect().top / travel) * (steps - 1);
    const now = Math.min(steps - 1, Math.floor(pos + 0.5));
    if (now === active) return;
    if (active < 0) caption.textContent = texts[now];
    else scramble(texts[now]);
    active = now;
    show(now);
  }
  const request = () => { if (!queued) { queued = true; requestAnimationFrame(update); } };
  addEventListener("scroll", request, { passive: true });
  addEventListener("resize", request);
  update();
})();
