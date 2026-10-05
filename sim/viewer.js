const visualNames=['luma','contrast','edge H','edge /','edge V','edge \\','change','move X','move Y','confidence','expansion','rotation','saliency X','saliency Y','activity','consistency'];
const visualLocalNames=['luminance','contrast','edge H','edge /','edge V','edge \\','temporal change','motion X','motion Y','motion confidence'];
const audioNames=['energy','low','mid','high','centroid','spread','onset','offset','peak band','impulse','modulation','level','phase','lateral move','confidence','novelty'];
const audioLocalNames=['left energy','right energy','mono energy','energy delta','onset','level difference','phase lead','stereo confidence'];
const visualSigned=new Set([6,7,8,10,11,12,13]),visualLocalSigned=new Set([6,7,8]),audioSigned=new Set([11,12,13]),audioLocalSigned=new Set([3,5,6]);
const $=id=>document.getElementById(id),signed=value=>value>127?value-256:value;
let replay=null,playing=false,animationStart=0,playbackStart=0;
let visualTileScales=[],visualCellScales=[],visualFieldScales=[],audioLocalScales=[],audioFieldScales=[];
let frameImages=new WeakMap();

function nearest(items,time){let best=null,distance=Infinity;for(const item of items||[]){const candidate=Math.abs(item.time-time);if(candidate<distance){best=item;distance=candidate}}return best}
function color(value,isSigned,limit=isSigned?128:255){if(isSigned){const v=Math.max(-1,Math.min(1,signed(value)/limit));return v<0?`rgb(${55-Math.round(v*120)},${78+Math.round((1+v)*45)},${120+Math.round((1+v)*80)})`:`rgb(${48+Math.round(v*38)},${75+Math.round(v*140)},${104+Math.round(v*90)})`}const v=Math.max(0,Math.min(1,value/limit));return `rgb(${20+Math.round(v*70)},${34+Math.round(v*185)},${58+Math.round(v*145)})`}
function clear(canvas){const context=canvas.getContext('2d');context.clearRect(0,0,canvas.width,canvas.height);return context}
function percentileScale(values,isSigned){const magnitudes=values.map(value=>isSigned?Math.abs(signed(value)):value).sort((a,b)=>a-b);return Math.max(1,magnitudes[Math.floor((magnitudes.length-1)*.99)]||1)}
function displayLimit(scales,index,signedSet){return $('scaleMode').value==='auto'?(scales[index]||1):(signedSet.has(index)?128:255)}
function computeScales(value){
  const visualTiles=visualLocalNames.map(()=>[]),visualCells=visualLocalNames.map(()=>[]),visualField=visualNames.map(()=>[]),audioLocal=audioLocalNames.map(()=>[]),audioField=audioNames.map(()=>[]);
  value.visual.forEach(entry=>{entry.tiles.forEach(record=>record.slice(0,10).forEach((sample,index)=>visualTiles[index].push(sample)));(entry.cells||entry.tiles).forEach(record=>record.slice(0,10).forEach((sample,index)=>visualCells[index].push(sample)));entry.field.slice(1,17).forEach((sample,index)=>visualField[index].push(sample))});
  value.audio.forEach(entry=>{entry.slots.forEach(slot=>slot[0].forEach(record=>record.forEach((sample,index)=>audioLocal[index].push(sample))));entry.field.slice(1,17).forEach((sample,index)=>audioField[index].push(sample))});
  visualTileScales=visualTiles.map((values,index)=>percentileScale(values,visualLocalSigned.has(index)));visualCellScales=visualCells.map((values,index)=>percentileScale(values,visualLocalSigned.has(index)));visualFieldScales=visualField.map((values,index)=>percentileScale(values,visualSigned.has(index)));audioLocalScales=audioLocal.map((values,index)=>percentileScale(values,audioLocalSigned.has(index)));audioFieldScales=audioField.map((values,index)=>percentileScale(values,audioSigned.has(index)));
}
function frameImage(entry){if(!entry?.frame_png)return null;let image=frameImages.get(entry);if(!image){image=new Image();image.decoding='async';image.onload=()=>{if(nearest(replay?.visual,Number($('time').value))===entry)drawImageAndFlow(entry)};image.src=entry.frame_png;frameImages.set(entry,image)}return image}
function prefetchFrames(entry){const index=replay?.visual?.indexOf(entry)??-1;if(index<0)return;for(let offset=1;offset<=12;offset++)frameImage(replay.visual[index+offset])}

