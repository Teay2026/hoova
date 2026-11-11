// Hoova : la page. Un seul Hoova, dessiné d'après Brand.swift, qui va d'un bloc à l'autre en se cachant derrière un
// bord, puis en ressortant de derrière le suivant. Le geste ⌃ ⌃ explique le mot qu'on montre, comme dans l'app.
(() => {
  'use strict';

  const root = document.documentElement;
  const $ = (selector, scope = document) => scope.querySelector(selector);
  const $$ = (selector, scope = document) => [...scope.querySelectorAll(selector)];
  const reduceQuery = matchMedia('(prefers-reduced-motion: reduce)');
  const fineQuery = matchMedia('(hover: hover) and (pointer: fine)');
  const reduced = () => reduceQuery.matches;
  const wait = ms => new Promise(resolve => setTimeout(resolve, ms));
  const EASE_OUT = 'cubic-bezier(.23, 1, .32, 1)';
  const EASE_IN_OUT = 'cubic-bezier(.77, 0, .175, 1)';
  const GITHUB = 'https://github.com/Teay2026/hoova';

  const heroDemo = $('.demo');
  const word = $('.word');
  const lit = $('.word-lit');
  const caret = $('.caret');
  const card = $('#explain');
  const keys = $$('.key');
  const live = $('#live');

  const desk = $('.desk');
  const deskWindow = $('.desk-window');
  const deskCard = $('#desk-card');
  const deskText = $('#desk-text');
  const deskPointer = $('.desk-pointer');
  const says = $$('.say');

  const moonStage = $('.moon-stage');
  const moonFace = $('.moon-face');
  const installSteps = $('.install-stage');
  const installAnyway = $('#install-anyway');
  const endMark = $('.end-mark');
  const endDot = $('.end-dot');

  const perch = $('.perch');
  const hv = $('.hv');
  const svg = $('.hoova');
  const fig = $('.hv-fig');
  const eyesGroup = $('.hv-eyes');
  const eyes = $$('.hv-eyes .eye');
  const feet = [$('.foot-l'), $('.foot-r')];
  const heroStars = $('.hero .stars');
  const aurora = $('.aurora');

  const meanings = {
    money: 'Here, a bank is a company that keeps money and lends it. Raising its rates makes loans cost more.',
    river: 'Here, the bank is the ground along the edge of the river.',
  };

  // Les mots du titre entrent un par un, et la réponse de l'IA s'écrit mot à mot : on les découpe, en gardant le
  // texte lisible.
  function split() {
    word.setAttribute('aria-label', `${$('.word-base').textContent}, explain this word`);
    let token = 0;
    for (const node of [...$('.reply-text').childNodes]) {
      if (node === word) {
        word.classList.add('tok');
        word.style.setProperty('--i', token++);
      } else if (node.nodeType === Node.TEXT_NODE) {
        const fragment = document.createDocumentFragment();
        for (const part of node.textContent.split(/(\s+)/)) {
          if (!part) continue;
          if (/^\s+$/.test(part)) {
            fragment.append(part);
            continue;
          }
          const span = document.createElement('span');
          span.className = 'tok';
          span.style.setProperty('--i', token++);
          span.textContent = part;
          fragment.append(span);
        }
        node.replaceWith(fragment);
      }
    }
    let index = 0;
    for (const line of $$('.hl-line')) {
      const words = line.textContent.split(' ');
      line.textContent = '';
      words.forEach((text, position) => {
        const span = document.createElement('span');
        span.className = 'w';
        span.style.setProperty('--i', index++);
        span.textContent = text;
        line.append(span);
        if (position < words.length - 1) line.append(' ');
      });
    }
  }

  // Des ciels fixes : des étoiles tirées d'une graine, plus nombreuses en haut, et les étoiles ✳ de la DA.
  function drawStars(sky) {
    const ns = 'http://www.w3.org/2000/svg';
    let seed = Number(sky.dataset.seed ?? 20261108);
    const random = () => (seed = (seed * 1664525 + 1013904223) >>> 0) / 4294967296;
    const count = Number(sky.dataset.stars ?? 130);
    const fragment = document.createDocumentFragment();
    for (let i = 0; i < count; i++) {
      const y = random() ** 1.7 * 900;
      const star = document.createElementNS(ns, 'circle');
      star.setAttribute('cx', (random() * 1440).toFixed(1));
      star.setAttribute('cy', y.toFixed(1));
      star.setAttribute('r', (0.45 + random() ** 3 * 1.35).toFixed(2));
      star.setAttribute('opacity', (0.18 + random() * 0.72 * (1 - y / 1300)).toFixed(2));
      star.style.setProperty('--d', `${Math.round(random() * 1100)}ms`);
      fragment.append(star);
    }
    const tones = ['mint', 'iris', 'ink', 'iris', 'ink', 'gold', 'mint'];
    // Ailleurs que dans le haut de la page, les ✳ restent sur les bords : jamais sur le texte.
    const sparks = sky === heroStars
      ? [[150, 120, 10], [1330, 250, 8], [1190, 322, 6], [262, 404, 7], [1236, 760, 8], [86, 650, 6]]
      : Array.from({ length: Math.max(2, Math.round(count / 12)) }, (_, index) => [
          index % 2 ? 1250 + random() * 150 : 40 + random() * 150,
          60 + random() * 780,
          5 + random() * 4,
        ]);
    sparks.forEach(([x, y, size], index) => {
      let d = '';
      for (let step = 0; step < 4; step++) {
        const angle = (step * Math.PI) / 4;
        const dx = Math.cos(angle) * size;
        const dy = Math.sin(angle) * size;
        d += `M${(x - dx).toFixed(1)} ${(y - dy).toFixed(1)}L${(x + dx).toFixed(1)} ${(y + dy).toFixed(1)}`;
      }
      const spark = document.createElementNS(ns, 'path');
      spark.setAttribute('d', d);
      spark.setAttribute('class', `spark spark-${tones[index % tones.length]}`);
      spark.setAttribute('stroke-width', (size * 0.28).toFixed(2));
      spark.style.setProperty('--d', `${Math.round(300 + random() * 900)}ms`);
      fragment.append(spark);
    });
    sky.append(fragment);
  }

  // La part éclairée de la lune à cet âge (0 : nouvelle lune, 0,5 : pleine lune), autour de (0, 0), comme
  // Mascot.lunarPhase. Croissante, elle est éclairée à droite ; décroissante, il faut la retourner.
  function phasePath(age, r = 31) {
    const k = 0.5523;
    const waxing = age < 0.5;
    const edge = r * Math.cos(2 * Math.PI * (waxing ? age : 1 - age));
    const n = value => +value.toFixed(2);
    return {
      d:
        `M0 ${-r}C${n(k * r)} ${-r} ${r} ${n(-k * r)} ${r} 0C${r} ${n(k * r)} ${n(k * r)} ${r} 0 ${r}` +
        `C${n(k * edge)} ${r} ${n(edge)} ${n(k * r)} ${n(edge)} 0C${n(edge)} ${n(-k * r)} ${n(k * edge)} ${-r} 0 ${-r}Z`,
      flip: waxing ? 1 : -1,
    };
  }

  // Sa lune a la phase de la vraie lune, calculée sans réseau, comme dans l'app.
  function drawMoon() {
    const days = (Date.now() / 1000 - 947182440) / 86400;
    let age = (days / 29.530588853) % 1;
    if (age < 0) age += 1;
    const { d, flip } = phasePath(age);
    const phase = $('.moon-phase');
    phase.setAttribute('d', d);
    phase.setAttribute('transform', `translate(474.985 427.998) rotate(-30) scale(${flip} 1)`);
  }

  // Les cinq lunes de l'accueil de l'app : de la nouvelle lune, vide, à la pleine lune, en or.
  function drawMoons() {
    const ns = 'http://www.w3.org/2000/svg';
    const row = $('.moons');
    [0, 0.12, 0.25, 0.38, 0.5].forEach((age, index) => {
      const moon = document.createElementNS(ns, 'svg');
      moon.setAttribute('viewBox', '-34 -34 68 68');
      if (index === 4) moon.classList.add('moon-gold');
      const rim = document.createElementNS(ns, 'circle');
      rim.setAttribute('r', '31');
      rim.setAttribute('class', 'moon-rim');
      moon.append(rim);
      if (age > 0) {
        const tilt = document.createElementNS(ns, 'g');
        tilt.setAttribute('transform', 'rotate(-30)');
        const lit = document.createElementNS(ns, 'path');
        lit.setAttribute('d', phasePath(age).d);
        lit.setAttribute('class', 'moon-lit');
        lit.style.setProperty('--i', index);
        tilt.append(lit);
        moon.append(tilt);
      }
      row.append(moon);
    });
  }

  // Hors d'un Mac, les boutons disent que Hoova est pour Mac, et mènent à GitHub.
  function adaptToDevice() {
    const mac = /Macintosh|Mac OS X/.test(navigator.userAgent) && navigator.maxTouchPoints < 2;
    if (mac) return;
    for (const button of $$('[data-download]')) {
      button.textContent = 'Hoova is for Mac';
      button.href = GITHUB;
    }
    for (const line of $$('[data-fine]')) line.textContent = 'Free and open source. Open this page on a Mac to download it.';
  }

  /* Ses places. Chacune a une scène (l'élément où il se pose), un bord (où il se tient), et une pose : debout, ou
     qui dépasse de derrière. */

  const STAND = 0;
  const PEEK = 44;
  const GONE = 101;
  let cardShift = 0;
  let deskSpot = { left: 0, top: 0 };

  function boxIn(stage, element) {
    const outer = stage.getBoundingClientRect();
    const inner = element.getBoundingClientRect();
    return { left: inner.left - outer.left, top: inner.top - outer.top, width: inner.width, height: inner.height };
  }

  const spots = {
    // Il dépasse du haut de la bulle de réponse, près de son coin droit.
    word: { stage: heroDemo, pose: PEEK, edge: () => boxIn(heroDemo, $('.reply')), from: 'right', inset: 1.08 },
    // Le pop-up grandit en s'ouvrant : sa place se lit sans ses transformations.
    card: {
      stage: heroDemo,
      pose: STAND,
      reads: true,
      edge: () => ({ left: card.offsetLeft + cardShift, top: card.offsetTop, width: card.offsetWidth }),
      from: 'right',
      inset: 0.9,
    },
    window: { stage: desk, pose: PEEK, edge: () => boxIn(desk, deskWindow), from: 'right', inset: 1.12 },
    popup: {
      stage: desk,
      pose: STAND,
      reads: true,
      edge: () => ({ left: deskSpot.left, top: deskSpot.top, width: deskCard.offsetWidth }),
      from: 'right',
      inset: 0.9,
    },
    moon: { stage: moonStage, pose: STAND, edge: () => boxIn(moonStage, moonFace), from: 'center', sink: 0.025 },
    install: { stage: installSteps, pose: PEEK, edge: () => boxIn(installSteps, installAnyway), from: 'right', inset: 1.05 },
    // Debout à côté du point de « hoova. », à sa droite, sur la ligne des lettres : jamais sur le point.
    dot: {
      stage: endMark,
      pose: STAND,
      edge: () => {
        const dot = boxIn(endMark, endDot);
        return { left: dot.left + dot.width * 1.35, top: dot.top + dot.height, width: 0 };
      },
      from: 'left',
      inset: 0.135,
      appear: true,
    },
  };

  // Assez de place à droite du mot : le pop-up déborde du mot, et Hoova se tient à côté. Sinon, le pop-up
  // descend d'une hauteur de Hoova, pour qu'il ne cache jamais le mot.
  function layoutCard() {
    // Sa taille dans le haut de la page (--hv-size), même quand il se tient ailleurs.
    const size = Math.min(152, Math.max(84, root.clientWidth * 0.105));
    const room = root.clientWidth - heroDemo.getBoundingClientRect().right - 16;
    const side = room >= size * 0.85;
    cardShift = side ? Math.round(Math.min(room, size)) : 0;
    heroDemo.classList.toggle('card-side', side);
    heroDemo.style.setProperty('--card-shift', `${cardShift}px`);
  }

  function attach(name) {
    const spot = spots[name];
    if (perch.parentElement !== spot.stage) spot.stage.append(perch);
    position(name);
  }

  function position(name) {
    const spot = spots[name];
    if (!spot) return;
    const size = perch.offsetWidth;
    const edge = spot.edge();
    // « center » : au milieu du bord ; « left » : son corps commence au bord gauche ; sinon, contre le bord droit.
    const x =
      spot.from === 'center'
        ? edge.left + edge.width / 2 - size * 0.5
        : spot.from === 'left'
          ? edge.left - size * spot.inset
          : edge.left + edge.width - size * spot.inset;
    const y = edge.top - size + (spot.sink ?? 0) * size;
    perch.style.transform = `translate(${Math.round(x)}px, ${Math.round(y)}px)`;
  }

  /* Ses trajets. Il ne glisse jamais : il se cache derrière le bord où il est (0,2 s), marque une pause (0,25 s), puis
     sort de derrière le suivant (0,32 s). La dernière place demandée l'emporte. */

  let rise = GONE;
  let riseAnimation = null;
  let here = null;
  let wanted = null;
  let trip = null;

  function moveTo(to, duration, easing = EASE_OUT) {
    const from = rise;
    rise = to;
    riseAnimation?.cancel();
    hv.style.transform = `translateY(${to}%)`;
    if (reduced() || !duration) return Promise.resolve();
    riseAnimation = hv.animate([{ transform: `translateY(${from}%)` }, { transform: `translateY(${to}%)` }], { duration, easing });
    return riseAnimation.finished.catch(() => {});
  }

  function goTo(name) {
    wanted = name;
    trip ??= travel().finally(() => {
      trip = null;
    });
    return trip;
  }

  // La même place, mais le bord a bougé (le pop-up suit un autre mot) : il refait le trajet.
  function hopAgain(name) {
    if (here === name) here = `${name}*`;
    return goTo(name);
  }

  async function travel() {
    while (wanted !== here) {
      const target = wanted;
      if (here && rise < GONE) await leave();
      here = target;
      if (!target) continue;
      attach(target);
      applyLevel();
      await enter(target);
      if (wanted === target) await settle(target);
    }
  }

  async function leave() {
    setFloating(false);
    gaze = null;
    const spot = spots[here?.replace('*', '')];
    if (reduced()) {
      moveTo(GONE, 0);
      return;
    }
    if (spot?.appear) {
      await hv.animate([{ opacity: 1, scale: 1 }, { opacity: 0, scale: 0.94 }], { duration: 200, easing: 'ease-in' }).finished.catch(() => {});
      moveTo(GONE, 0);
    } else {
      await moveTo(GONE, 200, EASE_IN_OUT);
    }
    hv.style.translate = '';
    await wait(250);
  }

  async function enter(name) {
    const spot = spots[name];
    if (reduced()) {
      moveTo(spot.pose, 0);
      return;
    }
    if (spot.appear) {
      moveTo(spot.pose, 0);
      await hv.animate([{ opacity: 0, scale: 0.94 }, { opacity: 1, scale: 1 }], { duration: 320, easing: EASE_OUT }).finished.catch(() => {});
    } else {
      await moveTo(spot.pose, 320);
    }
    kick();
  }

  // Une fois là : sur un pop-up, il fait deux petits pas, lit et sourit ; à l'éveil final, il flotte.
  async function settle(name) {
    const spot = spots[name];
    if (reduced()) return;
    if (explained >= 3 && spot.pose === STAND) {
      if (!svg.classList.contains('is-final')) {
        setLevel(3);
        await wait(520);
      }
      if (wanted === name) setFloating(true);
      return;
    }
    if (spot.reads) {
      await walk();
      if (wanted === name) await readAndSmile();
    }
  }

  function setMood(mood) {
    svg.dataset.mood = mood;
  }

  // Deux petits pas vers la gauche, un pied après l'autre, comme sur le bord du pop-up de l'app.
  async function walk() {
    for (const [index, foot] of feet.entries()) {
      foot.animate(
        [{ transform: 'translateY(0)' }, { transform: 'translateY(-22px)', offset: 0.5 }, { transform: 'translateY(0)' }],
        { duration: 240, easing: 'ease-in-out' },
      );
      const from = `${-12 * index}% 0`;
      const to = `${-12 * (index + 1)}% 0`;
      hv.style.translate = to;
      await hv.animate([{ translate: from }, { translate: to }], { duration: 240, easing: 'ease-in-out' }).finished.catch(() => {});
      await wait(40);
    }
  }

  // Il regarde ce qui est écrit, sourit, puis te regarde de nouveau.
  async function readAndSmile() {
    gaze = { x: -7, y: 10 };
    kick();
    setMood('reading');
    await wait(800);
    setMood('proud');
    await wait(950);
    gaze = null;
    kick();
    if (!touching) setMood('happy');
  }

  /* Ses yeux suivent ton pointeur, avec un ressort, et le ciel du haut bouge d'un rien avec eux. */

  const pointer = { x: 0, y: 0, active: false };
  const look = { x: 0, y: 0, vx: 0, vy: 0 };
  const sky = { x: 0, y: 0, vx: 0, vy: 0 };
  let gaze = null;
  let frame = 0;

  function spring(state, tx, ty, stiffness, damping) {
    state.vx = (state.vx + (tx - state.x) * stiffness) * damping;
    state.vy = (state.vy + (ty - state.y) * stiffness) * damping;
    state.x += state.vx;
    state.y += state.vy;
    return Math.abs(state.vx) + Math.abs(state.vy) > 0.003 || Math.abs(tx - state.x) + Math.abs(ty - state.y) > 0.01;
  }

  function tick() {
    frame = 0;
    let tx = 0;
    let ty = 0;
    if (gaze) {
      ({ x: tx, y: ty } = gaze);
    } else if (pointer.active) {
      const box = svg.getBoundingClientRect();
      const dx = pointer.x - (box.left + box.width * 0.43);
      const dy = pointer.y - (box.top + box.height * 0.5);
      const distance = Math.hypot(dx, dy) || 1;
      const reach = Math.min(1, distance / 260);
      tx = (dx / distance) * 11 * reach;
      ty = (dy / distance) * 9 * reach;
    }
    const eyesMoving = spring(look, tx, ty, 0.16, 0.68);
    eyesGroup.setAttribute('transform', `translate(${look.x.toFixed(2)} ${look.y.toFixed(2)})`);
    const inHero = scene === 'hero' && pointer.active;
    const skyMoving = spring(sky, inHero ? pointer.x / innerWidth - 0.5 : 0, inHero ? pointer.y / innerHeight - 0.5 : 0, 0.05, 0.8);
    heroStars.style.translate = `${(-sky.x * 10).toFixed(2)}px ${(-sky.y * 6).toFixed(2)}px`;
    aurora.style.translate = `${(-sky.x * 24).toFixed(2)}px ${(-sky.y * 10).toFixed(2)}px`;
    if (eyesMoving || skyMoving) frame = requestAnimationFrame(tick);
  }

  function kick() {
    if (!frame && !reduced()) frame = requestAnimationFrame(tick);
  }

  function blinkLater() {
    setTimeout(() => {
      if (!reduced() && rise < GONE && !document.hidden) {
        for (const eye of eyes) {
          eye.animate([{ transform: 'scaleY(1)' }, { transform: 'scaleY(.1)', offset: 0.5 }, { transform: 'scaleY(1)' }], {
            duration: 170,
            easing: 'ease-in-out',
          });
        }
      }
      blinkLater();
    }, 2400 + Math.random() * 2200);
  }

  /* La série d'éveils, comme dans l'app : au deuxième mot expliqué, il prend la menthe de sa lune ; au troisième,
     l'éveil final. Cinq minutes sans explication, et il redevient Hoova. */

  let explained = 0;
  let calmTimer = 0;

  function setLevel(level) {
    svg.classList.toggle('is-awake', level >= 2);
    svg.classList.toggle('is-final', level >= 3);
  }

  // Il sort de derrière le bord dans son état : en éveil final s'il l'a déjà atteint, sinon en Hoova éveil.
  function applyLevel() {
    if (svg.classList.contains('is-final')) return;
    setLevel(Math.min(explained, 2));
  }

  function setFloating(floating) {
    svg.classList.toggle('is-floating', floating);
    perch.classList.toggle('is-floating', floating);
  }

  function calmLater() {
    clearTimeout(calmTimer);
    calmTimer = setTimeout(() => {
      if (heroOpen || deskOpen) return calmLater();
      explained = 0;
      setFloating(false);
      setLevel(0);
    }, 5 * 60 * 1000);
  }

  /* Les explications : le mot du haut de la page, et les deux « bank » du faux bureau. */

  let heroOpen = false;
  let deskOpen = null;
  let shotStar = false;

  function explainedOne(text) {
    explained += 1;
    calmLater();
    live.textContent = `Hoova: ${text}`;
    if (!shotStar) {
      shotStar = true;
      shootingStar();
    }
  }

  function openHero() {
    if (heroOpen) return;
    heroOpen = true;
    word.setAttribute('aria-expanded', 'true');
    root.classList.add('is-open');
    explainedOne($('.card-text', card).textContent);
    goTo('card');
  }

  function closeHero(quiet = false) {
    if (!heroOpen) return;
    heroOpen = false;
    word.setAttribute('aria-expanded', 'false');
    root.classList.remove('is-open');
    live.textContent = '';
    if (!quiet) goTo('word');
  }

  // La fin de la ligne où est le mot, dans le faux bureau.
  function lineEnd(button) {
    const range = document.createRange();
    range.selectNodeContents(button.parentElement);
    const box = button.getBoundingClientRect();
    let right = box.right;
    for (const rect of range.getClientRects()) {
      if (rect.bottom > box.top + 2 && rect.top < box.bottom - 2) right = Math.max(right, rect.right);
    }
    return right - desk.getBoundingClientRect().left;
  }

  // Le pop-up du faux bureau se pose sous le mot, sans sortir de l'écran, et assez à droite pour que Hoova, debout
  // sur son bord, se tienne après la fin de la ligne : jamais sur ce qu'on lit.
  function placeDeskCard(button) {
    const box = boxIn(desk, button);
    const width = deskCard.offsetWidth;
    const size = Math.min(92, Math.max(54, root.clientWidth * 0.062));
    let left = box.left - 18;
    left = Math.max(left, lineEnd(button) + size * 0.9 - width);
    left = Math.max(12, Math.min(left, desk.offsetWidth - width - 8));
    const top = box.top + button.offsetHeight + 8;
    deskSpot = { left, top };
    deskCard.style.left = `${left}px`;
    deskCard.style.top = `${top}px`;
  }

  async function openDesk(key) {
    if (deskOpen === key) return;
    const switching = deskOpen !== null;
    deskOpen = key;
    const button = says.find(say => say.dataset.say === key);
    for (const say of says) {
      say.classList.toggle('is-lit', say === button);
      say.setAttribute('aria-expanded', String(say === button));
    }
    // Il se cache tout de suite ; il ressortira de derrière le nouveau pop-up, déjà posé.
    if (scene === 'how') hopAgain('popup');
    if (switching && !reduced()) {
      desk.classList.remove('is-open');
      await wait(170);
      if (deskOpen !== key) return;
    }
    deskText.textContent = meanings[key];
    placeDeskCard(button);
    desk.classList.add('is-open');
    explainedOne(meanings[key]);
  }

  function closeDesk(quiet = false) {
    if (!deskOpen) return;
    deskOpen = null;
    desk.classList.remove('is-open');
    for (const say of says) {
      say.classList.remove('is-lit');
      say.setAttribute('aria-expanded', 'false');
    }
    live.textContent = '';
    if (!quiet && scene === 'how') goTo('window');
  }

  /* Le geste : deux appuis brefs sur ⌃, sans autre touche entre les deux. Il explique le mot sous le pointeur, ou
     celui du bloc qu'on regarde. Les touches dessinées s'enfoncent et s'allument à chaque appui. */

  let pressedAt = 0;
  let lastTap = 0;
  let otherKey = false;
  let lightTimer = 0;
  let hovered = null;

  function light(duration) {
    for (const key of keys) key.classList.add('is-lit');
    clearTimeout(lightTimer);
    lightTimer = setTimeout(() => {
      for (const key of keys) key.classList.remove('is-lit');
    }, duration);
  }

  function press(down) {
    for (const key of keys) key.classList.toggle('is-down', down);
  }

  function gesture() {
    if (hovered?.classList.contains('say') || (!hovered && scene === 'how')) {
      deskTouched = true;
      const key = hovered?.dataset.say ?? (deskOpen ? null : says[0].dataset.say);
      if (!key || deskOpen === key) closeDesk();
      else openDesk(key);
    } else if (hovered === word || scene === 'hero') {
      if (heroOpen) closeHero();
      else openHero();
    }
  }

  function tap() {
    const now = performance.now();
    if (lastTap && now - lastTap < 520) {
      lastTap = 0;
      light(280);
      gesture();
    } else {
      lastTap = now;
      light(520);
    }
  }

  addEventListener('keydown', event => {
    if (event.key === 'Escape') {
      closeHero();
      closeDesk();
      return;
    }
    if (event.key !== 'Control') {
      otherKey = true;
      lastTap = 0;
      return;
    }
    if (event.repeat) return;
    otherKey = false;
    pressedAt = performance.now();
    press(true);
  });

  addEventListener('keyup', event => {
    if (event.key !== 'Control') return;
    press(false);
    if (otherKey || performance.now() - pressedAt > 400) {
      lastTap = 0;
      return;
    }
    tap();
  });

  addEventListener('blur', () => {
    press(false);
    lastTap = 0;
  });

  // On peut aussi appuyer sur une touche dessinée, ou toucher un mot.
  for (const key of keys) {
    key.addEventListener('pointerdown', event => {
      event.preventDefault();
      press(true);
    });
    key.addEventListener('pointerup', () => {
      press(false);
      tap();
    });
    key.addEventListener('pointerleave', () => press(false));
  }

  word.addEventListener('click', () => (heroOpen ? closeHero() : openHero()));
  for (const say of says) {
    say.addEventListener('click', () => {
      deskTouched = true;
      if (deskOpen === say.dataset.say) closeDesk();
      else openDesk(say.dataset.say);
    });
  }

  document.addEventListener('pointerover', event => {
    hovered = event.target.closest?.('.word, .say') ?? null;
  });

  document.addEventListener('pointerdown', event => {
    const inside = selector => event.target.closest(selector);
    if (heroOpen && !inside('.word, .card, .key, .hv-fig')) closeHero();
    if (deskOpen && !inside('.say, .desk-card, .key, .hv-fig')) {
      deskTouched = true;
      closeDesk();
    }
  });

  /* Il se touche : survolé, il sourit ; un clic, il ferme les yeux. Hoova éveil en est ravi, et l'éveil final laisse
     jaillir son aura. */

  let touching = false;
  let ouching = false;

  fig.addEventListener('pointerenter', () => {
    touching = true;
    if (fineQuery.matches && !ouching && !gaze) setMood('proud');
  });

  fig.addEventListener('pointerleave', () => {
    touching = false;
    if (!ouching && !gaze) setMood('happy');
  });

  fig.addEventListener('click', async () => {
    if (ouching || reduced()) return;
    ouching = true;
    if (svg.classList.contains('is-final')) {
      burstAura();
      await wait(900);
    } else if (svg.classList.contains('is-awake')) {
      setMood('proud');
      sparkles();
      await wait(700);
    } else {
      setMood('hurt');
      fig.animate([{ transform: 'scale(1, 1)' }, { transform: 'scale(1.05, .9)', offset: 0.3 }, { transform: 'scale(1, 1)' }], {
        duration: 460,
        easing: EASE_OUT,
      });
      await wait(650);
    }
    ouching = false;
    setMood(touching && fineQuery.matches ? 'proud' : 'happy');
  });

  // Une gerbe d'étincelles de Hoova : des étoiles ✳ d'or, de menthe et de lavande (0,7 s).
  function sparkles() {
    const ns = 'http://www.w3.org/2000/svg';
    const colors = ['#FFCC3D', '#C9F4DD', '#C4B1FB'];
    for (let i = 0; i < 9; i++) {
      const angle = -Math.PI / 2 + (i - 4) * 0.38 + (Math.random() - 0.5) * 0.2;
      const distance = 210 + Math.random() * 90;
      const size = 24 + Math.random() * 16;
      let d = '';
      for (let step = 0; step < 4; step++) {
        const a = (step * Math.PI) / 4;
        d += `M${(-Math.cos(a) * size).toFixed(1)} ${(-Math.sin(a) * size).toFixed(1)}L${(Math.cos(a) * size).toFixed(1)} ${(Math.sin(a) * size).toFixed(1)}`;
      }
      const spark = document.createElementNS(ns, 'path');
      spark.setAttribute('d', d);
      spark.setAttribute('fill', 'none');
      spark.setAttribute('stroke', colors[i % 3]);
      spark.setAttribute('stroke-width', (size * 0.32).toFixed(1));
      spark.setAttribute('stroke-linecap', 'round');
      svg.append(spark);
      const x = Math.cos(angle) * distance;
      const y = Math.sin(angle) * distance;
      spark
        .animate(
          [
            { transform: 'translate(475px, 420px) scale(.4)', opacity: 1, easing: EASE_OUT },
            { transform: `translate(${475 + x * 0.8}px, ${420 + y * 0.8}px) scale(1)`, opacity: 1, offset: 0.55, easing: 'ease-in' },
            { transform: `translate(${475 + x}px, ${420 + y}px) scale(.6)`, opacity: 0 },
          ],
          { duration: 700 },
        )
        .finished.then(() => spark.remove(), () => spark.remove());
    }
  }

  // L'aura jaillit : un éclat doré, puis deux ondes de sa silhouette, surtout vers les côtés (0,9 s).
  function burstAura() {
    const ns = 'http://www.w3.org/2000/svg';
    const flash = document.createElementNS(ns, 'circle');
    flash.setAttribute('cx', '474.985');
    flash.setAttribute('cy', '403.998');
    flash.setAttribute('r', '60');
    flash.setAttribute('fill', '#FFCC3D');
    flash.setAttribute('filter', 'url(#hv-blur-16)');
    flash.style.transformBox = 'fill-box';
    flash.style.transformOrigin = 'center';
    svg.insertBefore(flash, fig);
    flash.animate([{ transform: 'scale(.6)', opacity: 0.95 }, { transform: 'scale(1.8)', opacity: 0 }], { duration: 600, easing: EASE_OUT }).finished.then(
      () => flash.remove(),
      () => flash.remove(),
    );
    [0, 160].forEach((delay, index) => {
      const wave = document.createElementNS(ns, 'use');
      wave.setAttribute('href', '#hv-shape');
      wave.setAttribute('fill', index ? '#FFCC3D' : '#C9F4DD');
      wave.setAttribute('filter', 'url(#hv-blur-9)');
      wave.style.transformOrigin = '515px 600px';
      svg.insertBefore(wave, fig);
      wave
        .animate([{ transform: 'translateY(-24px) scale(1, 1)', opacity: 0.85 }, { transform: 'translateY(-24px) scale(1.7, 1.3)', opacity: 0 }], {
          duration: 900 - delay,
          delay,
          easing: EASE_OUT,
          fill: 'backwards',
        })
        .finished.then(() => wave.remove(), () => wave.remove());
    });
  }

  // Au premier mot expliqué, une étoile filante passe, comme au réveil dans l'accueil de l'app.
  function shootingStar() {
    if (reduced() || scene !== 'hero') return;
    const width = innerWidth;
    const height = innerHeight;
    $('.shooting').animate(
      [
        { transform: `translate(${width * 0.16}px, ${height * 0.08}px) rotate(13deg)`, opacity: 0 },
        { opacity: 1, offset: 0.25 },
        { transform: `translate(${width * 0.6}px, ${height * 0.2}px) rotate(13deg)`, opacity: 0 },
      ],
      { duration: 1000, easing: 'cubic-bezier(.2, .7, .3, 1)' },
    );
  }

  /* Le faux bureau se montre une fois tout seul, la première fois qu'on y arrive : un pointeur va sur le premier
     « bank », ⌃ ⌃, Hoova l'explique ; puis le second, au sens différent. On peut ensuite essayer soi-même. */

  let deskTouched = false;
  let deskShown = false;

  async function pointAt(button) {
    const box = boxIn(desk, button);
    const x = box.left + box.width * 0.7;
    const y = box.top + button.offsetHeight * 0.75;
    const from = deskPointer.style.transform || `translate(${desk.offsetWidth * 0.82}px, ${desk.offsetHeight * 0.86}px)`;
    const to = `translate(${Math.round(x)}px, ${Math.round(y)}px)`;
    deskPointer.style.transform = to;
    deskPointer.style.opacity = '1';
    await deskPointer.animate([{ transform: from, opacity: 1 }, { transform: to, opacity: 1 }], { duration: 760, easing: EASE_IN_OUT }).finished.catch(() => {});
  }

  async function pressBoth() {
    for (let i = 0; i < 2; i++) {
      press(true);
      for (const key of keys) key.classList.add('is-lit');
      await wait(110);
      press(false);
      await wait(170);
    }
    light(260);
  }

  async function showDesk() {
    if (deskShown || deskTouched || reduced()) return;
    deskShown = true;
    await wait(500);
    for (const [index, button] of says.entries()) {
      if (deskTouched || scene !== 'how') break;
      await pointAt(button);
      if (deskTouched || scene !== 'how') break;
      await pressBoth();
      if (deskTouched || scene !== 'how') break;
      openDesk(button.dataset.say);
      if (index === 0) await wait(3400);
    }
    await wait(600);
    deskPointer.animate([{ opacity: 1 }, { opacity: 0 }], { duration: 300, fill: 'forwards' });
  }

  /* Les blocs : celui qu'on regarde décide où se tient Hoova. Le film et les questions n'ont pas de place pour lui :
     il reste où il est. */

  let scene = 'hero';
  const scenes = $$('[data-scene]');
  const shown = new Map();

  function restingSpot(name) {
    if (name === 'hero') return heroOpen ? 'card' : 'word';
    if (name === 'how') return deskOpen ? 'popup' : 'window';
    if (name === 'private') return 'moon';
    if (name === 'install') return 'install';
    if (name === 'end') return 'dot';
    return undefined;
  }

  function setScene(name) {
    if (name === scene) return;
    const previous = scene;
    scene = name;
    if (previous === 'hero') closeHero(true);
    if (previous === 'how') closeDesk(true);
    const spot = restingSpot(name);
    if (spot !== undefined && introDone) goTo(spot);
    if (name === 'how') showDesk();
  }

  const sceneObserver = new IntersectionObserver(
    entries => {
      for (const entry of entries) shown.set(entry.target, entry.isIntersecting ? entry.intersectionRect.height : 0);
      let best = null;
      let most = 0;
      for (const [element, height] of shown) {
        if (height > most) {
          most = height;
          best = element;
        }
      }
      if (best && most > innerHeight * 0.3) setScene(best.dataset.scene);
    },
    { threshold: [0, 0.15, 0.3, 0.45, 0.6, 0.75, 0.9, 1] },
  );

  // Un seul moment par bloc, la première fois qu'on y arrive : l'écran s'allume, la lune s'éclaire, les mots
  // tombent un par un, le ciel de la fin reprend ses couleurs.
  const momentObserver = new IntersectionObserver(
    entries => {
      for (const entry of entries) {
        if (!entry.isIntersecting) continue;
        entry.target.classList.add('is-seen');
        momentObserver.unobserve(entry.target);
      }
    },
    { threshold: 0.4 },
  );

  // À la fin, quand on télécharge, il s'envole vers la barre des menus.
  async function flyAway() {
    if (here !== 'dot' || reduced() || trip) return;
    const top = perch.getBoundingClientRect().bottom + 60;
    wanted = null;
    setFloating(false);
    await perch
      .animate([{ translate: '0 0' }, { translate: `${perch.offsetWidth * 0.5}px ${-top}px` }], {
        duration: 900,
        easing: 'cubic-bezier(.55, 0, .7, .2)',
      })
      .finished.catch(() => {});
    moveTo(GONE, 0);
    here = null;
  }

  /* L'entrée : la nuit, la phrase, puis un curseur sélectionne le mot. Hoova sort de derrière lui et regarde, et la
     touche montre le geste. */

  let introDone = false;

  function select() {
    const width = lit.offsetWidth;
    lit.style.clipPath = 'inset(0 0 0 0)';
    const timing = { duration: 760, easing: EASE_IN_OUT };
    lit.animate([{ clipPath: 'inset(0 100% 0 0)' }, { clipPath: 'inset(0 0% 0 0)' }], timing);
    caret.animate([{ transform: 'translateX(0)' }, { transform: `translateX(${width - 14}px)` }], { ...timing, fill: 'both' });
    caret.animate([{ opacity: 0 }, { opacity: 1, offset: 0.1 }, { opacity: 1, offset: 0.82 }, { opacity: 0 }], { duration: 920, fill: 'both' });
    return wait(820);
  }

  async function showKey() {
    for (let i = 0; i < 2; i++) {
      press(true);
      for (const key of keys) key.classList.add('is-lit');
      await wait(110);
      press(false);
      await wait(190);
    }
    await wait(240);
    for (const key of keys) key.classList.remove('is-lit');
  }

  function relayout() {
    layoutCard();
    if (deskOpen) placeDeskCard(says.find(say => say.dataset.say === deskOpen));
    if (here) position(here.replace('*', ''));
  }

  async function start() {
    split();
    for (const sky of $$('.stars')) drawStars(sky);
    drawMoon();
    drawMoons();
    adaptToDevice();
    relayout();
    new ResizeObserver(relayout).observe(heroDemo);
    addEventListener('resize', relayout);
    addEventListener('pointermove', event => {
      pointer.x = event.clientX;
      pointer.y = event.clientY;
      pointer.active = event.pointerType === 'mouse';
      kick();
    });
    document.addEventListener('pointerleave', () => {
      pointer.active = false;
      kick();
    });
    for (const button of $$('[data-farewell]')) button.addEventListener('click', flyAway);

    // Le film ne se charge qu'au clic : l'écran se redresse, et les commandes du navigateur prennent le relais.
    const video = $('.film-video');
    $('.play').addEventListener('click', () => {
      video.controls = true;
      video.closest('.screen').classList.add('is-playing');
      video.play().catch(() => {});
      video.focus();
    });
    blinkLater();

    for (const element of scenes) sceneObserver.observe(element);
    for (const element of $$('[data-moment]')) {
      if (reduced()) element.classList.add('is-seen');
      else momentObserver.observe(element);
    }

    await Promise.race([document.fonts.ready, wait(1200)]);
    relayout();
    root.classList.add('is-in');

    if (reduced()) {
      lit.style.clipPath = 'inset(0 0 0 0)';
      introDone = true;
      goTo(restingSpot(scene) ?? null);
      return;
    }
    // La réponse finit de s'écrire, puis le curseur sélectionne le mot.
    await wait(2700);
    await select();
    introDone = true;
    if (!here && !trip) goTo(restingSpot(scene) ?? null);
    await wait(500);
    if (scene === 'hero' && !heroOpen) showKey();
  }

  start();
})();
