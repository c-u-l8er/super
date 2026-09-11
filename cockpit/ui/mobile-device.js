// Where a person finds out that a phone can read this runtime, and how to let
// one. Until this page existed the answer lived only in mobile/README.md, so
// the feature was effectively undiscoverable from inside the app.
//
// Everything here is presentation. The page states no runtime fact it has not
// been given: live observer status is not delivered to the webview, whose CSP
// allows `connect-src ipc:` only, so the page says so rather than guessing.
// The last status seen, so a frame re-render draws what is known instead of
// blanking the region until the next poll.
let last = null;

const groupsOf = code => String(code).split('\n');

const SVG = 'http://www.w3.org/2000/svg';

const ago = (at, now) => {
  const sec = Math.max(0, Math.round((now - at) / 1000));
  if (sec < 10) return 'just now';
  if (sec < 60) return `${sec}s ago`;
  if (sec < 3600) return `${Math.round(sec / 60)}m ago`;
  return `${Math.round(sec / 3600)}h ago`;
};
const KIND = {app: 'Super Mobile', browser: 'A browser', other: 'A device', unknown: 'A device'};

/**
 * The phones and browsers holding a session right now.
 *
 * Each is named by an identifier the gateway derived from its session one way,
 * which is enough to tell two apart and not enough to be one. "Last read" is
 * the fact worth showing: a paired device that is not reading is not watching.
 */
// The page is rebuilt each frame and `paint` is shared by the renderer and the
// poll, so the invoke handle is parked here rather than threaded through both.
let ask = null;

function devicesNode(node, list) {
  const section = node('section', undefined, 'mobile-devices');
  section.append(node('h2', list.length ? `Connected · ${list.length}` : 'Connected'));
  if (!list.length) {
    section.append(node('p', 'No device is paired. A phone appears here the moment it pairs, and stays for its eight hours unless the observer restarts.', 'empty'));
    return section;
  }
  const now = Date.now();
  const rows = node('ul', undefined, 'mobile-device-list');
  for (const device of list) {
    const row = node('li', undefined, 'mobile-device');
    const fresh = now - Number(device.last_seen ?? 0) < 15000;
    row.append(node('span', '', 'mobile-device-dot ' + (fresh ? 'mobile-state-on' : 'mobile-state-idle')));
    const copy = node('span', undefined, 'mobile-device-copy');
    copy.append(
      node('span', `${KIND[device.kind] ?? KIND.unknown} · ${device.id}`, 'mobile-device-name'),
      node('span', `paired ${ago(Number(device.paired_at), now)} · last read ${ago(Number(device.last_seen), now)}`, 'mobile-device-when'));
    row.append(copy);
    rows.append(row);
  }
  section.append(rows);
  section.append(node('p', 'Each holds a read-only session. Restarting the observer ends every one of them.', 'mobile-code-note'));
  return section;
}

/**
 * The code as a scannable square.
 *
 * Drawn here from a matrix rather than accepting an image or markup from the
 * host, so nothing crosses the boundary that could be injected. Black on white
 * whatever the theme: a scanner needs the contrast, not the palette.
 */
function qrNode(qr) {
  const {width, modules} = qr;
  const quiet = 4, size = width + quiet * 2;
  const svg = document.createElementNS(SVG, 'svg');
  svg.setAttribute('viewBox', `0 0 ${size} ${size}`);
  svg.setAttribute('role', 'img');
  svg.setAttribute('aria-label', 'Pairing code as a scannable square');
  svg.classList.add('mobile-qr');
  const bg = document.createElementNS(SVG, 'rect');
  bg.setAttribute('width', String(size));
  bg.setAttribute('height', String(size));
  bg.setAttribute('fill', '#ffffff');
  const path = document.createElementNS(SVG, 'path');
  let d = '';
  for (let y = 0; y < width; y += 1) {
    for (let x = 0; x < width; x += 1) {
      if (modules[y * width + x] === '1') d += `M${x + quiet} ${y + quiet}h1v1h-1z`;
    }
  }
  path.setAttribute('d', d);
  path.setAttribute('fill', '#000000');
  svg.append(bg, path);
  return svg;
}