function drawImageAndFlow(entry){
  const canvas=$('image'),context=clear(canvas);if(!entry)return;const size=replay.preview_size,pixels=context.createImageData(size,size);
  entry.preview.forEach((value,index)=>{pixels.data[index*4]=pixels.data[index*4+1]=pixels.data[index*4+2]=value;pixels.data[index*4+3]=255});
  const scratch=document.createElement('canvas');scratch.width=scratch.height=size;scratch.getContext('2d').putImageData(pixels,0,0);context.imageSmoothingEnabled=false;context.drawImage(scratch,0,0,canvas.width,canvas.height);
  const full=frameImage(entry);if(full?.complete&&full.naturalWidth){context.imageSmoothingEnabled=false;context.drawImage(full,0,0,canvas.width,canvas.height)}prefetchFrames(entry);
  const records=entry.cells||entry.tiles,grid=Math.round(Math.sqrt(records.length)),cell=canvas.width/grid;context.strokeStyle='#ffffff18';context.lineWidth=1;for(let n=1;n<grid;n++){context.beginPath();context.moveTo(n*cell,0);context.lineTo(n*cell,canvas.height);context.stroke();context.beginPath();context.moveTo(0,n*cell);context.lineTo(canvas.width,n*cell);context.stroke()}
  context.strokeStyle='#55d6be';context.fillStyle='#55d6be';context.lineWidth=2;records.forEach((record,index)=>{const x=(index%grid+.5)*cell,y=(Math.floor(index/grid)+.5)*cell,dx=signed(record[7])/10,dy=signed(record[8])/10;context.beginPath();context.moveTo(x,y);context.lineTo(x+dx,y+dy);context.stroke();context.beginPath();context.arc(x+dx,y+dy,2,0,Math.PI*2);context.fill()});
  const sx=signed(entry.field[13]),sy=signed(entry.field[14]),saliencyX=canvas.width/2+sx*1.2,saliencyY=canvas.height/2+sy*1.2;context.strokeStyle='#ffc857';context.lineWidth=3;context.beginPath();context.arc(saliencyX,saliencyY,11,0,Math.PI*2);context.stroke();context.beginPath();context.moveTo(saliencyX-16,saliencyY);context.lineTo(saliencyX+16,saliencyY);context.moveTo(saliencyX,saliencyY-16);context.lineTo(saliencyX,saliencyY+16);context.stroke();
}

function drawVisualMap(entry){
  const canvas=$('visualMap'),context=clear(canvas);if(!entry)return;const feature=Number($('visualFeature').value),fine=$('visualLevel').value==='tiles',records=fine?entry.tiles:(entry.cells||entry.tiles),grid=Math.round(Math.sqrt(records.length)),cell=canvas.width/grid,scales=fine?visualTileScales:visualCellScales,limit=displayLimit(scales,feature,visualLocalSigned);
  records.forEach((record,index)=>{context.fillStyle=color(record[feature],visualLocalSigned.has(feature),limit);context.fillRect((index%grid)*cell,Math.floor(index/grid)*cell,cell-1,cell-1);context.fillStyle='#e5eef8';context.font=`${grid>8?9:11}px ui-monospace`;const value=visualLocalSigned.has(feature)?signed(record[feature]):record[feature];context.fillText(String(value),(index%grid)*cell+2,Math.floor(index/grid)*cell+(grid>8?10:14))});
  $('visualGrid').textContent=`${grid}×${grid} ${fine?'fine A0 tile':'emitted cell'} raster; numbers are raw bytes`;
  $('visualScale').textContent=`display ${visualLocalSigned.has(feature)?'±':''}${limit}`;
  $('visualStatus').textContent=`status 0x${entry.field[17].toString(16).padStart(2,'0')}`;
}

function drawBars(canvas,names,values,signedSet,scales){
  const context=clear(canvas),width=canvas.width,height=canvas.height,column=width/names.length,zero=height*.48;context.strokeStyle='#34445a';context.beginPath();context.moveTo(0,zero);context.lineTo(width,zero);context.stroke();
  names.forEach((name,index)=>{const value=signedSet.has(index)?signed(values[index]):values[index],limit=displayLimit(scales,index,signedSet),magnitude=Math.min(1,Math.abs(value)/limit),barHeight=magnitude*(zero-25),y=signedSet.has(index)&&value<0?zero:zero-barHeight;context.fillStyle=value<0?'#ff6e7a':'#55d6be';context.fillRect(index*column+5,y,column-10,barHeight);context.fillStyle='#e1ebf7';context.font='11px ui-monospace';context.fillText(String(value),index*column+7,value<0?zero+14:Math.max(12,y-4));context.save();context.translate(index*column+column*.58,height-4);context.rotate(-Math.PI/3);context.fillStyle='#aab8ca';context.fillText(name,0,0);context.restore()});
}
function readouts(container,entries){container.innerHTML=entries.map(([name,value,klass=''])=>`<div class="readout"><span>${name}</span><strong class="${klass}">${value}</strong></div>`).join('')}

