'use strict';
const screens=JSON.parse(document.getElementById('screens-data').textContent);
const buttons=[...document.querySelectorAll('[data-screen]')];
const description=document.querySelector('.screenDescription');
const image=document.querySelector('.galleryFigure img');
buttons.forEach(button=>button.addEventListener('click',()=>{
 const screen=screens.find(item=>item.id===button.dataset.screen);if(!screen)return;
 buttons.forEach(item=>item.setAttribute('aria-pressed',String(item===button)));
 description.querySelector('.screenLabel').textContent=screen.label;
 description.querySelector('h3').textContent=screen.title;
 description.querySelector('p').textContent=screen.text;
 description.querySelector('a').href=screen.src;
 image.src=screen.src;image.alt=screen.alt;
}));
