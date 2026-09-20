/*
 * V4 — resilient product image pipeline.
 * Input: common camera/product images.
 * Normal output: WebP main + WebP thumbnail.
 * If a browser encoder/decoder fails, common small PNG/JPEG/WEBP files use a safe fallback.
 */
const PRODUCT_IMAGE_MAX_INPUT_BYTES = 25 * 1024 * 1024;
const PRODUCT_IMAGE_MAX_OUTPUT_BYTES = 4.7 * 1024 * 1024;
const PRODUCT_IMAGE_MAX_DIM = 2500;
const PRODUCT_IMAGE_THUMB_DIM = 480;

function makeImageFile(blob, baseName, suffix){
  if(!blob) return null;
  const type=blob.type||'image/webp';
  const ext=type==='image/webp'?'webp':type==='image/png'?'png':type==='image/jpeg'?'jpg':'bin';
  return new File([blob],baseName+(suffix||'')+'.'+ext,{type,lastModified:Date.now()});
}

function decodeProductImage(file){
  return new Promise((resolve,reject)=>{
    if(!file||!file.type||!file.type.startsWith('image/')){reject(new Error('NOT_IMAGE'));return;}
    if(file.size>PRODUCT_IMAGE_MAX_INPUT_BYTES){reject(new Error('INPUT_TOO_LARGE'));return;}
    const fallback=()=>{
      const url=URL.createObjectURL(file),img=new Image();
      img.onload=()=>{URL.revokeObjectURL(url);resolve({image:img,close:()=>{}})};
      img.onerror=()=>{URL.revokeObjectURL(url);reject(new Error('DECODE_FAILED'))};
      img.src=url;
    };
    if(typeof createImageBitmap==='function'){
      createImageBitmap(file,{imageOrientation:'from-image'})
        .then(bitmap=>resolve({image:bitmap,close:()=>{try{bitmap.close()}catch(e){}}}))
        .catch(fallback);
    }else fallback();
  });
}

function canvasBlob(canvas,type,quality){
  return new Promise(resolve=>{
    try{canvas.toBlob(blob=>resolve(blob||null),type,quality)}catch(e){resolve(null)}
  });
}

async function encodeProductImage(image,maxDim,targetBytes,startQuality,allowJpegFallback){
  let w=image.width||image.naturalWidth,h=image.height||image.naturalHeight;
  if(!w||!h)return null;
  const scale=Math.min(1,maxDim/Math.max(w,h));
  w=Math.max(1,Math.round(w*scale)); h=Math.max(1,Math.round(h*scale));
  const canvas=document.createElement('canvas'),ctx=canvas.getContext('2d',{alpha:true});
  if(!ctx)return null;
  const draw=()=>{
    canvas.width=w;canvas.height=h;ctx.clearRect(0,0,w,h);
    ctx.imageSmoothingEnabled=true;ctx.imageSmoothingQuality='high';
    ctx.drawImage(image,0,0,w,h);
  };
  let q=startQuality;
  while(q>=0.64){
    draw();
    const b=await canvasBlob(canvas,'image/webp',q);
    if(b&&b.type==='image/webp'&&b.size<=targetBytes)return b;
    q=+(q-0.06).toFixed(2);
  }
  while(Math.max(w,h)>1100){
    w=Math.max(1,Math.round(w*.82));h=Math.max(1,Math.round(h*.82));q=.78;
    while(q>=0.64){
      draw();
      const b=await canvasBlob(canvas,'image/webp',q);
      if(b&&b.type==='image/webp'&&b.size<=targetBytes)return b;
      q=+(q-0.07).toFixed(2);
    }
  }
  if(!allowJpegFallback)return null;
  q=.82;
  while(q>=0.58){
    draw();
    const b=await canvasBlob(canvas,'image/jpeg',q);
    if(b&&b.type==='image/jpeg'&&b.size<=targetBytes)return b;
    q=+(q-0.07).toFixed(2);
  }
  return null;
}

async function compressImageVariants(file){
  if(!file||!file.type||!file.type.startsWith('image/'))return [null,null];
  if(file.size>PRODUCT_IMAGE_MAX_INPUT_BYTES)return [null,null];
  const base=(file.name||'product-image').replace(/\.[^.]+$/,'').replace(/[^a-zA-Z0-9_-]+/g,'-').replace(/^-+|-+$/g,'')||'product-image';
  let decoded=null;
  try{
    decoded=await decodeProductImage(file);
    const image=decoded.image,isPng=/^image\/png$/i.test(file.type);
    const main=await encodeProductImage(image,PRODUCT_IMAGE_MAX_DIM,PRODUCT_IMAGE_MAX_OUTPUT_BYTES,.86,!isPng);
    if(main){
      const thumb=await encodeProductImage(image,PRODUCT_IMAGE_THUMB_DIM,450*1024,.80,!isPng);
      if(thumb){
        decoded.close();
        return [makeImageFile(main,base,''),makeImageFile(thumb,base,'_thumb')];
      }
    }
    decoded.close();
  }catch(e){try{if(decoded)decoded.close()}catch(_){}}
  // Do not block the admin when a browser encoder fails.
  if(/^(image\/png|image\/jpeg|image\/jpg|image\/webp)$/i.test(file.type)&&file.size<=PRODUCT_IMAGE_MAX_OUTPUT_BYTES){
    const ext=file.type==='image/png'?'png':file.type==='image/webp'?'webp':'jpg';
    const safe=new File([file],base+'.'+ext,{type:file.type,lastModified:file.lastModified||Date.now()});
    return [safe,safe];
  }
  return [null,null];
}

function getStorageSiblingUrl(url,suffix){
  if(!url||!/^https?:\/\//i.test(url))return url;
  try{const u=new URL(url),m=u.pathname.match(/^(.*\/)([^/]+)$/);if(!m)return url;const name=m[2],dot=name.lastIndexOf('.'),base=dot>0?name.slice(0,dot):name;u.pathname=m[1]+base+suffix+'.webp';u.search='';return u.toString()}catch(e){return url}
}
function productImageUrl(url,variant){
  if(!url)return '';
  if(variant==='thumb'&&/\.webp(?:$|[?#])/i.test(url))return getStorageSiblingUrl(url,'_thumb');
  return url;
}
async function imageUploadVariants(file){return compressImageVariants(file)}
