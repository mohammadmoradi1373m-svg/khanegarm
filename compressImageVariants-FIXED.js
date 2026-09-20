/* خانه‌گرم — اصلاح قطعی تبدیل تصویر محصول
   این تابع را جایگزین function compressImageVariants(file) فعلی کنید.
*/
function compressImageVariants(file){
  return new Promise(resolve=>{
    if(!file||!file.type||!file.type.startsWith('image/')){
      resolve([null,null]);
      return;
    }

    const base=(file.name||'product-image').replace(/\.[^.]+$/,'');

    const finish=(mainBlob,thumbBlob,mainType)=>{
      if(!mainBlob || mainBlob.size>4.9*1024*1024 || !thumbBlob){
        resolve([null,null]);
        return;
      }
      const mainExt=mainType==='image/jpeg'?'jpg':'webp';
      const thumbExt=thumbBlob.type==='image/jpeg'?'jpg':'webp';

      resolve([
        new File([mainBlob],base+'.'+mainExt,{
          type:mainType,
          lastModified:Date.now()
        }),
        new File([thumbBlob],base+'_thumb.'+thumbExt,{
          type:thumbBlob.type,
          lastModified:Date.now()
        })
      ]);
    };

    /* مهم: draw تا پایان encode صبر می‌کند؛ بنابراین ImageBitmap
       قبل از پایان toBlob() بسته نمی‌شود. این همان ایراد اصلی نسخه قبلی است. */
    const draw=async(img,revoke)=>{
      try{
        const ow=img.width||img.naturalWidth;
        const oh=img.height||img.naturalHeight;

        if(!ow||!oh){
          if(revoke)URL.revokeObjectURL(revoke);
          resolve([null,null]);
          return;
        }

        const maxDim=1800;
        const maxPixels=5.5e6;

        let scale=Math.min(
          1,
          maxDim/Math.max(ow,oh),
          Math.sqrt(maxPixels/(ow*oh))
        );

        if(!Number.isFinite(scale)||scale<=0)scale=.1;

        let w=Math.max(1,Math.round(ow*scale));
        let h=Math.max(1,Math.round(oh*scale));

        const thumbScale=Math.min(1,420/Math.max(ow,oh));
        const tw=Math.max(1,Math.round(ow*thumbScale));
        const th=Math.max(1,Math.round(oh*thumbScale));

        const mainCanvas=document.createElement('canvas');
        const thumbCanvas=document.createElement('canvas');

        const mainCtx=mainCanvas.getContext('2d',{alpha:true});
        const thumbCtx=thumbCanvas.getContext('2d',{alpha:true});

        if(!mainCtx||!thumbCtx){
          if(revoke)URL.revokeObjectURL(revoke);
          resolve([null,null]);
          return;
        }

        const encode=(canvas,ctx,W,H,type,q)=>new Promise(r=>{
          try{
            canvas.width=W;
            canvas.height=H;
            ctx.clearRect(0,0,W,H);
            ctx.imageSmoothingEnabled=true;
            ctx.imageSmoothingQuality='high';
            ctx.drawImage(img,0,0,W,H);
            canvas.toBlob(r,type,q);
          }catch(e){
            r(null);
          }
        });

        let main=null;

        /* WebP را با چند کیفیت امتحان می‌کنیم. */
        for(const q of [.82,.76,.70,.64]){
          main=await encode(mainCanvas,mainCtx,w,h,'image/webp',q);
          if(main&&main.size<=4.7*1024*1024)break;
        }

        /* اگر هنوز بزرگ بود، ابعاد را هم مرحله‌ای کم می‌کنیم. */
        while(
          (!main||main.size>4.7*1024*1024) &&
          Math.max(w,h)>1000
        ){
          w=Math.max(1,Math.round(w*.82));
          h=Math.max(1,Math.round(h*.82));
          main=await encode(
            mainCanvas,mainCtx,w,h,'image/webp',.72
          );
        }

        let mainType='image/webp';

        /* fallback واقعی برای مرورگرهایی که WebP را encode نمی‌کنند. */
        if(!main||main.size>4.7*1024*1024){
          main=await encode(
            mainCanvas,mainCtx,w,h,'image/jpeg',.78
          );
          mainType='image/jpeg';
        }

        let thumb=await encode(
          thumbCanvas,thumbCtx,tw,th,'image/webp',.76
        );

        if(!thumb){
          thumb=await encode(
            thumbCanvas,thumbCtx,tw,th,'image/jpeg',.78
          );
        }

        if(revoke)URL.revokeObjectURL(revoke);
        finish(main,thumb,mainType);

      }catch(e){
        if(revoke)URL.revokeObjectURL(revoke);
        resolve([null,null]);
      }
    };

    /* مسیر fallback برای موبایل‌هایی که createImageBitmap مشکل دارد. */
    const fallback=()=>{
      const url=URL.createObjectURL(file);
      const img=new Image();

      img.onload=()=>draw(img,url);

      img.onerror=()=>{
        URL.revokeObjectURL(url);
        resolve([null,null]);
      };

      img.src=url;
    };

    if(typeof createImageBitmap==='function'){
      createImageBitmap(file,{imageOrientation:'from-image'})
        .then(async bitmap=>{
          try{
            /* حتماً تا پایان draw/encode صبر می‌کنیم. */
            await draw(bitmap,null);
          }finally{
            try{bitmap.close()}catch(e){}
          }
        })
        .catch(fallback);
    }else{
      fallback();
    }
  });
}
