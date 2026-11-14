const observer=new IntersectionObserver(entries=>{for(const entry of entries)if(entry.isIntersecting){entry.target.classList.add('visible');observer.unobserve(entry.target)}},{threshold:.08});
document.querySelectorAll('.reveal').forEach(el=>observer.observe(el));
document.querySelectorAll('[data-chapter]').forEach(link=>link.addEventListener('click',()=>{sessionStorage.setItem('furbrides-entry-stage',link.dataset.chapter)}));
