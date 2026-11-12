// Pure replay tests: no browser or capture process is started.
import assert from 'node:assert/strict';
import {Tape, TermView} from './term.js';

function paint(styles, runs) {
  const view = {cellW:11, cellH:22, width:110, height:22,
    text:{innerHTML:''}, lines:{setAttribute(){}, innerHTML:''}};
  TermView.prototype.paint.call(view, {styles}, {rows:[runs]});
  return view;
}
const colored = paint([['#abcdef','#123456',4,'#ff0000']], [[0,'Meet',0,4]]);
assert.match(colored.text.innerHTML, /color:#abcdef/);
assert.match(colored.text.innerHTML, /background:#123456/);
assert.match(colored.text.innerHTML, /text-decoration-color:#ff0000/);
assert.match(colored.text.innerHTML, /text-decoration-skip-ink:none/);
assert.match(colored.text.innerHTML, />Meet<\/span>/);

const legacy = paint([['#abcdef',null,4]], [[0,'now',0,3]]);
assert.match(legacy.text.innerHTML, /text-decoration-color:currentColor/);
assert.match(legacy.text.innerHTML, />now<\/span>/);
const blank = paint([['#abcdef',null,4,'#ff0000']], [[0,'   ',0,3]]);
assert.match(blank.lines.innerHTML, /data-terminal-underline="blank" d="M0 20\.4416\d*H33" stroke="#ff0000"/);
assert.match(blank.lines.innerHTML, /stroke-linecap="butt"/);
assert.doesNotMatch(blank.text.innerHTML, /text-decoration:underline/);
assert.equal(colored.lines.innerHTML, '');
const blankLegacy = paint([['#abcdef','#123456',4]], [[2,'   ',0,3]]);
assert.match(blankLegacy.lines.innerHTML, /d="M22 [^"]+H55" stroke="#abcdef"/);
assert.match(blankLegacy.text.innerHTML, /background:#123456/);
const clearNow = paint([['#e8ebf1','#111620',4,'#ff7070']], [[3,'               ',0,15]]);
assert.match(clearNow.lines.innerHTML, /d="M33 [^"]+H198" stroke="#ff7070"/);
const plain = paint([['#abcdef',null,0,'#ff0000']], [[0,'<&',0,2]]);
assert.doesNotMatch(plain.text.innerHTML, /text-decoration/);
assert.match(plain.text.innerHTML, /&lt;&amp;/);

const tape = new Tape({tape:'synthetic',columns:4,rows:1,styles:[['#abcdef',null,4,'#ff0000']],
  defaults:{fg:'#abcdef'},marks:[],frames:[{t:0,rows:[[[0,'Meet',0,4]]],cursor:null}]});
assert.deepEqual(tape.grid(0)[0][0], ['M',['#abcdef',null,4,'#ff0000']]);
console.log('short0219 replay: independent underline color, cell backgrounds, blank underline and legacy styles pass');
