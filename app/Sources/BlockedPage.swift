// 분산 사이트 탭이 바뀌어 오는 차단 페이지. 앱의 로컬 서버가 /blocked 로 내려준다.
// 원래 주소는 # 뒤에 인코딩돼 있다.

let blockedPageHTML = #"""
<!doctype html>
<html lang="ko">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>집중 중 — 차단됨</title>
<style>
  :root { --bg:#faf8f6; --card:#fff; --text:#1d1d1f; --muted:#6e6e73; --line:#e6e2de; --focus:#d64545; --break:#2f9e6b; }
  @media (prefers-color-scheme: dark) { :root { --bg:#17171a; --card:#222226; --text:#f2f2f4; --muted:#9b9ba3; --line:#34343a; } }
  * { box-sizing: border-box; }
  body { margin:0; min-height:100vh; display:flex; align-items:center; justify-content:center; padding:16px;
         background:var(--bg); color:var(--text); font:15px/1.5 -apple-system, "Apple SD Gothic Neo", system-ui, sans-serif; }
  .card { background:var(--card); border:1px solid var(--line); border-radius:16px; max-width:460px; width:100%; text-align:center; padding:32px 24px; }
  h1 { margin:8px 0; font-size:24px; }
  .big { font-size:48px; font-weight:700; font-variant-numeric:tabular-nums; color:var(--focus); }
  .muted { color:var(--muted); }
  label { display:block; text-align:left; font-size:13px; font-weight:600; color:var(--muted); margin:18px 0 6px; }
  input { font:inherit; width:100%; padding:10px 12px; border-radius:10px; border:1px solid var(--line); background:var(--bg); color:var(--text); }
  .hint { text-align:left; font-size:13px; min-height:20px; margin-top:4px; color:var(--break); }
  .hint.err { color:var(--focus); }
  a.btn { display:inline-block; margin-top:12px; padding:10px 16px; border-radius:10px; background:var(--break); color:#fff; text-decoration:none; font-weight:600; }
  .url { word-break:break-all; font-size:12px; margin-top:18px; }
  .hidden { display:none; }
</style>
</head>
<body>
<div class="card">
  <div style="font-size:44px">🍅</div>
  <div id="focusView">
    <h1>지금은 집중 시간이에요</h1>
    <div id="left" class="big">--:--</div>
    <p class="muted">남은 시간. 끝나면 마음껏 보세요.</p>
    <p id="task" style="font-weight:600"></p>
    <label for="later">💭 뭔가 찾아보려던 거라면, 적어두고 나중에 해요</label>
    <input id="later" placeholder="그 강의 영상 다시 보기 (Enter)" maxlength="120" autocomplete="off">
    <div id="hint" class="hint"></div>
    <p class="muted" style="margin-top:16px">⌘W로 이 탭을 닫고 공부로 돌아가요.</p>
  </div>
  <div id="offlineView" class="hidden">
    <h1>앱과 연결할 수 없어요</h1>
    <p class="muted">Focus Guard가 켜져 있는지 확인해 주세요. 연결되면 자동으로 다시 보여드려요.</p>
  </div>
  <div id="doneView" class="hidden">
    <h1>집중 시간이 끝났어요</h1>
    <p class="muted">이제 원래 페이지로 갈 수 있어요.</p>
    <a id="go" class="btn" href="#">원래 페이지 열기</a>
  </div>
  <p id="url" class="url muted"></p>
</div>
<script>
  const $ = (id) => document.getElementById(id);
  let original = '';
  try { original = decodeURIComponent(location.hash.slice(1)); } catch {}
  if (!/^https?:\/\//.test(original)) original = '';
  $('url').textContent = original ? '차단된 주소: ' + original : '';
  $('go').href = original || 'about:blank';

  // view: 'loading' | 'offline' | 'blocking' | 'done' — 응답을 받기 전엔 끝났다고 보여주지 않는다
  let st = null, view = 'loading', fetchedAt = 0;
  const clock = (s) => { s = Math.max(0, s); return String(Math.floor(s / 60)).padStart(2, '0') + ':' + String(s % 60).padStart(2, '0'); };

  function render() {
    $('focusView').classList.toggle('hidden', view !== 'blocking');
    $('offlineView').classList.toggle('hidden', view !== 'offline');
    $('doneView').classList.toggle('hidden', view !== 'done');
    if (view !== 'blocking') return;
    const left = st.paused ? st.remainingSec : st.remainingSec - Math.round((Date.now() - fetchedAt) / 1000);
    $('left').textContent = clock(left) + (st.paused ? ' (일시정지)' : '');
    $('task').textContent = st.task ? '📌 지금 할 일: ' + st.task : '';
  }

  async function refresh() {
    try {
      const res = await fetch('/status');
      if (!res.ok) throw new Error(res.status);
      const s = await res.json();
      if (typeof s.block !== 'boolean') throw new Error('bad status');
      st = s; fetchedAt = Date.now();
      view = s.block ? 'blocking' : 'done';
    } catch {
      view = 'offline';
    }
    render();
  }

  $('later').addEventListener('keydown', async (e) => {
    if (e.key !== 'Enter' || e.isComposing) return;
    const text = $('later').value.trim();
    if (!text) return;
    const hint = $('hint');
    try {
      const res = await fetch('/later', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ text }) });
      if (!res.ok) throw new Error(res.status);
      $('later').value = '';
      hint.className = 'hint';
      hint.textContent = '✓ 적어뒀어요. 정리 시간에 다시 보여드릴게요.';
    } catch {
      hint.className = 'hint err';
      hint.textContent = '저장하지 못했어요. 적은 내용은 그대로 두었어요.';
    }
  });

  refresh();
  setInterval(render, 1000);
  setInterval(refresh, 5000);
</script>
</body>
</html>
"""#