/** Copies the code without its reading spaces: the browser observer only trims. */
function copyButton(node, code) {
  const button = node('button', 'Copy code', 'mobile-copy');
  button.type = 'button';
  let restore = null;
  button.addEventListener('click', async () => {
    const plain = String(code).replace(/\s+/g, '');
    let done = false;
    try { await navigator.clipboard.writeText(plain); done = true; } catch { done = false; }
    if (!done) {
      // Older webviews refuse the async clipboard outside a secure context.
      const hidden = document.createElement('textarea');
      hidden.value = plain; hidden.setAttribute('readonly', '');
      hidden.style.position = 'fixed'; hidden.style.opacity = '0';
      document.body.append(hidden); hidden.select();
      try { done = document.execCommand('copy'); } catch { done = false; }
      hidden.remove();
    }
    button.textContent = done ? 'Copied' : 'Press Ctrl C to copy';
    clearTimeout(restore);
    restore = setTimeout(() => { button.textContent = 'Copy code'; }, 2000);
  });
  return button;
}

/** The parts that change every second, without rebuilding the QR each tick. */
function tickParts(region, status) {
  const left = Number(status.seconds_left) || 0;
  const note = region.querySelector('.mobile-code-note');
  if (note) note.textContent = `One use · ${Math.floor(left / 60)}m ${String(left % 60).padStart(2, '0')}s left`;
  const fill = region.querySelector('.mobile-bar-fill');
  if (fill) fill.style.width = `${Math.max(0, Math.min(100, (left / 600) * 100))}%`;
}

/**
 * Fills the live region. Shared by the renderer and the poll, so both agree.
 *
 * A full redraw only when the state actually changed; otherwise the countdown
 * is patched in place. Rebuilding each second would throw away the QR and wipe
 * the copy button's confirmation while someone was reading it.
 */
function paint(region, node, status) {
  const fingerprint = (status?.devices ?? []).map(d => `${d.id}:${d.last_seen}`).join(',');
  const signature = status ? `${status.enabled}|${status.alive}|${status.code ?? status.reason}|${fingerprint}` : 'none';
  if (region.dataset.mobileSignature === signature) { if (status?.code) tickParts(region, status); return; }
  region.dataset.mobileSignature = signature;
  region.replaceChildren();
  if (!status) { region.append(node('p', 'Checking…', 'empty')); return; }
  if (!status.enabled) {
    region.append(
      node('p', 'Not running', 'mobile-state mobile-state-off'),
      node('p', 'This copy of Super was started without the companion. Use the command below and a code will appear here.'));
    return;
  }
  const paired = Array.isArray(status.devices) ? status.devices : [];
  region.append(node('p',
    !status.alive ? 'Started, but its observer has stopped'
      : paired.length ? `Running · ${paired.length} connected`
      : 'Running · waiting for a phone',
    'mobile-state ' + (status.alive ? 'mobile-state-on' : 'mobile-state-off')));
  region.append(devicesNode(node, paired));
  if (!status.code) {
    const why = {expired: 'That code expired. Ten minutes is the whole of its life.',
      used: 'That code has been used — a code is good for one device.',
      'no-code': 'No code has been written yet.',
      unreadable: 'The pairing file could not be read.',
      unrecognised: 'The pairing file does not hold a code this observer wrote.'}[status.reason]
      ?? 'No code is available.';
    region.append(node('p', why, 'mobile-code-note'));
    // Spent and expired are the two states a person can act on from here, and
    // until this button existed the only way out of either was restarting
    // Super — which revokes every other session to issue one code.
    if (status.alive && (status.reason === 'used' || status.reason === 'expired')) {
      region.append(newCodeButton(node));
      region.append(node('p',
        'A new code lets one more device pair. It does not disconnect anything already connected.',
        'availability-note'));
    }
    return;
  }
  const pair = node('div', undefined, 'mobile-pair');
  const left = node('div', undefined, 'mobile-pair-code');
  const code = node('div', undefined, 'mobile-code');
  for (const line of String(status.code).split('\n')) code.append(node('span', line, 'mobile-code-line'));
  left.append(code, copyButton(node, status.code));
  pair.append(left);
  if (status.qr) {
    const square = node('div', undefined, 'mobile-pair-qr');
    square.append(qrNode(status.qr), node('p', 'Scan this with Super on your phone', 'mobile-qr-note'));
    pair.append(square);
  }
  region.append(pair);
  region.append(node('p', '', 'mobile-code-note'));
  const bar = node('div', undefined, 'mobile-bar');
  bar.append(node('div', undefined, 'mobile-bar-fill'));
  region.append(bar);
  tickParts(region, status);
}

