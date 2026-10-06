(() => {
  'use strict';
  document.documentElement.classList.add('js');
  const assetUrl = document.currentScript.src;
  const announcement = document.createElement('span');
  announcement.className = 'sr-only';
  announcement.setAttribute('role', 'status');
  announcement.setAttribute('aria-live', 'polite');
  document.body.append(announcement);
  if (window.matchMedia('(max-width: 1279px)').matches) {
    for (const toc of document.querySelectorAll('.doc-toc')) toc.open = false;
  }
  const nav = document.getElementById('docs-nav');
  const toggle = document.querySelector('[data-nav-toggle]');
  toggle?.addEventListener('click', () => {
    const expanded = toggle.getAttribute('aria-expanded') !== 'true';
    toggle.setAttribute('aria-expanded', String(expanded));
    nav?.classList.toggle('is-open', expanded);
  });
  document.addEventListener('keydown', event => {
    if (event.key === 'Escape' && nav?.classList.contains('is-open')) {
      nav.classList.remove('is-open');
      toggle?.setAttribute('aria-expanded', 'false');
      toggle?.focus();
    }
  });
  for (const button of document.querySelectorAll('.copy-code')) {
    const idleLabel = button.textContent;
    button.addEventListener('click', async () => {
      const code = document.getElementById(button.dataset.copy);
      if (!code) return;
      try {
        await navigator.clipboard.writeText(button.hasAttribute('data-copy-prompt') ? code.textContent.trim() : code.textContent);
        button.textContent = 'Copied';
        button.dataset.copied = '';
        announcement.textContent = 'Copied to clipboard.';
      } catch {
        button.textContent = 'Select & copy';
        const selection = window.getSelection();
        const range = document.createRange();
        range.selectNodeContents(code);
        selection.removeAllRanges();
        selection.addRange(range);
        announcement.textContent = 'Clipboard unavailable. Code selected for copying.';
      }
      window.setTimeout(() => { button.textContent = idleLabel; delete button.dataset.copied; }, 1800);
    });
  }
  for (const button of document.querySelectorAll('[data-animation-toggle]')) {
    const picture = button.closest('figure')?.querySelector('picture');
    const img = picture?.querySelector('img');
    if (!img) continue;
    let playing = !window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    const paint = () => {
      picture.querySelector('source').media = playing ? 'not all' : '(prefers-reduced-motion: reduce)';
      img.src = playing ? button.dataset.animated : button.dataset.still;
      button.textContent = playing ? 'Pause animation' : 'Play animation';
      button.setAttribute('aria-pressed', String(playing));
    };
    paint();
    button.addEventListener('click', () => { playing = !playing; paint(); });
  }
  const search = document.getElementById('doc-search');
  const results = document.getElementById('search-results');
  if (!search || !results) return;
  let index;
  let request;
  const load = async () => {
    request ??= fetch(new URL('../search.json', assetUrl)).then(response => {
      if (!response.ok) throw new Error('Search index unavailable');
      return response.json();
    });
    index ??= await request;
    return index;
  };
  search.addEventListener('input', async () => {
    const query = search.value.trim().toLowerCase();
    results.replaceChildren();
    results.hidden = !query;
    if (!query) return;
    try {
      const entries = await load();
      if (query !== search.value.trim().toLowerCase()) return;
      const matches = entries.flatMap(entry => [{ title: entry.title, url: entry.url, section: entry.section }, ...entry.headings.map(heading => ({ ...heading, section: entry.title }))]).filter(entry => `${entry.title} ${entry.section}`.toLowerCase().includes(query)).slice(0, 10);
      if (!matches.length) {
        results.textContent = 'No matching guide or heading.';
        return;
      }
      for (const entry of matches) {
        const link = document.createElement('a');
        link.href = entry.url;
        link.textContent = entry.title;
        const detail = document.createElement('small');
        detail.textContent = entry.section;
        link.append(detail);
        results.append(link);
      }
    } catch {
      results.textContent = 'Search is unavailable. Browse the guides below.';
    }
  });
  search.addEventListener('keydown', event => {
    if (event.key === 'Escape') {
      search.value = '';
      results.replaceChildren();
      results.hidden = true;
    } else if (event.key === 'ArrowDown') results.querySelector('a')?.focus();
  });
})();
