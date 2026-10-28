// node render3d.js <model.glb> <out.png> [camX camY camZ targetZ fov]
const { chromium } = require('playwright');
const fs = require('fs'), path = require('path');
(async () => {
  const [model, out, cx = 230, cy = -330, cz = 200, tz = 100, fov = 30] = process.argv.slice(2);
  const b64 = fs.readFileSync(model).toString('base64');
  const html = `<html><body style="margin:0;background:#f4efe6">
<script type="importmap">{"imports":{"three":"https://cdn.jsdelivr.net/npm/three@0.160.0/build/three.module.js","three/addons/":"https://cdn.jsdelivr.net/npm/three@0.160.0/examples/jsm/"}}</script>
<script type="module">
import * as THREE from 'three';
import {GLTFLoader} from 'three/addons/loaders/GLTFLoader.js';
const r=new THREE.WebGLRenderer({antialias:true,preserveDrawingBuffer:true});r.setSize(900,1100);r.setClearColor(0xf4efe6);
r.shadowMap.enabled=true;document.body.appendChild(r.domElement);
const s=new THREE.Scene();const cam=new THREE.PerspectiveCamera(${fov},900/1100,1,5000);
cam.up.set(0,0,1);cam.position.set(${cx},${cy},${cz});cam.lookAt(0,0,${tz});
s.add(new THREE.HemisphereLight(0xffffff,0x998877,1.6));
const d=new THREE.DirectionalLight(0xffffff,2.2);d.position.set(200,-300,400);d.castShadow=true;
d.shadow.mapSize.set(2048,2048);Object.assign(d.shadow.camera,{left:-200,right:200,top:200,bottom:-200});s.add(d);
const fl=new THREE.Mesh(new THREE.PlaneGeometry(2000,2000),new THREE.MeshStandardMaterial({color:0xe8dfd0}));fl.receiveShadow=true;s.add(fl);
const buf=Uint8Array.from(atob("${b64}"),c=>c.charCodeAt(0)).buffer;
new GLTFLoader().parse(buf,'',g=>{g.scene.traverse(o=>{if(o.isMesh){o.castShadow=o.receiveShadow=true;
 o.material=new THREE.MeshStandardMaterial({color:0xeee2b2,roughness:0.75});o.geometry=o.geometry.toNonIndexed();o.geometry.computeVertexNormals();}});
 s.add(g.scene);r.render(s,cam);window.done=true;});
</script></body></html>`;
  const browser = await chromium.launch({args:['--use-gl=swiftshader','--enable-unsafe-swiftshader']});
  const page = await browser.newPage({viewport:{width:900,height:1100}});
  page.on('console', m => console.log('console:', m.text()));
  await page.setContent(html);
  await page.waitForFunction('window.done===true',null,{timeout:120000});
  await page.screenshot({path: out});
  await browser.close();
})();