/**
 * Asks the companion for a fresh code.
 *
 * Disabled while the request is in flight and while the code it produced is
 * still unspent, because pressing it again would replace a code someone may be
 * halfway through typing.
 */
function newCodeButton(node) {
  const button = node('button', 'New pairing code', 'mobile-new-code');
  button.type = 'button';
  button.onclick = async () => {
    if (!ask || button.disabled) return;
    button.disabled = true;
    button.textContent = 'Asking…';
    let outcome = null;
    try { outcome = await ask('mobile_new_code'); } catch { outcome = null; }
    if (!outcome?.ok) {
      button.disabled = false;
      button.textContent = 'New pairing code';
      const region = document.querySelector('[data-mobile-status]');
      if (region) region.append(node('p',
        'The companion did not answer. It may have stopped; the page will say so within a second.',
        'availability-note'));
    }
    // On success the poll redraws this region the moment the code lands, so
    // the button goes away with the state that offered it.
  };
  return button;
}

/**
 * Polls the companion's state once a second and patches the live region in
 * place. Patching rather than re-rendering, because the page is rebuilt on
 * every frame and a full redraw each second would fight it.
 */
export function initMobileDevice(invoke, node) {
  ask = invoke;
  const tick = async () => {
    try { last = await invoke('mobile_status'); } catch { last = null; return; }
    const region = document.querySelector('[data-mobile-status]');
    if (region) paint(region, node, last);
  };
  void tick();
  setInterval(() => { if (document.querySelector('[data-mobile-status]')) void tick(); }, 1000);
}

export function mobileDevice({node, panel, card}) {
  const page = panel('mobile');
  page.append(node('p', 'Scope: this machine', 'scope-note'));
  page.append(node('p',
    'Super Mobile is a companion view of this runtime on your phone, over your own private network. It reads. It cannot approve, merge, deploy, run a command, or act for you — the companion is given a selected projection and no control channel at all.',
    'overview-card'));

  const stats = node('div', undefined, 'stats-grid');
  stats.append(
    card('Access', 'Read-only', 'No mutation operation is exposed'),
    card('Pairing code', 'One use', 'Expires ten minutes after the observer mints it'),
    card('Session', '8 hours', 'Restarting the observer revokes every session'));
  page.append(stats);

  const live = node('section', undefined, 'mobile-live');
  live.append(node('h2', 'This machine'));
  const region = node('div');
  region.dataset.mobileStatus = '';
  paint(region, node, last);
  live.append(region);
  page.append(live);

  const list = (title, intro, items, cls) => {
    const s = node('section');
    s.append(node('h2', title));
    if (intro) s.append(node('p', intro));
    const ul = node('ul', undefined, cls);
    for (const item of items) ul.append(node('li', item));
    s.append(ul);
    page.append(s);
    return s;
  };

  const steps = node('section');
  steps.append(node('h2', 'Pair a phone'));
  steps.append(node('p', 'The companion is opt-in and starts with the desktop. Run this from the Super repository, and the code appears on this page:'));
  const commands = node('ol', undefined, 'mobile-steps');
  for (const [what, command] of [
    ['Start Super with the companion', './mobile/start-local.sh'],
    ['Or also show the code in its own window, for a second screen', 'SUPER_MOBILE_PANEL=1 ./mobile/start-local.sh'],
  ]) {
    const li = node('li');
    li.append(node('span', what, 'mobile-step-what'), node('code', command, 'mobile-command'));
    commands.append(li);
  }
  steps.append(commands);
  steps.append(node('p', 'Then open the companion on the phone, go to its Host tab, and type the code. The window shows it in four-character groups; the spaces are only to read by.'));
  page.append(steps);

  list('What the phone can see',
    'A selected projection of this runtime, withdrawn the moment it goes stale:',
    ['Development tasks and their revisions',
     'Workspaces, goals and lanes',
     'Bots and workers',
     'Nothing older than three seconds — a stale observation is withdrawn, not shown'],
    'mobile-list');

  list('What it can never do',
    'Not a setting, and not a permission you can grant it. These operations are absent from the companion:',
    ['Approve, merge or deploy anything',
     'Run a command or open a terminal',
     'Change grants, capabilities or authority',
     'Reach your provider credentials'],
    'mobile-list');

  page.append(node('p',
    'The code above is read from the observer\u2019s own file each second and is never stored by this page. A phone that pairs with it receives a read-only projection and no control channel.',
    'availability-note'));
  return page;
}
