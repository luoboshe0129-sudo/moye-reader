import Foundation

// These parsers and the month scan match the macOS implementation.
enum MoyeSiteScripts {
    static let searchScript = #"""
    (()=>{
      const out=[],seen=new Set();
      const clean=x=>(x||'').replace(/\s+/g,' ').trim();
      for(const a of document.querySelectorAll('a[href*="/album/"]')){
        const href=new URL(a.getAttribute('href')||a.href||'',location.href).href,m=href.match(/\/album\/(\d+)/);
        if(!m||seen.has(m[1])||a.closest('nav,header,.navbar'))continue;
        const img=a.querySelector('img');
        if(!img)continue;
        const raw=img.getAttribute('data-original')||img.getAttribute('data-src')||img.getAttribute('data-lazy-src')||img.currentSrc||img.src||'';
        if(!raw||raw.startsWith('data:'))continue;
        const cover=new URL(raw,location.href).href;
        if(!/\/media\/albums\//i.test(cover))continue;
        let card=a.closest('.list-col');
        if(!card){
          card=a.parentElement;
          for(let i=0;i<3&&card?.parentElement;i++){
            if(card.querySelector('.video-title,.album-title'))break;
            const parent=card.parentElement;
            const ids=new Set([...parent.querySelectorAll('a[href*="/album/"]')].map(x=>(x.href.match(/\/album\/(\d+)/)||[])[1]).filter(Boolean));
            if(ids.size>1)break;
            card=parent;
          }
        }
        if(!card)continue;
        const title=clean(card.querySelector('.video-title,.album-title')?.textContent)||clean(img.alt)||clean(a.title)||('JM '+m[1]);
        const authors=[...card.querySelectorAll('a[href*="main_tag=2"]')].map(x=>clean(x.textContent)).filter(Boolean);
        const author=[...new Set(authors)].join('、');
        const tags=[...card.querySelectorAll('.tags .tag,.tags a')].map(x=>clean(x.textContent)).filter(Boolean);
        const likes=clean(card.querySelector('[id^="love_likes_"],.label-loveicon')?.textContent);
        seen.add(m[1]);out.push({id:m[1],title,author,tags,likesText:likes,cover,url:href});
      }
      return out;
    })()
    """#

    static let detailScript = #"""
    (()=>{const title=document.querySelector('#book-name')?.innerText||document.querySelector('h1')?.innerText||document.title||'';const author=document.querySelector('.author')?.innerText||document.querySelector('[class*=author]')?.innerText||'';const description=document.querySelector('meta[property="og:description"]')?.content||document.querySelector('.description')?.innerText||'';const imgs=[...document.querySelectorAll('a[href*="/photo/"] img,#album_photo,.album-thumb img,.thumb-overlay img,[class*=cover] img')];const src=i=>i&&(i.getAttribute('data-original')||i.getAttribute('data-src')||i.getAttribute('data-lazy-src')||i.currentSrc||i.src)||'';const actual=imgs.find(i=>{const u=src(i);return u&&!u.startsWith('data:')&&!/(logo|avatar|blank|banner|ad\.)/i.test(u)});const social=document.querySelector('meta[property="og:image"]')?.content||'';const cover=src(actual)||(social&&!/(logo|avatar|blank|banner)/i.test(social)?social:'');const chapters=[];const seen=new Set();for(const a of document.querySelectorAll('a[href*="/photo/"]')){const m=(a.href||'').match(/\/photo\/(\d+)/);if(!m||seen.has(m[1]))continue;seen.add(m[1]);chapters.push({id:m[1],title:(a.innerText||a.textContent||'').trim(),url:a.href})}return {title,author,description,cover:cover?new URL(cover,location.href).href:'',chapters};})()
    """#

    static let photoScript = #"""
    (()=>{const imgs=[...document.querySelectorAll('.scramble-page img, img[id^="album_photo"]')];let raw=imgs.map(i=>i.dataset.original||i.dataset.src||i.src||'').filter(x=>x&&!x.includes('blank')&&!x.startsWith('data:'));let arr=window.page_arr;if(typeof arr==='string'){try{arr=JSON.parse(arr)}catch(e){}}const first=raw[0]||document.querySelector('[data-original*="/media/photos/"]')?.getAttribute('data-original')||'';if(Array.isArray(arr)&&arr.length&&first){const u=new URL(first,location.href);const base=u.href.slice(0,u.href.lastIndexOf('/')+1);const suffix=u.search;raw=arr.map(x=>base+String(x)+suffix)}const urls=[...new Set(raw.map(x=>new URL(x,location.href).href))];return {urls,albumID:Number(window.aid||new URL(location.href).pathname.match(/photo\/(\d+)/)?.[1]||0),scrambleID:Number(window.scramble_id||0)};})()
    """#

}
