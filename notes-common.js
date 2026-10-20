/* Shared code for notes.html (โน้ตไทย) and staff.html (โน้ตสากล):
   data + song list, notation parsing, synthesised ฆ้อง/ระนาด/ฉิ่ง, and a look-ahead player. */
const NK = (() => {
  const $ = id => document.getElementById(id);
  const esc = s => String(s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
  const store = {
    get(k, d) { try { const v = localStorage.getItem('phlengkhru.' + k); return v == null ? d : JSON.parse(v); } catch { return d; } },
    set(k, v) { try { localStorage.setItem('phlengkhru.' + k, JSON.stringify(v)); } catch {} },
  };

  /* ---------------- notation ---------------- */
  const NOTE = 'ดรมฟซลท';
  const THAI_DIGIT = '๐๑๒๓๔๕๖๗๘๙';

  // A measure token like "-ร4-ม", "ซ่ล", "ทลซร(ล้อ)" → slots.
  // ฺ = octave down, ่ = octave up, digit after a note = คู่ (e.g. 8 = octave pair).
  function parseMeasure(tok) {
    const echo = tok.includes('(ล้อ)');
    tok = tok.replace('(ล้อ)', '');
    const slots = [];
    for (const ch of tok) {
      const last = slots[slots.length - 1];
      const ni = NOTE.indexOf(ch);
      if (ni >= 0) slots.push({ text: ch, deg: ni, oct: 0, pair: 0 });
      else if (ch === '-') slots.push({ text: '-', deg: null });
      else if (/[0-9๐-๙]/.test(ch)) {
        const n = /[0-9]/.test(ch) ? +ch : THAI_DIGIT.indexOf(ch);
        if (last) { last.text += ch; if (last.deg != null) last.pair = n; }
      } else if (ch === 'ฺ') { if (last) { last.text += ch; if (last.deg != null) last.oct = -1; } }
      else if ('ุู่้'.includes(ch)) { if (last) { last.text += ch; if (last.deg != null) last.oct = 1; } }
      else if (ch === '*') { if (last) last.text += ch; }
      else slots.push({ text: ch, deg: null }); // typo letters in the source (e.g. ฃ) sound as rests
    }
    return { slots, echo };
  }

  // Pitch as diatonic steps from C4 (ด = C). On ฆ้องวงใหญ่ the unmarked middle register runs
  // ซ ล ท ด ร ม ฟ (G4–F5), so "-ท-ร" steps up a third rather than down a sixth.
  function stepsOf(slot) {
    if (slot.deg == null) return null;
    return (slot.deg >= 4 ? slot.deg : slot.deg + 7) + 7 * slot.oct;
  }
  // The pitches a slot sounds: the note, plus the lower note of a คู่ (ร4 → ร with ล a fourth below).
  function pitchesOf(slot) {
    const s = stepsOf(slot);
    if (s == null) return [];
    return slot.pair > 1 ? [s, s - (slot.pair - 1)] : [s];
  }

  /* ---------------- song list + routing ---------------- */
  let songs = [], current = null;
  function renderList() {
    const q = $('search').value.trim();
    let html = '', group = null;
    for (const s of songs) {
      if (q && !s.title.includes(q)) continue;
      if (s.group !== group) { group = s.group; html += `<div class="group-h">${esc(group)}</div>`; }
      const dup = s.occurrence > 1 ? ' (ซ้ำ)' : '';
      html += `<button class="song-btn${current && current.id === s.id ? ' active' : ''}" data-id="${s.id}">
        <span class="no">${s.id}</span><span>${esc(s.title)}${dup}</span><span class="pg">น.${s.pages[0]}</span></button>`;
    }
    $('songList').innerHTML = html || '<div class="empty" style="padding:30px 10px">ไม่พบเพลง</div>';
    document.querySelector('.song-btn.active')?.scrollIntoView({ block: 'nearest' });
  }
  function initShell({ onSong }) {
    $('songList').addEventListener('click', e => {
      const b = e.target.closest('.song-btn'); if (!b) return;
      location.hash = 'song=' + b.dataset.id;
      document.body.classList.remove('drawer');
    });
    $('search').addEventListener('input', renderList);
    $('menuBtn').addEventListener('click', () => document.body.classList.add('drawer'));
    $('scrim').addEventListener('click', () => document.body.classList.remove('drawer'));
    const route = () => {
      const m = location.hash.match(/song=(\d+)/);
      current = songs.find(s => s.id === (m ? +m[1] : 0)) || songs[0];
      // keep the same song when switching between โน้ตไทย and โน้ตสากล
      document.querySelectorAll('.views a').forEach(a => { a.href = a.href.split('#')[0] + '#song=' + current.id; });
      renderList();
      window.scrollTo(0, 0);
      onSong(current);
    };
    return fetch('data/phleng-khru-notes.json')
      .then(r => { if (!r.ok) throw new Error(r.status); return r.json(); })
      .then(d => { songs = d.songs; addEventListener('hashchange', route); route(); })
      .catch(() => {
        $('sheet').innerHTML = `<div class="empty">โหลดไฟล์โน้ตไม่ได้<br>เปิดผ่านเซิร์ฟเวอร์ในโฟลเดอร์โปรเจกต์:<br>
          <code>python -m http.server 8765</code><br>แล้วไปที่ <code>http://localhost:8765/${location.pathname.split('/').pop()}</code></div>`;
      });
  }

  /* ---------------- audio: same synthesis as index.html ---------------- */
  let ac = null, master, revIn, noiseBuf, sessDry, sessWet;
  function ensureAudio() {
    if (ac) { ac.resume(); return ac; }
    ac = new (window.AudioContext || window.webkitAudioContext)();
    master = ac.createGain(); master.gain.value = 0.85;
    const comp = ac.createDynamicsCompressor(); comp.threshold.value = -14; comp.ratio.value = 4;
    master.connect(comp); comp.connect(ac.destination);
    const len = ac.sampleRate * 3.4, ir = ac.createBuffer(2, len, ac.sampleRate);
    for (let c = 0; c < 2; c++) { const d = ir.getChannelData(c); for (let i = 0; i < len; i++) d[i] = (Math.random() * 2 - 1) * Math.pow(1 - i / len, 2.6); }
    const conv = ac.createConvolver(); conv.buffer = ir;
    const wet = ac.createGain(); wet.gain.value = 0.38;
    revIn = ac.createGain(); revIn.connect(conv); conv.connect(wet); wet.connect(comp);
    noiseBuf = ac.createBuffer(1, ac.sampleRate * 0.25, ac.sampleRate);
    const nd = noiseBuf.getChannelData(0); for (let i = 0; i < nd.length; i++) nd[i] = Math.random() * 2 - 1;
    newSession();
    return ac;
  }
  // Every playback run gets its own bus so stop/pause can silence notes already scheduled ahead.
  function newSession() {
    if (!ac) return;
    if (sessDry) {
      const t = ac.currentTime, d = sessDry, w = sessWet;
      [d, w].forEach(g => { g.gain.setValueAtTime(g.gain.value, t); g.gain.linearRampToValueAtTime(0, t + 0.04); });
      setTimeout(() => { d.disconnect(); w.disconnect(); }, 200);
    }
    sessDry = ac.createGain(); sessDry.connect(master);
    sessWet = ac.createGain(); sessWet.connect(revIn);
  }
  function out(node, dry = 1, wet = 1) {
    const a = ac.createGain(); a.gain.value = dry; node.connect(a); a.connect(sessDry);
    const b = ac.createGain(); b.gain.value = wet; node.connect(b); b.connect(sessWet);
  }
  function partial(dest, f, amp, dec, t) {
    const o = ac.createOscillator(), g = ac.createGain();
    o.frequency.value = f;
    g.gain.setValueAtTime(0, t); g.gain.linearRampToValueAtTime(amp, t + 0.003);
    g.gain.exponentialRampToValueAtTime(0.0001, t + dec);
    o.connect(g); g.connect(dest); o.start(t); o.stop(t + dec + 0.05);
  }
  function noiseHit(dest, t, freq, q, amp, dec, type = 'bandpass') {
    const s = ac.createBufferSource(); s.buffer = noiseBuf;
    const f = ac.createBiquadFilter(); f.type = type; f.frequency.value = freq; f.Q.value = q;
    const g = ac.createGain(); g.gain.setValueAtTime(amp, t); g.gain.exponentialRampToValueAtTime(0.0001, t + dec);
    s.connect(f); f.connect(g); g.connect(dest); s.start(t); s.stop(t + dec + 0.02);
  }
  function ranat(f, t, vel) {
    const bus = ac.createGain(); bus.gain.value = 0.3 * vel; out(bus, 1, 0.9);
    partial(bus, f, 1, 0.75, t);
    partial(bus, f * 2.01, 0.18, 0.35, t);
    partial(bus, f * 2.76, 0.32, 0.22, t);
    partial(bus, f * 5.4, 0.12, 0.08, t);
    noiseHit(bus, t, 2600, 1.2, 0.35, 0.025);
  }
  function gong(f, t, vel) {
    f /= 2;
    const bus = ac.createGain(); bus.gain.value = 0.22 * vel; out(bus, 1, 1.1);
    partial(bus, f, 1, 2.6, t); partial(bus, f + 1.6, 0.6, 2.4, t);
    partial(bus, f * 2.02, 0.25, 1.4, t); partial(bus, f * 3.0, 0.08, 0.7, t);
    noiseHit(bus, t, 1400, 1.5, 0.12, 0.02);
  }
  function ching(t, open) {
    const bus = ac.createGain(); bus.gain.value = open ? 0.06 : 0.05; out(bus, 1, 0.7);
    if (open) [2730, 3905, 5190, 6620].forEach((f, j) => partial(bus, f, 1 / (j + 1), 1.4 - j * 0.2, t));
    else { partial(bus, 2730, 0.6, 0.06, t); noiseHit(bus, t, 6000, 0.8, 0.9, 0.05); }
  }
  // Thai 7-tone equal temperament (ด5 ≈ 290 Hz, as in index.html), or 12-TET C major for comparison.
  const MAJOR = [0, 2, 4, 5, 7, 9, 11];
  function freqOf(s, tuning) {
    if (tuning === 'western') {
      const o = Math.floor(s / 7), midi = 48 + 12 * o + MAJOR[s - 7 * o];
      return 440 * Math.pow(2, (midi - 69) / 12);
    }
    return 290 * Math.pow(2, (s - 7) / 7);
  }
  function playNote(s, t, vel = 1) {
    const f = freqOf(s, $('tuning')?.value);
    ($('inst').value === 'ranat' ? ranat : gong)(f, t, vel);
  }

  /* ---------------- player ----------------
     events: [{ at (in measures from the start), pitches: [steps], vel, ... }] sorted by `at`.
     The ching sounds on the last quarter of every 2nd measure, alternating ฉิ่ง / ฉับ. */
  function createPlayer({ onVisual, onStop }) {
    let evs = [], total = 0, playing = false, i = 0, chingM = 0, timer = null, raf = 0, visQ = [], shown = null;
    let anchorAt = 0, anchorTime = 0, mdAnchor = 1;
    const tempo = () => +$('tempo').value;            // ห้องต่อนาที
    const timeOf = at => anchorTime + (at - anchorAt) * mdAnchor;

    function tick() {
      const horizon = ac.currentTime + 0.2;
      while (playing) {
        const nextEv = i < evs.length ? evs[i].at : Infinity;
        const nextCh = chingM < total ? chingM + 0.75 : Infinity;
        if (nextEv === Infinity && nextCh === Infinity) {
          if ($('loop').checked && evs.length) {
            anchorTime = timeOf(total); anchorAt = 0; i = 0; chingM = 0;
            continue;
          }
          playing = false; clearInterval(timer);
          const left = timeOf(total) - ac.currentTime;
          setTimeout(() => { if (!playing) stop(); }, Math.max(0, left * 1000) + 400);
          break;
        }
        const at = Math.min(nextEv, nextCh), t = timeOf(at);
        if (t > horizon) break;
        if (nextCh <= nextEv) {
          if ($('ching').checked && chingM % 2 === 1) ching(t, (chingM >> 1) % 2 === 0);
          chingM++;
        } else {
          const ev = evs[i++];
          ev.pitches.forEach(s => playNote(s, t, ev.vel ?? 1));
          visQ.push({ t, ev });
        }
      }
    }
    function draw() {
      raf = requestAnimationFrame(draw);
      let item = null;
      while (visQ.length && visQ[0].t <= ac.currentTime) item = visQ.shift();
      if (item && item.ev !== shown) { onVisual(item.ev, shown); shown = item.ev; }
    }
    function play(from = null) {
      if (!evs.length) return;
      ensureAudio();
      if (from != null) { stop(); i = from; }
      if (i >= evs.length) i = 0;
      const startAt = evs[i].at;
      chingM = Math.floor(startAt + 0.25);
      mdAnchor = 60 / tempo(); anchorAt = startAt; anchorTime = ac.currentTime + 0.08;
      playing = true; visQ = [];
      clearInterval(timer); timer = setInterval(tick, 25); tick();
      cancelAnimationFrame(raf); raf = requestAnimationFrame(draw);
      $('playBtn').textContent = '❚❚ พัก';
    }
    function pause() {
      playing = false; clearInterval(timer);
      // resume from the event currently sounding, not the look-ahead pointer
      if (shown) i = evs.indexOf(shown);
      visQ = []; newSession();
      $('playBtn').textContent = '▶ เล่นต่อ';
    }
    function stop() {
      playing = false; clearInterval(timer); cancelAnimationFrame(raf);
      visQ = []; i = 0;
      if (shown) onVisual(null, shown);
      shown = null;
      newSession();
      $('playBtn').textContent = '▶ เล่น';
      onStop?.();
    }
    function load(events, totalMeasures) { stop(); evs = events; total = totalMeasures; }
    $('playBtn').addEventListener('click', () => playing ? pause() : play());
    $('stopBtn').addEventListener('click', stop);
    document.addEventListener('keydown', e => {
      if (e.code === 'Space' && !/INPUT|SELECT|TEXTAREA/.test(e.target.tagName)) { e.preventDefault(); playing ? pause() : play(); }
    });
    // A new tempo takes over from the current position without a jump.
    $('tempo').addEventListener('input', () => {
      $('tempoVal').textContent = tempo() + ' ห้อง/นาที';
      store.set('tempo', tempo());
      if (playing) {
        const now = ac.currentTime;
        anchorAt += (now - anchorTime) / mdAnchor; anchorTime = now; mdAnchor = 60 / tempo();
      }
    });
    return { load, play, pause, stop, get playing() { return playing; } };
  }

  // Restore and persist the transport settings both pages share.
  function initControls() {
    $('tempo').value = store.get('tempo', 90);
    $('tempoVal').textContent = $('tempo').value + ' ห้อง/นาที';
    for (const id of ['inst', 'tuning']) {
      const el = $(id); if (!el) continue;
      el.value = store.get(id, el.value);
      el.addEventListener('change', () => store.set(id, el.value));
    }
  }

  return { $, esc, store, parseMeasure, stepsOf, pitchesOf, initShell, initControls, createPlayer };
})();
