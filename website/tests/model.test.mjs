import test from 'node:test';
import assert from 'node:assert/strict';
import {validateNotes,filterNotes,markdown,samples,formatTime} from '../model.mjs';
test('backup rejects invalid, duplicate and excessive records before merge',()=>{const n=samples();assert.equal(validateNotes(n).length,3);assert.throws(()=>validateNotes([...n,n[0]]));assert.throws(()=>validateNotes([{...n[0],time:Infinity}]));assert.throws(()=>validateNotes([{...n[0],text:'x'.repeat(4001)}]));assert.throws(()=>validateNotes([{...n[0],sourceId:null}]));assert.throws(()=>validateNotes(Array(3001).fill(n[0])));});
test('search includes source and favorites',()=>{const n=samples();assert.equal(filterNotes(n,'自己的话').length,1);assert.equal(filterNotes(n,'',true).length,1);assert.equal(filterNotes(n,'一分钟').length,3);assert.equal(filterNotes(n,'不存在').length,0);});
test('time and export retain user text, source, timestamps and favorites',()=>{assert.equal(formatTime(65.8),'01:05');assert.equal(formatTime(-2),'00:00');const n=samples();const md=markdown(n);assert.ok(md.includes('00:24'));assert.ok(md.includes('★'));assert.ok(md.includes(n[2].text));});