function drawWaveform(time){
  const canvas=$('waveform'),context=clear(canvas),points=replay?.waveform||[],span=.12,start=time-span/2,end=time+span/2,visible=points.filter(point=>point[0]>=start&&point[0]<=end);context.strokeStyle='#34445a';context.beginPath();context.moveTo(0,canvas.height/2);context.lineTo(canvas.width,canvas.height/2);context.stroke();
  for(const [channel,tint] of [[1,'#5fa8ff'],[2,'#ff6e7a']]){context.strokeStyle=tint;context.lineWidth=1.5;context.beginPath();visible.forEach((point,index)=>{const x=(point[0]-start)/span*canvas.width,y=canvas.height/2-point[channel]/32768*canvas.height*.44;index?context.lineTo(x,y):context.moveTo(x,y)});context.stroke()}context.fillStyle='#8293aa';context.font='12px ui-monospace';context.fillText(`${(span*1000).toFixed(0)} ms window`,9,17);
}

function drawCochlea(entry){
  const canvas=$('cochlea'),context=clear(canvas);if(!entry)return;const feature=Number($('audioFeature').value),cellW=canvas.width/8,cellH=canvas.height/16,limit=displayLimit(audioLocalScales,feature,audioLocalSigned);
  entry.slots.forEach((slot,timeIndex)=>slot[0].forEach((record,band)=>{context.fillStyle=color(record[feature],audioLocalSigned.has(feature),limit);const y=(15-band)*cellH;context.fillRect(timeIndex*cellW,y,cellW-1,cellH-1)}));
  context.fillStyle='#dfe9f5';context.font='11px ui-monospace';[0,4,8,12,15].forEach(band=>context.fillText(`b${band}`,4,(15-band)*cellH+12));$('audioScale').textContent=`display ${audioLocalSigned.has(feature)?'±':''}${limit}`;$('audioStatus').textContent=`status 0x${entry.field[17].toString(16).padStart(2,'0')}`;drawSpatial(entry);
}
function drawSpatial(entry){
  const canvas=$('spatial'),context=clear(canvas),mid=canvas.height/2;context.strokeStyle='#34445a';context.beginPath();context.moveTo(10,mid);context.lineTo(canvas.width-10,mid);context.stroke();context.fillStyle='#8293aa';context.font='11px ui-monospace';context.fillText('LEFT',10,14);context.fillText('RIGHT',canvas.width-44,14);
  entry.slots.forEach((slot,index)=>{let weighted=0,confidence=0;slot[0].forEach(record=>{weighted+=signed(record[5])*record[7];confidence+=record[7]});const lateral=confidence?Math.max(-128,Math.min(127,weighted/(1<<Math.floor(Math.log2(confidence))))):0,x=canvas.width/2+lateral/128*(canvas.width/2-18),y=mid+(index-3.5)*5;context.fillStyle=`hsl(${175+index*7} 70% 60%)`;context.beginPath();context.arc(x,y,4,0,Math.PI*2);context.fill()});
}

function mismatch(entry){if(!entry?.rtl_field)return null;for(let i=0;i<entry.field.length;i++)if(entry.field[i]!==entry.rtl_field[i])return{index:i,expected:entry.field[i],actual:entry.rtl_field[i]};return false}
function drawTimeline(time){
  const canvas=$('timeline'),context=clear(canvas);if(!replay)return;const left=28,right=canvas.width-18,scale=value=>left+value/replay.duration*(right-left);context.font='12px ui-monospace';context.fillStyle='#8293aa';context.fillText('VIS',2,43);context.fillText('AUD',2,96);context.strokeStyle='#27364a';[38,91].forEach(y=>{context.beginPath();context.moveTo(left,y);context.lineTo(right,y);context.stroke()});
  for(const entry of replay.visual){const bad=mismatch(entry),status=entry.field[17];context.fillStyle=(bad||status)?'#ff6e7a':'#55d6be';context.fillRect(scale(entry.time)-1,27,3,22)}for(const entry of replay.audio){const bad=mismatch(entry),status=entry.field[17];context.fillStyle=(bad||status)?'#ff6e7a':'#bd93f9';context.fillRect(scale(entry.time)-1,80,3,22)}context.strokeStyle='#ffc857';context.lineWidth=2;context.beginPath();context.moveTo(scale(time),12);context.lineTo(scale(time),122);context.stroke();for(let tick=0;tick<=replay.duration;tick+=.1){const x=scale(tick);context.fillStyle='#60738b';context.fillRect(x,125,1,Math.abs(tick-Math.round(tick))<.001?10:5);if(Math.abs(tick-Math.round(tick))<.001)context.fillText(`${tick.toFixed(0)}s`,x+2,145)}
}

