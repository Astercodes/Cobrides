/* Account-owned profile images use existing private storage and cloud references. */
(()=>{'use strict';
async function upload(file){
 if(!['image/jpeg','image/png','image/webp'].includes(file?.type)||!file.size||file.size>10*1024*1024)throw Error('Choose a JPG, PNG or WebP photo up to 10 MB.');
 const source=URL.createObjectURL(file);
 try{const image=new Image();image.src=source;await image.decode();if(!image.naturalWidth||!image.naturalHeight)throw Error('This photo could not be opened.');
 const scale=Math.min(1,1024/Math.max(image.naturalWidth,image.naturalHeight)),canvas=document.createElement('canvas');canvas.width=Math.max(1,Math.round(image.naturalWidth*scale));canvas.height=Math.max(1,Math.round(image.naturalHeight*scale));const ctx=canvas.getContext('2d');ctx.fillStyle='#ffffff';ctx.fillRect(0,0,canvas.width,canvas.height);ctx.drawImage(image,0,0,canvas.width,canvas.height);
 const blob=await new Promise(resolve=>canvas.toBlob(resolve,'image/jpeg',.88));if(!blob)throw Error('This photo could not be prepared.');return await CoBridesFiles.upload(blob,'cb-documents','profile photo');
 }finally{URL.revokeObjectURL(source);}
}
window.CobrideyProfilePhoto={upload};
})();
