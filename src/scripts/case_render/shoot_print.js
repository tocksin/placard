// shoot_print.js - renders of the 3D-printed case (gen_case_print.py --mesh mesh, gen_case.py --mesh mesh
// for the board's parts).  Serve this folder on port 8765, then: node shoot_print.js [view ...]
// Writes out/print_*.png.  Date: 2026-11-16
const {chromium} = require('playwright');
const fs = require('fs');
const B = JSON.parse(fs.readFileSync('mesh/board.json'));
const L = JSON.parse(fs.readFileSync(process.env.PRINT_LAYOUT || '../../../case/print/print_layout.json'));
const W = B.W, D = B.D;
const BODY = '#3b3f45', TOP = '#b9d6ea', COVER = '#23252a', STRAP = '#c9a227';
const quad = n => [n.includes('left') && !n.includes('wall_left') ? -1 : 1, n.includes('front') ? -1 : 1];

function caseItems(o) {              // o: explode distances {floor, straps, walls, top, covers, spread}, hide: [..]
  const it = [], sp = o.spread || 0, hide = o.hide || [];
  const add = (name, c, off, extra = {}) => { if (!hide.some(h => name.startsWith(h))) it.push({f: 'mesh/print_' + name + '.stl', c, o: off, ...extra}); };
  for (const q of ['front_left', 'front_right', 'back_left', 'back_right']) {
    const sx = q.includes('left') ? -1 : 1, sy = q.includes('front') ? -1 : 1;
    add('floor_' + q, BODY, [sx * sp, sy * sp, -(o.floor || 0)]);
    add('top_' + q, o.topColor || TOP, [sx * sp, sy * sp, o.top || 0], {a: o.topAlpha ?? 0.55, ec: '#4d7fa3', r: 0.25});
  }
  for (let i = 1; i <= L.straps.length; i++) add('floor_strap_' + i, STRAP, [0, 0, -(o.straps || 0)]);
  const w = o.walls || 0;
  for (const [n, off] of [['wall_front_left', [-sp, -w, 0]], ['wall_front_right', [sp, -w, 0]], ['wall_back_left', [-sp, w, 0]],
      ['wall_back_right', [sp, w, 0]], ['wall_left_front', [-w, -sp, 0]], ['wall_left_back', [-w, sp, 0]],
      ['wall_right_front', [w, -sp, 0]], ['wall_right_back', [w, sp, 0]]]) add(n, o.wallColor || BODY, off);
  for (const n of (o.coverList || ['slot_cover_1', 'slot_cover_2', 'slot_cover_3', 'slot_cover_4', 'cart_cover']))
    add(n, COVER, [0, 0, o.covers || 0]);
  return it;
}
function boardItems() {
  const colors = {J7: '#9aa0a6', J13: '#b0b4b8', J6: '#222222', J5: '#5a5f66', J8: '#1a1a1a', J9: '#222', J10: '#222', J11: '#222',
                  J12: '#222', J2: '#555a60', J3: '#555a60', SW1: '#b0b4b8', SW2: '#222', J4: '#b0b4b8'};
  const it = [];
  for (const ref of B.models) {
    const c = colors[ref] || (/^U/.test(ref) ? '#1c1c1e' : /^C/.test(ref) ? '#b8893a' : /^R/.test(ref) ? '#c9b48a' : '#444');
    it.push({f: 'mesh/model_' + ref + '.stl', c, e: false});
  }
  it.push({f: 'mesh/standoffs.stl', c: '#d4c08a', m: 0.8, r: 0.3, e: false});
  return it;
}
const board = [{b: [B.OFF, W - B.OFF, B.OFF, D - B.OFF, -1.6, 0], c: '#1f6b45'}];
const ctr = [W / 2, D / 2, 5];
const views = {
  print_assembled: {cam: [-250, -340, 290], look: ctr, items: [...caseItems({}), ...boardItems()], boxes: board},
  print_assembled_rear: {cam: [520, 560, 300], look: ctr, items: [...caseItems({}), ...boardItems()], boxes: board},
  print_exploded: {cam: [-430, -560, 470], look: [W / 2, D / 2, 0], fov: 32,
    items: [...caseItems({floor: 55, straps: 95, walls: 55, top: 75, covers: 120, spread: 10, topAlpha: 0.8}), ...boardItems()], boxes: board},
  print_exploded_rear: {cam: [560, 640, 430], look: [W / 2, D / 2, 0], fov: 32,
    items: [...caseItems({floor: 55, straps: 95, walls: 55, top: 75, covers: 120, spread: 10, topAlpha: 0.8}), ...boardItems()], boxes: board},
  print_underside: {cam: [-120, -330, -330], look: [W / 2, D / 2, -5], fov: 30, items: caseItems({coverList: []})},
  print_inside: {cam: [40, -60, 190], look: [215, 185, 0], fov: 34,
    items: [...caseItems({hide: ['top_', 'slot_cover', 'cart_cover']}), ...boardItems()], boxes: board},
  print_joints: {cam: [150, 60, 105], look: [262, 205, 8], fov: 30,
    items: [...caseItems({hide: ['top_', 'slot_cover', 'cart_cover'], wallColor: '#5b616a'})]},
};
// every piece as it lies on the bed
{
  const rows = [['floor_front_left', 'floor_front_right'], ['floor_back_left', 'floor_back_right'],
    ['top_front_left', 'top_front_right'], ['top_back_left', 'top_back_right'],
    ['wall_front_left', 'wall_front_right', 'wall_left_front'], ['wall_back_left', 'wall_back_right', 'wall_left_back'],
    ['wall_right_front', 'wall_right_back', 'slot_cover', 'cart_cover', 'floor_strap']];
  const size = Object.fromEntries(L.pieces.map(p => [p.name, p.size]));
  const it = []; let y = 0;
  const cols = [[0, 1], [2, 3], [4, 5, 6]];
  let x0 = 0;
  for (const col of cols) {
    let yy = 0, wmax = 0;
    for (const r of col) { let x = x0, h = 0;
      for (const n of rows[r]) { const s = size[n];
        it.push({f: 'mesh/bed/' + n + '.stl', c: n.startsWith('top') ? '#9fc3dc' : n.includes('cover') ? '#4a4d53' : n.includes('strap') ? STRAP : '#5b616a', o: [x, yy, 0]});
        x += s[0] + 12; h = Math.max(h, s[1]); }
      wmax = Math.max(wmax, x - x0); yy += h + 14; }
    x0 += wmax + 10;
  }
  views.print_bed = {cam: [380, -520, 620], look: [470, 150, 0], fov: 36, items: it, w: 2000, h: 1100};
}
(async () => {
  const b = await chromium.launch({args: ['--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader']});
  const p = await b.newPage({viewport: {width: 1600, height: 1000}});
  p.on('console', m => { if (m.type() === 'error') console.log('ERR', m.text()); });
  p.on('pageerror', e => console.log('PAGEERR', e.message));
  for (const [name, v] of Object.entries(views)) {
    if (process.argv[2] && !process.argv.slice(2).includes(name)) continue;
    await p.setViewportSize({width: v.w || 1600, height: v.h || 1000});
    await p.goto('http://localhost:8765/render_print.html?v=' + encodeURIComponent(JSON.stringify(v)));
    await p.waitForFunction('window.done===true', null, {timeout: 240000});
    await p.screenshot({path: 'out/' + name + '.png'});
    console.log('ok', name);
  }
  await b.close();
})();