function compare(visual,audio){
  const parts=[];let state='reference only',klass='';for(const [name,entry] of [['visual',visual],['audio',audio]]){const result=mismatch(entry);if(result===null)parts.push(`${name}: no RTL field in replay`);else if(result===false){parts.push(`${name}: exact reference/RTL match`);state='matching';klass='good'}else{parts.push(`${name}: byte ${result.index}, reference ${result.expected}, RTL ${result.actual}`);state='mismatch';klass='bad'}}$('comparison').textContent=parts.join('\n');$('compareState').textContent=state;$('compareState').className=klass;
}

function render(time){
  if(!replay)return;const visual=nearest(replay.visual,time),audio=nearest(replay.audio,time);$('clock').textContent=`${time.toFixed(3)} s`;$('visualTime').textContent=visual?`${visual.time.toFixed(3)} s`:'—';$('audioTime').textContent=audio?`${audio.time.toFixed(3)} s`:'—';drawImageAndFlow(visual);drawVisualMap(visual);drawWaveform(time);drawCochlea(audio);drawTimeline(time);compare(visual,audio);
  if(visual){const values=visual.field.slice(1,17);drawBars($('visualBars'),visualNames,values,visualSigned,visualFieldScales);readouts($('visualReadouts'),[['translation',`${signed(values[7])}, ${signed(values[8])}`],['expansion',signed(values[10]),values[10]&&'good'],['rotation',signed(values[11])],['saliency',`${signed(values[12])}, ${signed(values[13])}`],['activity',values[14]],['confidence',values[9]],['consistency',values[15]],['status',`0x${visual.field[17].toString(16).padStart(2,'0')}`]])}
  if(audio){const values=audio.field.slice(1,17);drawBars($('audioBars'),audioNames,values,audioSigned,audioFieldScales);readouts($('audioReadouts'),[['energy',values[0]],['peak band',Math.round(values[8]/17)],['onset',values[6]],['impulse',values[9]],['lateral',signed(values[13])],['confidence',values[14]],['novelty',values[15]],['status',`0x${audio.field[17].toString(16).padStart(2,'0')}`]])}
}

function loadReplay(value){if(value.schema!=='THE_SENSOR_REFERENCE_REPLAY_V0')throw new Error(`unsupported schema ${value.schema}`);replay=value;frameImages=new WeakMap();computeScales(value);$('schema').textContent=value.schema;const source=value.source;$('source').textContent=source?`${source.file} @ ${source.segment_start.toFixed(3)} s`:'synthetic';$('time').max=value.duration;$('time').value=0;$('drop').style.display='none';render(0)}
async function loadFile(file){try{loadReplay(JSON.parse(await file.text()))}catch(error){$('drop').textContent=`Could not load replay: ${error.message}`;$('drop').style.display='block'}}
$('file').onchange=event=>event.target.files[0]&&loadFile(event.target.files[0]);$('time').oninput=event=>render(Number(event.target.value));$('visualFeature').onchange=()=>render(Number($('time').value));$('visualLevel').onchange=()=>render(Number($('time').value));$('audioFeature').onchange=()=>render(Number($('time').value));$('scaleMode').onchange=()=>{$('displayScale').textContent=$('scaleMode').value==='auto'?'p99 auto gain; labels are raw':'raw byte scale';render(Number($('time').value))};
$('play').onclick=()=>{if(!replay)return;playing=!playing;$('play').textContent=playing?'❚❚ Pause':'▶ Play';animationStart=performance.now();playbackStart=Number($('time').value);if(playing)requestAnimationFrame(tick)};$('back').onclick=()=>step(-1);$('forward').onclick=()=>step(1);
function step(direction){if(!replay)return;playing=false;$('play').textContent='▶ Play';const next=Math.max(0,Math.min(replay.duration,Number($('time').value)+direction/(replay.frame_rate||30)));$('time').value=next;render(next)}
function tick(now){if(!playing)return;const speed=parseFloat($('speed').value);let time=playbackStart+(now-animationStart)/1000*speed;if(time>replay.duration){time=0;animationStart=now;playbackStart=0}$('time').value=time;render(time);requestAnimationFrame(tick)}
for(const [select,names] of [[$('visualFeature'),visualLocalNames],[$('audioFeature'),audioLocalNames]])names.forEach((name,index)=>select.add(new Option(name,index)));$('audioFeature').value=2;
for(const eventName of ['dragenter','dragover'])document.body.addEventListener(eventName,event=>{event.preventDefault();$('drop').classList.add('active')});for(const eventName of ['dragleave','drop'])document.body.addEventListener(eventName,event=>{event.preventDefault();$('drop').classList.remove('active')});document.body.addEventListener('drop',event=>event.dataTransfer.files[0]&&loadFile(event.dataTransfer.files[0]));
