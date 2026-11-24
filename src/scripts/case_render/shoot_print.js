// shoot_print.js - renders of the 3D-printed case (gen_case_print.py --mesh mesh, gen_case.py --mesh mesh
// for the board's parts).  node shoot_print.js [view ...]   (needs three in web/node_modules: cd web && npm install three)
// The page's files are handed to the browser straight from this folder, so no web server is needed.
// Writes out/print_*.png.  Date: 2026-11-24
const {chromium} = require('playwright');
const fs = require('fs');
const B = JSON.parse(fs.readFileSync('mesh/board.json'));
const L = JSON.parse(fs.readFileSync(process.env.PRINT_LAYOUT || '../../../case/print/print_layout.json'));
const W = B.W, D = B.D;
const BODY = '#3b3f45', TOP = '#b9d6ea', COVER = '#23252a', STRAP = '#c9a227';

function caseItems(o) {              // o: explode distances {floor, walls, top, covers, spread}, hide: [..]
  const it = [], sp = o.spread || 0, hide = o.hide || [];
  const add = (name, c, off, extra = {}) => { if (!hide.some(h => name.startsWith(h))) it.push({f: 'mesh/print_' + name + '.stl', c, o: off, ...extra}); };
  for (const [q, sx] of [['left', -1], ['right', 1]]) {
    add('floor_' + q, BODY, [sx * sp, 0, -(o.floor || 0)]);
    add('top_' + q, o.topColor || TOP, [sx * sp, 0, o.top || 0], {a: o.topAlpha ?? 0.55, ec: '#2f5f85', r: 0.25});
  }
  const w = o.walls || 0;
  for (const [n, off] of [['wall_front', [0, -w, 0]], ['wall_back', [0, w, 0]], ['wall_left', [-w, 0, 0]], ['wall_right', [w, 0, 0]]])
    add(n, o.wallColor || BODY, off);
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
    items: [...caseItems({floor: 55, walls: 55, top: 75, covers: 120, spread: 10, topAlpha: 0.8}), ...boardItems()], boxes: board},
  print_exploded_rear: {cam: [560, 640, 430], look: [W / 2, D / 2, 0], fov: 32,
    items: [...caseItems({floor: 55, walls: 55, top: 75, covers: 120, spread: 10, topAlpha: 0.8}), ...boardItems()], boxes: board},
  print_underside: {cam: [-120, -330, -330], look: [W / 2, D / 2, -5], fov: 30, items: caseItems({coverList: []})},
  print_inside: {cam: [40, -60, 190], look: [215, 185, 0], fov: 34,
    items: [...caseItems({hide: ['top_', 'slot_cover', 'cart_cover']}), ...boardItems()], boxes: board},
  print_joints: {cam: [150, 60, 105], look: [262, 205, 8], fov: 30,
    items: [...caseItems({hide: ['top_', 'slot_cover', 'cart_cover'], wallColor: '#5b616a'})]},
  print_corner: {cam: [-95, -120, 75], look: [12, 10, 8], fov: 26,
    items: [...caseItems({hide: ['top_', 'slot_cover', 'cart_cover', 'wall_front'], wallColor: '#5b616a'}),
            {f: 'mesh/print_wall_front.stl', c: '#8a929c', o: [0, -22, 0]}]},
  print_seams: {cam: [60, -150, 330], look: [160, 105, 0], fov: 30,
    items: [{f: 'mesh/print_top_left.stl', c: '#9fc3dc', o: [-6, 0, 0]}, {f: 'mesh/print_top_right.stl', c: '#b9d6ea', o: [6, 0, 0]}]},
  // a floor catch and its stop block, with the right wall pulled 16 mm out to show the window in its flange
  print_catch: {cam: [236, 168, 34], look: [291, 196, -6], fov: 26,
    items: [...caseItems({hide: ['top_', 'slot_cover', 'cart_cover', 'wall_right'], wallColor: '#5b616a'}),
            {f: 'mesh/print_wall_right.stl', c: '#8a929c', o: [16, 0, 0]}]},
  // the top from below: its pegs, and the walls' lugs they drop into
  print_pegs: {cam: [470, -150, -175], look: [215, 95, 22], fov: 30,
    items: [{f: 'mesh/print_top_left.stl', c: '#9fc3dc', o: [0, 0, 26]}, {f: 'mesh/print_top_right.stl', c: '#b9d6ea', o: [0, 0, 26]},
            {f: 'mesh/print_wall_front.stl', c: '#5b616a', o: [0, 0, 0]}, {f: 'mesh/print_wall_right.stl', c: '#5b616a', o: [0, 0, 0]},
            {f: 'mesh/print_wall_back.stl', c: '#5b616a', o: [0, 0, 0]}, {f: 'mesh/print_wall_left.stl', c: '#5b616a', o: [0, 0, 0]}]},
};
// every piece as it lies on the bed
{
  const cols = [['floor_left', 'floor_right', 'top_left', 'top_right', 'slot_cover', 'cart_cover'],
    ['wall_front', 'wall_back', 'wall_left', 'wall_right', 'dovetail_test', 'snap_test_wall', 'snap_test_floor', 'snap_test_top']];
  const size = Object.fromEntries(L.pieces.map(p => [p.name, p.size]));
  const it = [];
  let y0 = 0;
  for (const [k, col] of cols.entries()) {       // one row of pieces per entry, the rows stacked toward the back
    let x = 0, h = 0;
    for (const n of col) { const s = size[n];
      it.push({f: 'mesh/bed/' + n + '.stl', c: n.startsWith('top') || n === 'snap_test_top' ? '#9fc3dc' : n.includes('cover') ? '#4a4d53' : n.includes('test') ? STRAP : '#5b616a', o: [x, y0, 0]});
      x += s[0] + 14; h = Math.max(h, s[1]); }
    y0 += h + 16;
  }
  views.print_bed = {cam: [380, -560, 760], look: [380, 200, 0], fov: 36, items: it, w: 2000, h: 1100};
}
(async () => {
  const b = await chromium.launch({args: ['--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader']});
  const p = await b.newPage({viewport: {width: 1600, height: 1000}});
  p.on('console', m => { if (m.type() === 'error') console.log('ERR', m.text()); });
  p.on('pageerror', e => console.log('PAGEERR', e.message));
  const mime = {html: 'text/html', js: 'text/javascript', stl: 'model/stl', json: 'application/json'};
  await p.route('http://localhost:8765/**', r => {
    const f = require('path').join(__dirname, decodeURIComponent(new URL(r.request().url()).pathname));
    fs.existsSync(f) ? r.fulfill({body: fs.readFileSync(f), contentType: mime[f.split('.').pop()] || 'application/octet-stream'})
                     : r.fulfill({status: 404, body: ''});
  });
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
